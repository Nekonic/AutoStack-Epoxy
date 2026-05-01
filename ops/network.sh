#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

check_root
[ "$MY_ROLE" = "controller" ] || die "Controller 노드에서 실행하세요."
[ -f /root/admin-openrc ] || die "admin-openrc 없음. Keystone 먼저 설치하세요."
source /root/admin-openrc

# env.sh 변수에서 prefix 추출
_net_prefix() { echo "$1" | cut -d'/' -f1; }
_net_prefix4() { echo "$1" | cut -d'/' -f2; }

# ── 기능 ──────────────────────────────────────────────────────────────

show_status() {
    echo
    log_step "네트워크"
    openstack network list -f table
    echo
    log_step "서브넷"
    openstack subnet list -f table
    echo
    log_step "라우터"
    openstack router list -f table
    echo
    log_step "포트"
    openstack port list --router router -f table 2>/dev/null || true
    echo
}

setup_provider() {
    log_step "Provider 네트워크 생성"
    if openstack network show provider &>/dev/null; then
        log_warn "provider 네트워크 이미 존재. 건너뜀."
    else
        openstack network create \
            --share \
            --external \
            --provider-physical-network provider \
            --provider-network-type flat \
            provider > /dev/null
        log_ok "provider 네트워크 생성 완료"
    fi

    log_step "Provider 서브넷 생성"
    if openstack subnet show provider-subnet &>/dev/null; then
        log_warn "provider-subnet 이미 존재. 건너뜀."
    else
        openstack subnet create \
            --network provider \
            --allocation-pool "start=${PROVIDER_POOL_START},end=${PROVIDER_POOL_END}" \
            --dns-nameserver "${MGMT_DNS}" \
            --gateway "${PROVIDER_GW}" \
            --subnet-range "${PROVIDER_CIDR}" \
            provider-subnet > /dev/null
        log_ok "provider-subnet 생성 완료 (${PROVIDER_CIDR}, pool: ${PROVIDER_POOL_START}~${PROVIDER_POOL_END})"
    fi
}

setup_selfservice() {
    log_step "Self-service 네트워크 생성"
    if openstack network show selfservice &>/dev/null; then
        log_warn "selfservice 네트워크 이미 존재. 건너뜀."
    else
        openstack network create selfservice > /dev/null
        log_ok "selfservice 네트워크 생성 완료"
    fi

    log_step "Self-service 서브넷 생성"
    if openstack subnet show selfservice-subnet &>/dev/null; then
        log_warn "selfservice-subnet 이미 존재. 건너뜀."
    else
        openstack subnet create \
            --network selfservice \
            --dns-nameserver "${MGMT_DNS}" \
            --gateway "${SELFSERVICE_GW}" \
            --subnet-range "${SELFSERVICE_CIDR}" \
            selfservice-subnet > /dev/null
        log_ok "selfservice-subnet 생성 완료 (${SELFSERVICE_CIDR}, gw: ${SELFSERVICE_GW})"
    fi
}

setup_router() {
    log_step "라우터 생성"
    if openstack router show router &>/dev/null; then
        log_warn "router 이미 존재. 건너뜀."
    else
        openstack router create router > /dev/null
        log_ok "router 생성 완료"
    fi

    log_step "라우터에 selfservice 서브넷 연결"
    local _port_exists
    _port_exists=$(openstack port list --router router -f value -c "Fixed IP Addresses" 2>/dev/null \
        | grep -c "${SELFSERVICE_GW}" || true)
    if [ "$_port_exists" -gt 0 ]; then
        log_warn "selfservice-subnet 이미 연결됨. 건너뜀."
    else
        openstack router add subnet router selfservice-subnet
        log_ok "selfservice-subnet → router 연결 완료"
    fi

    log_step "라우터 외부 게이트웨이 설정 (provider)"
    local _gw
    _gw=$(openstack router show router -f value -c external_gateway_info 2>/dev/null || true)
    if echo "$_gw" | grep -q "network_id"; then
        log_warn "외부 게이트웨이 이미 설정됨. 건너뜀."
    else
        openstack router set router --external-gateway provider
        log_ok "외부 게이트웨이 → provider 설정 완료"
    fi
}

setup_all() {
    echo
    log_info "다음 설정으로 네트워크를 구성합니다:"
    echo -e "  Provider  : ${PROVIDER_CIDR}  GW: ${PROVIDER_GW}  Pool: ${PROVIDER_POOL_START}~${PROVIDER_POOL_END}"
    echo -e "  Self-svc  : ${SELFSERVICE_CIDR}  GW: ${SELFSERVICE_GW}"
    echo -e "  DNS       : ${MGMT_DNS}"
    echo
    prompt_confirm "계속하시겠습니까?" || return 0

    setup_provider
    setup_selfservice
    setup_router

    echo
    log_ok "네트워크 초기 설정 완료"
    echo
    show_status
}

teardown_all() {
    echo
    log_warn "라우터, selfservice, provider 네트워크를 모두 삭제합니다."
    prompt_confirm "정말 삭제하시겠습니까?" || return 0

    # 라우터 정리
    if openstack router show router &>/dev/null; then
        openstack router set router --no-external-gateway 2>/dev/null || true
        openstack router remove subnet router selfservice-subnet 2>/dev/null || true
        openstack router delete router 2>/dev/null || true
        log_ok "router 삭제 완료"
    fi

    # 서브넷/네트워크 삭제
    for name in selfservice-subnet provider-subnet selfservice provider; do
        if openstack subnet show "$name" &>/dev/null 2>&1 \
           || openstack network show "$name" &>/dev/null 2>&1; then
            openstack subnet delete "$name" 2>/dev/null || true
            openstack network delete "$name" 2>/dev/null || true
            log_ok "${name} 삭제 완료"
        fi
    done

    log_ok "네트워크 삭제 완료"
}

# ── 메인 루프 ─────────────────────────────────────────────────────────
log_header "네트워크 관리"

while true; do
    echo -e "  ${BOLD}메뉴${NC}"
    echo "    1) 네트워크 상태 확인"
    echo "    2) 전체 초기 설정 (provider + selfservice + router)"
    echo "    3) Provider 네트워크만 생성"
    echo "    4) Self-service 네트워크만 생성"
    echo "    5) 라우터만 생성/연결"
    echo "    6) 전체 삭제 (초기화)"
    echo "    0) 종료"
    echo

    read -rp "  선택: " menu_choice
    echo
    case "$menu_choice" in
        1) show_status ;;
        2) setup_all ;;
        3) setup_provider ;;
        4) setup_selfservice ;;
        5) setup_router ;;
        6) teardown_all ;;
        0) break ;;
        *) echo "  올바른 번호를 입력하세요." ;;
    esac
    echo
done
