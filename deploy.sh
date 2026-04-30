#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/AutoStack-Epoxy/env.sh"

source "${SCRIPT_DIR}/lib/ui.sh"

check_root
[ -f "$ENV_FILE" ] || die "env.sh 없음. 먼저 setup.sh를 실행하세요."
source "$ENV_FILE"

run_script() {
    local script="${SCRIPT_DIR}/scripts/$1"
    [ -f "$script" ] || die "스크립트 없음: $script"
    log_info "실행: $1"
    bash "$script" "${@:2}"
}

# --test 플래그: 배포 없이 테스트만 실행
if [ "${1:-}" = "--test" ]; then
    bash "${SCRIPT_DIR}/test.sh"
    exit $?
fi

log_header "AutoStack-Epoxy 배포 시작"
echo -e "  노드: ${BOLD}${MY_HOSTNAME}${NC} (${MY_IP}) | 역할: ${BOLD}${MY_ROLE}${NC}\n"

case "$MY_ROLE" in
    controller)
        run_script 00_common.sh
        run_script 01_keystone.sh
        run_script 02_glance.sh
        run_script 03_placement.sh
        run_script 04_nova.sh
        run_script 05_neutron.sh
        run_script 06_horizon.sh
        run_script 07_cinder.sh
        echo
        log_header "Controller 배포 완료"
        echo -e "  Compute 노드 배포 완료 후 아래 명령으로 Compute 노드를 등록하세요:"
        echo -e "  ${BOLD}sudo ./scripts/04_nova.sh discover${NC}"
        echo
        echo -e "  Horizon 접속: ${BOLD}http://${MY_IP}/horizon${NC}"
        echo -e "  도메인: Default | 사용자: admin | 패스워드: (설정한 값)"
        ;;
    compute)
        run_script 00_common.sh
        run_script 04_nova.sh
        run_script 05_neutron.sh
        echo
        log_header "Compute 노드 배포 완료"
        echo -e "  Controller에서 아래 명령으로 이 노드를 등록하세요:"
        echo -e "  ${BOLD}sudo ./scripts/04_nova.sh discover${NC}"
        ;;
    block)
        run_script 00_common.sh
        run_script 07_cinder.sh
        echo
        log_header "Block 노드 배포 완료"
        ;;
    *)
        die "알 수 없는 역할: $MY_ROLE (setup.sh를 다시 실행하세요)"
        ;;
esac

# 배포 완료 후 테스트 자동 실행
echo
if prompt_confirm "배포 완료 — 지금 검증 테스트를 실행하시겠습니까?"; then
    bash "${SCRIPT_DIR}/test.sh"
else
    echo -e "  나중에 실행: ${BOLD}sudo ./test.sh${NC}  또는  ${BOLD}sudo ./deploy.sh --test${NC}"
fi
