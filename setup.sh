#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/nic.sh"
source "${SCRIPT_DIR}/lib/role.sh"

check_root

ENV_FILE="/etc/AutoStack-Epoxy/env.sh"

log_header "AutoStack-Epoxy 환경 설정 마법사"

# ── Step 1: Management NIC ──────────────────────────────────────────
log_step "1단계: Management NIC 선택 (관리망)"
MGMT_IF=$(select_nic "Management NIC 번호 선택" "")
log_ok "Management NIC: $MGMT_IF"

# ── Step 2: Provider NIC ────────────────────────────────────────────
log_step "2단계: Provider NIC 선택 (외부망/브리지)"
PROVIDER_IF=$(select_nic "Provider NIC 번호 선택" "$MGMT_IF")
log_ok "Provider NIC: $PROVIDER_IF"

# ── Step 3: Management 네트워크 ─────────────────────────────────────
log_step "3단계: Management 네트워크 설정"
MGMT_CIDR=$(prompt_input "Management 서브넷 (CIDR)" "10.0.0.0/24")
MGMT_GW=$(prompt_input "Management 게이트웨이" "10.0.0.2")
MGMT_DNS=$(prompt_input "DNS 서버" "8.8.8.8")

# ── Step 4: Provider 네트워크 ────────────────────────────────────────
log_step "4단계: Provider 네트워크 설정 (Floating IP 대역)"
PROVIDER_CIDR=$(prompt_input "Provider 서브넷 (CIDR)" "192.168.2.0/24")
PROVIDER_GW=$(prompt_input "Provider 게이트웨이" "192.168.2.2")
PROVIDER_POOL_START=$(prompt_input "Floating IP 시작" "192.168.2.200")
PROVIDER_POOL_END=$(prompt_input "Floating IP 끝" "192.168.2.250")

# ── Step 5: 노드 역할 범위 ───────────────────────────────────────────
log_step "5단계: 노드 역할 범위 설정 (IP 마지막 옥텟 기준)"
echo -e "  기본값: Controller 10-19 / Compute 20-99 / Block 100-200"
CONTROLLER_RANGE=$(prompt_input "Controller 범위" "10-19")
COMPUTE_RANGE=$(prompt_input "Compute 범위" "20-99")
BLOCK_RANGE=$(prompt_input "Block 범위" "100-200")

# ── Step 6: 공통 패스워드 ────────────────────────────────────────────
log_step "6단계: 공통 패스워드 설정"
echo -e "  ${YELLOW}모든 OpenStack 서비스(DB, RabbitMQ, 각 서비스 계정)에 동일하게 적용됩니다.${NC}"
while true; do
    COMMON_PASS=$(prompt_secret "패스워드 입력")
    COMMON_PASS_CONFIRM=$(prompt_secret "패스워드 확인")
    [ "$COMMON_PASS" = "$COMMON_PASS_CONFIRM" ] && break
    echo -e "  ${RED}패스워드가 일치하지 않습니다. 다시 입력하세요.${NC}"
done
[ -z "$COMMON_PASS" ] && die "패스워드는 비워둘 수 없습니다."
log_ok "패스워드 설정 완료"

# ── Step 7: 이 노드 IP 및 역할 판별 ─────────────────────────────────
log_step "7단계: 이 노드 IP 설정 및 역할 판별"

_current_ip=$(get_nic_ip "$MGMT_IF")
if [ -n "$_current_ip" ]; then
    echo -e "  ${BLUE}[→]${NC} 현재 감지된 IP: ${_current_ip}"
    MY_IP=$(prompt_input "이 노드의 Management 고정 IP" "$_current_ip")
else
    echo -e "  ${YELLOW}[!]${NC} ${MGMT_IF}에 IP가 없습니다 (초기 상태). 원하는 고정 IP를 입력하세요."
    MY_IP=$(prompt_input "이 노드의 Management 고정 IP (예: 10.0.0.11)" "")
    [ -z "$MY_IP" ] && die "IP를 입력해야 합니다."
fi

MY_ROLE=$(detect_role "$MY_IP")
MY_HOSTNAME=$(gen_hostname "$MY_ROLE" "$MY_IP")

if [ "$MY_ROLE" = "unknown" ]; then
    echo -e "  ${YELLOW}입력한 IP ($MY_IP)가 정의된 범위에 속하지 않습니다.${NC}"
    echo -e "  Controller: $CONTROLLER_RANGE / Compute: $COMPUTE_RANGE / Block: $BLOCK_RANGE"
    die "IP 범위를 다시 확인하세요."
fi

log_ok "이 노드: IP=$MY_IP, 역할=${MY_ROLE}, hostname=${MY_HOSTNAME}"

# ── Step 8: Controller IP 확인 ───────────────────────────────────────
log_step "8단계: Controller IP 설정"
if [ "$MY_ROLE" = "controller" ]; then
    CONTROLLER_IP="$MY_IP"
    log_ok "이 노드가 Controller입니다: $CONTROLLER_IP"
else
    CONTROLLER_IP=$(find_controller_ip 2>/dev/null || true)
    if [ -n "$CONTROLLER_IP" ]; then
        log_ok "Controller 감지: $CONTROLLER_IP"
        prompt_confirm "이 IP를 Controller로 사용하시겠습니까?" || \
            CONTROLLER_IP=$(prompt_input "Controller IP 직접 입력" "")
    else
        echo -e "  ${YELLOW}Controller IP를 자동으로 찾지 못했습니다.${NC}"
        CONTROLLER_IP=$(prompt_input "Controller IP 직접 입력" "")
    fi
    [ -z "$CONTROLLER_IP" ] && die "Controller IP를 입력해야 합니다."

    # Controller 연결 확인
    log_info "Controller(${CONTROLLER_IP}) 연결 확인 중..."
    if ! ping -c1 -W2 "$CONTROLLER_IP" &>/dev/null; then
        log_error "Controller(${CONTROLLER_IP})에 ping 실패 — 네트워크 설정을 확인하세요."
        exit 1
    fi
    log_ok "Controller(${CONTROLLER_IP}) ping 성공"
    for port in 5000 5672 11211; do
        if ! bash -c "echo >/dev/tcp/${CONTROLLER_IP}/${port}" 2>/dev/null; then
            log_error "${CONTROLLER_IP}:${port} 연결 실패 — Controller 배포가 완료됐는지 확인하세요."
            exit 1
        fi
        log_ok "${CONTROLLER_IP}:${port} 연결 확인"
    done
fi

# ── Step 9: Self-service 네트워크 ────────────────────────────────────
log_step "9단계: Self-service 네트워크 설정 (인스턴스 내부 네트워크)"
SELFSERVICE_CIDR=$(prompt_input "Self-service 서브넷 (CIDR)" "172.16.1.0/24")
SELFSERVICE_GW=$(prompt_input "Self-service 게이트웨이" "172.16.1.1")

# ── 요약 및 확인 ─────────────────────────────────────────────────────
echo
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${BOLD}  설정 요약${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "  이 노드 역할    : ${BOLD}${MY_ROLE}${NC} (${MY_HOSTNAME} / ${MY_IP})"
echo -e "  Controller IP  : ${CONTROLLER_IP}"
echo -e "  Management NIC : ${MGMT_IF} | 서브넷: ${MGMT_CIDR} | GW: ${MGMT_GW}"
echo -e "  Provider NIC   : ${PROVIDER_IF} | 서브넷: ${PROVIDER_CIDR} | GW: ${PROVIDER_GW}"
echo -e "  Floating IP 풀 : ${PROVIDER_POOL_START} ~ ${PROVIDER_POOL_END}"
echo -e "  Self-service   : ${SELFSERVICE_CIDR} | GW: ${SELFSERVICE_GW}"
echo -e "  역할 범위       : Controller=${CONTROLLER_RANGE} / Compute=${COMPUTE_RANGE} / Block=${BLOCK_RANGE}"
echo -e "  패스워드        : (설정됨)"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo

prompt_confirm "이 설정으로 저장하시겠습니까?" || { echo "설정을 취소합니다."; exit 0; }

# ── env.sh 저장 ──────────────────────────────────────────────────────
mkdir -p /etc/AutoStack-Epoxy
cat > "$ENV_FILE" <<EOF
# OpenStack 배포 환경 변수 - setup.sh에 의해 자동 생성됨
# 생성 시각: $(date '+%Y-%m-%d %H:%M:%S')

MGMT_IF="${MGMT_IF}"
PROVIDER_IF="${PROVIDER_IF}"
MGMT_CIDR="${MGMT_CIDR}"
MGMT_GW="${MGMT_GW}"
MGMT_DNS="${MGMT_DNS}"
PROVIDER_CIDR="${PROVIDER_CIDR}"
PROVIDER_GW="${PROVIDER_GW}"
PROVIDER_POOL_START="${PROVIDER_POOL_START}"
PROVIDER_POOL_END="${PROVIDER_POOL_END}"
SELFSERVICE_CIDR="${SELFSERVICE_CIDR}"
SELFSERVICE_GW="${SELFSERVICE_GW}"
CONTROLLER_RANGE="${CONTROLLER_RANGE}"
COMPUTE_RANGE="${COMPUTE_RANGE}"
BLOCK_RANGE="${BLOCK_RANGE}"
CONTROLLER_IP="${CONTROLLER_IP}"
MY_IP="${MY_IP}"
MY_ROLE="${MY_ROLE}"
MY_HOSTNAME="${MY_HOSTNAME}"
COMMON_PASS="${COMMON_PASS}"
EOF
chmod 600 "$ENV_FILE"
log_ok "설정 저장 완료: $ENV_FILE"

# ── preflight 실행 ────────────────────────────────────────────────────
echo
if prompt_confirm "지금 환경 검증(preflight)을 실행하시겠습니까?"; then
    bash "${SCRIPT_DIR}/preflight.sh"
else
    echo -e "  나중에 실행: ${BOLD}sudo ./preflight.sh${NC}"
fi
