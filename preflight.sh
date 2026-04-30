#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/openstack-deploy/env.sh"

source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/nic.sh"
source "${SCRIPT_DIR}/lib/check.sh"

check_root
[ -f "$ENV_FILE" ] || die "env.sh 없음. 먼저 setup.sh를 실행하세요."
source "$ENV_FILE"

log_header "AutoStack-Epoxy 환경 검증 (preflight)"
echo -e "  노드: ${BOLD}${MY_HOSTNAME}${NC} (${MY_IP}) | 역할: ${BOLD}${MY_ROLE}${NC}\n"

log_step "공통 항목"
check_os
check_nic_mgmt
check_nic_provider
check_promisc
check_bridge
check_vxlan
check_ip_forward
check_gateway
check_internet
check_ram

log_step "역할별 항목 (${MY_ROLE})"
case "$MY_ROLE" in
    controller)
        check_port_conflicts
        ;;
    compute)
        check_kvm
        ;;
    block)
        check_disk_block
        ;;
esac

# ── 결과 요약 ────────────────────────────────────────────────────────
echo
echo -e "${BOLD}══════════════════════════════════════${NC}"
if [ "$PREFLIGHT_ERRORS" -eq 0 ] && [ "$PREFLIGHT_WARNS" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}결과: 모든 항목 통과 — 배포 준비 완료${NC}"
elif [ "$PREFLIGHT_ERRORS" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}결과: 경고 ${PREFLIGHT_WARNS}개 — 배포 진행 가능 (경고 확인 권장)${NC}"
else
    echo -e "  ${RED}${BOLD}결과: 오류 ${PREFLIGHT_ERRORS}개, 경고 ${PREFLIGHT_WARNS}개 — 오류 해결 후 배포하세요${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════${NC}"

[ "$PREFLIGHT_ERRORS" -gt 0 ] && exit 1 || exit 0
