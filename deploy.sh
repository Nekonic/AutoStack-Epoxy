#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/AutoStack-Epoxy/env.sh"
STATE_FILE="/etc/AutoStack-Epoxy/deploy-state"

source "${SCRIPT_DIR}/lib/ui.sh"

show_help() {
    cat <<EOF

사용법: sudo ./deploy.sh [옵션]

옵션:
  -h, --help             이 도움말 출력
  -t, --test             배포 없이 검증 테스트만 실행
  -r, --reset            설치된 OpenStack 전체 제거 후 초기화 (env.sh 유지)
  -s, --status           현재 배포 진행 상태 출력
      --from <스크립트>    지정 스크립트부터 재실행
      --skip <스크립트>    지정 스크립트를 완료로 표시하고 건너뜀

예시:
  sudo ./deploy.sh
  sudo ./deploy.sh -r
  sudo ./deploy.sh --from 05_neutron.sh
  sudo ./deploy.sh --skip 00_common.sh
  sudo ./deploy.sh -s
  sudo ./deploy.sh -t
EOF
}

reset_deployment() {
    echo
    log_warn "전체 초기화 — 설치된 OpenStack 패키지/서비스/DB를 모두 제거합니다."
    log_warn "/etc/AutoStack-Epoxy/env.sh 는 유지됩니다."
    echo
    prompt_confirm "계속하시겠습니까? 되돌릴 수 없습니다." || { echo "  취소됨."; exit 0; }
    echo

    log_step "서비스 중지"
    for svc in \
        neutron-server neutron-openvswitch-agent neutron-l3-agent \
        neutron-dhcp-agent neutron-metadata-agent \
        nova-api nova-conductor nova-novncproxy nova-scheduler nova-compute \
        cinder-api cinder-scheduler cinder-volume tgt \
        glance-api placement-api apache2 memcached etcd
    do
        systemctl stop "$svc" 2>/dev/null && log_ok "중지: $svc" || true
    done

    log_step "패키지 제거"
    case "$MY_ROLE" in
        controller)
            DEBIAN_FRONTEND=noninteractive apt purge -y \
                keystone python3-keystone \
                glance python3-glance \
                placement-api python3-placement \
                nova-api nova-conductor nova-novncproxy nova-scheduler python3-nova \
                neutron-server neutron-plugin-ml2 neutron-openvswitch-agent \
                neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent python3-neutron \
                openstack-dashboard \
                cinder-api cinder-scheduler python3-cinder \
                2>/dev/null || true
            ;;
        compute)
            DEBIAN_FRONTEND=noninteractive apt purge -y \
                nova-compute python3-nova \
                neutron-openvswitch-agent python3-neutron \
                2>/dev/null || true
            ;;
        block)
            DEBIAN_FRONTEND=noninteractive apt purge -y \
                cinder-volume python3-cinder tgt \
                2>/dev/null || true
            ;;
    esac
    apt autoremove -y 2>/dev/null || true
    log_ok "패키지 제거 완료"

    log_step "설정/데이터 디렉토리 삭제"
    rm -rf \
        /etc/keystone /etc/glance /etc/placement /etc/nova \
        /etc/neutron /etc/cinder /etc/openstack-dashboard \
        /var/lib/keystone /var/lib/glance /var/lib/placement /var/lib/nova \
        /var/lib/neutron /var/lib/cinder \
        /root/admin-openrc
    log_ok "설정/데이터 삭제 완료"

    if [ "$MY_ROLE" = "controller" ]; then
        log_step "데이터베이스 삭제"
        mysql -uroot 2>/dev/null <<'EOSQL' || log_warn "DB 삭제 실패 (MariaDB 미설치일 수 있음)"
DROP DATABASE IF EXISTS keystone;
DROP DATABASE IF EXISTS glance;
DROP DATABASE IF EXISTS placement;
DROP DATABASE IF EXISTS nova;
DROP DATABASE IF EXISTS nova_api;
DROP DATABASE IF EXISTS nova_cell0;
DROP DATABASE IF EXISTS neutron;
DROP DATABASE IF EXISTS cinder;
EOSQL
        log_ok "DB 삭제 완료"

        log_step "RabbitMQ openstack 사용자 삭제"
        rabbitmqctl delete_user openstack 2>/dev/null \
            && log_ok "RabbitMQ 사용자 삭제 완료" \
            || log_warn "RabbitMQ 사용자 없음 (건너뜀)"
    fi

    log_step "OVS 브리지 정리"
    if command -v ovs-vsctl &>/dev/null; then
        ovs-vsctl del-port br-provider "$PROVIDER_IF" 2>/dev/null || true
        ovs-vsctl del-br br-provider 2>/dev/null || true
        log_ok "OVS 브리지 정리 완료"
    fi

    if [ "$MY_ROLE" = "block" ]; then
        log_step "LVM VG 삭제 (cinder-volumes)"
        if vgs cinder-volumes &>/dev/null; then
            vgremove -f cinder-volumes \
                && log_ok "cinder-volumes VG 삭제 완료" \
                || log_warn "VG 삭제 실패 (수동 확인 필요: vgremove -f cinder-volumes)"
        else
            log_ok "cinder-volumes VG 없음 (건너뜀)"
        fi
    fi

    rm -f "$STATE_FILE"
    echo
    log_header "초기화 완료"
    echo -e "  다시 배포하려면: ${BOLD}sudo ./deploy.sh${NC}"
    echo
    exit 0
}

# ── 인자 파싱 ─────────────────────────────────────────────────────────
ARG_MODE="deploy"
ARG_FROM=""
ARG_SKIP=""

case "${1:-}" in
    -h|--help)   show_help; exit 0 ;;
    -t|--test)   ARG_MODE="test" ;;
    -r|--reset)  ARG_MODE="reset" ;;
    -s|--status) ARG_MODE="status" ;;
    --from)
        ARG_MODE="from"
        ARG_FROM="${2:-}"
        [ -z "$ARG_FROM" ] && { echo "사용법: sudo ./deploy.sh --from <스크립트명>"; exit 1; }
        ;;
    --skip)
        ARG_MODE="skip"
        ARG_SKIP="${2:-}"
        [ -z "$ARG_SKIP" ] && { echo "사용법: sudo ./deploy.sh --skip <스크립트명>"; exit 1; }
        ;;
    "") ;;
    *) echo "알 수 없는 옵션: ${1}"; show_help; exit 1 ;;
esac

check_root
[ -f "$ENV_FILE" ] || die "env.sh 없음. 먼저 setup.sh를 실행하세요."
source "$ENV_FILE"

# ── --test ────────────────────────────────────────────────────────────
if [ "$ARG_MODE" = "test" ]; then
    bash "${SCRIPT_DIR}/test.sh"
    exit $?
fi

# ── 역할별 스크립트 목록 ──────────────────────────────────────────────
case "$MY_ROLE" in
    controller) SCRIPTS=(00_common.sh 01_keystone.sh 02_glance.sh 03_placement.sh 04_nova.sh 05_neutron.sh 06_horizon.sh 07_cinder.sh) ;;
    compute)    SCRIPTS=(00_common.sh 04_nova.sh 05_neutron.sh) ;;
    block)      SCRIPTS=(00_common.sh 07_cinder.sh) ;;
    *)          die "알 수 없는 역할: $MY_ROLE (setup.sh를 다시 실행하세요)" ;;
esac

# ── --reset ───────────────────────────────────────────────────────────
[ "$ARG_MODE" = "reset" ] && reset_deployment

# ── --status ──────────────────────────────────────────────────────────
if [ "$ARG_MODE" = "status" ]; then
    echo
    echo -e "${BOLD}배포 상태: ${MY_HOSTNAME} (${MY_IP}) | 역할: ${MY_ROLE}${NC}\n"
    all_done=true
    for script in "${SCRIPTS[@]}"; do
        if grep -qx "$script" "$STATE_FILE" 2>/dev/null; then
            log_ok "$script"
        else
            echo -e "  ${YELLOW}[-]${NC} $script"
            all_done=false
        fi
    done
    echo
    $all_done \
        && echo -e "  ${GREEN}모든 단계 완료${NC}" \
        || echo -e "  ${YELLOW}배포 미완료 — sudo ./deploy.sh 로 이어서 실행${NC}"
    echo
    exit 0
fi

# ── --skip ────────────────────────────────────────────────────────────
if [ "$ARG_MODE" = "skip" ]; then
    found=0
    for s in "${SCRIPTS[@]}"; do
        [ "$s" = "$ARG_SKIP" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && die "--skip: 스크립트를 찾을 수 없습니다: $ARG_SKIP\n  이 역할(${MY_ROLE})의 스크립트: ${SCRIPTS[*]}"

    if grep -qx "$ARG_SKIP" "$STATE_FILE" 2>/dev/null; then
        log_warn "${ARG_SKIP} 은 이미 완료 상태입니다."
    else
        echo "$ARG_SKIP" >> "$STATE_FILE"
        log_ok "${ARG_SKIP} 건너뜀으로 표시됨"
    fi
    echo -e "  이어서 실행: ${BOLD}sudo ./deploy.sh${NC}"
    echo
    exit 0
fi

# ── --from ────────────────────────────────────────────────────────────
if [ "$ARG_MODE" = "from" ]; then
    found=0
    for s in "${SCRIPTS[@]}"; do
        [ "$s" = "$ARG_FROM" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && die "--from: 스크립트를 찾을 수 없습니다: $ARG_FROM\n  이 역할(${MY_ROLE})의 스크립트: ${SCRIPTS[*]}"

    new_state=()
    for s in "${SCRIPTS[@]}"; do
        [ "$s" = "$ARG_FROM" ] && break
        grep -qx "$s" "$STATE_FILE" 2>/dev/null && new_state+=("$s")
    done
    if [ ${#new_state[@]} -gt 0 ]; then
        printf '%s\n' "${new_state[@]}" > "$STATE_FILE"
    else
        rm -f "$STATE_FILE"
    fi
    log_ok "${ARG_FROM}부터 재실행합니다."
    echo
fi

# ── run_script ────────────────────────────────────────────────────────
run_script() {
    local name="$1"
    local script="${SCRIPT_DIR}/scripts/${name}"
    [ -f "$script" ] || die "스크립트 없음: $script"

    if grep -qx "$name" "$STATE_FILE" 2>/dev/null; then
        log_ok "건너뜀 (이미 완료): $name"
        return 0
    fi

    log_info "실행: $name"
    if bash "$script" "${@:2}"; then
        echo "$name" >> "$STATE_FILE"
    else
        local exit_code=$?
        echo
        log_error "${name} 실패 (exit ${exit_code})"
        log_step "최근 시스템 로그 (journalctl -xe)"
        journalctl -xe --no-pager -n 20 2>/dev/null || true
        echo
        echo -e "  이어서 실행:       ${BOLD}sudo ./deploy.sh${NC}"
        echo -e "  이 단계 건너뛰기:  ${BOLD}sudo ./deploy.sh --skip ${name}${NC}"
        exit "$exit_code"
    fi
}

# ── Compute/Block: 컨트롤러 연결 사전 확인 ───────────────────────────
if [ "$MY_ROLE" != "controller" ]; then
    log_header "컨트롤러 연결 확인"

    # 기본 네트워크
    if ! ping -c1 -W2 controller &>/dev/null; then
        log_error "controller에 ping 실패 — /etc/hosts 또는 네트워크 설정을 확인하세요."
        exit 1
    fi
    log_ok "controller ping 성공"

    # Keystone (5000), RabbitMQ (5672), Memcached (11211)
    for port in 5000 5672 11211; do
        if ! bash -c "echo >/dev/tcp/controller/${port}" 2>/dev/null; then
            log_error "controller:${port} 연결 실패 — Controller 배포가 완료됐는지 확인하세요."
            exit 1
        fi
        log_ok "controller:${port} 연결 확인"
    done

    log_header "컨트롤러 연결 정상"
fi

# ── 배포 시작 ─────────────────────────────────────────────────────────
log_header "AutoStack-Epoxy 배포 시작"
echo -e "  노드: ${BOLD}${MY_HOSTNAME}${NC} (${MY_IP}) | 역할: ${BOLD}${MY_ROLE}${NC}"
if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    echo -e "  ${YELLOW}이전 진행 상태 감지 — 완료된 단계는 건너뜁니다.${NC}"
    echo -e "  상태 확인: ${BOLD}sudo ./deploy.sh -s${NC}  |  전체 초기화: ${BOLD}sudo ./deploy.sh -r${NC}"
fi
echo

for script in "${SCRIPTS[@]}"; do
    run_script "$script"
done

rm -f "$STATE_FILE"

echo
case "$MY_ROLE" in
    controller)
        log_header "Controller 배포 완료"
        echo -e "  Compute 노드 배포 완료 후 아래 명령으로 Compute 노드를 등록하세요:"
        echo -e "  ${BOLD}sudo ./scripts/04_nova.sh discover${NC}"
        echo
        echo -e "  Horizon 접속: ${BOLD}http://${MY_IP}/horizon${NC}"
        echo -e "  도메인: Default | 사용자: admin | 패스워드: (설정한 값)"
        ;;
    compute)
        log_header "Compute 노드 배포 완료"
        echo -e "  Controller에서 아래 명령으로 이 노드를 등록하세요:"
        echo -e "  ${BOLD}sudo ./scripts/04_nova.sh discover${NC}"
        ;;
    block)
        log_header "Block 노드 배포 완료"
        ;;
esac

echo
if prompt_confirm "배포 완료 — 지금 검증 테스트를 실행하시겠습니까?"; then
    bash "${SCRIPT_DIR}/test.sh"
else
    echo -e "  나중에 실행: ${BOLD}sudo ./deploy.sh -t${NC}"
fi
