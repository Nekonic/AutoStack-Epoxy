#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

check_root
[ "$MY_ROLE" = "controller" ] || die "Controller 노드에서 실행하세요."
[ -f /root/admin-openrc ] || die "admin-openrc 없음. Keystone 먼저 설치하세요."
source /root/admin-openrc

# ── 프리셋 정의 (이름:vCPU:RAM_MB:Disk_GB) ────────────────────────────
PRESETS=(
    "m1.tiny:1:512:1"
    "m1.small:1:2048:20"
    "m1.medium:2:4096:40"
    "m1.large:4:8192:80"
    "m1.xlarge:8:16384:160"
)

# ── 기능 ──────────────────────────────────────────────────────────────
list_flavors() {
    echo
    openstack flavor list --long
    echo
}

create_one() {
    local name="$1" vcpu="$2" ram="$3" disk="$4"
    if openstack flavor show "$name" &>/dev/null; then
        log_warn "플레이버 '${name}' 이미 존재합니다. 건너뜀."
        return 0
    fi
    openstack flavor create \
        --vcpus "$vcpu" \
        --ram "$ram" \
        --disk "$disk" \
        --public \
        "$name" > /dev/null
    log_ok "생성: ${name}  (vCPU: ${vcpu}, RAM: ${ram}MB, Disk: ${disk}GB)"
}

create_presets() {
    echo
    printf "  %-14s %6s %10s %10s\n" "이름" "vCPU" "RAM (MB)" "Disk (GB)"
    echo "  ──────────────────────────────────────"
    for preset in "${PRESETS[@]}"; do
        IFS=':' read -r pname pvcpu pram pdisk <<< "$preset"
        printf "  %-14s %6s %10s %10s\n" "$pname" "$pvcpu" "$pram" "$pdisk"
    done
    echo
    prompt_confirm "위 플레이버를 모두 생성하시겠습니까?" || return 0
    echo
    for preset in "${PRESETS[@]}"; do
        IFS=':' read -r pname pvcpu pram pdisk <<< "$preset"
        create_one "$pname" "$pvcpu" "$pram" "$pdisk"
    done
    echo
    log_ok "프리셋 플레이버 생성 완료"
}

create_custom() {
    echo
    local fname fvcpu fram fdisk fswap fephem
    fname=$(prompt_input "플레이버 이름" "")
    [ -z "$fname" ] && return 0
    fvcpu=$(prompt_input "vCPU 수" "2")
    fram=$(prompt_input "RAM (MB)" "4096")
    fdisk=$(prompt_input "루트 디스크 (GB, 0=ephemeral 없음)" "40")
    fswap=$(prompt_input "스왑 (MB, 0=없음)" "0")
    fephem=$(prompt_input "임시 디스크 (GB, 0=없음)" "0")

    local extra_args=()
    [ "$fswap" != "0" ]  && extra_args+=(--swap "$fswap")
    [ "$fephem" != "0" ] && extra_args+=(--ephemeral "$fephem")

    if openstack flavor show "$fname" &>/dev/null; then
        log_warn "플레이버 '${fname}' 이미 존재합니다."
        prompt_confirm "삭제 후 다시 생성하시겠습니까?" || return 0
        openstack flavor delete "$fname"
    fi

    openstack flavor create \
        --vcpus "$fvcpu" \
        --ram "$fram" \
        --disk "$fdisk" \
        --public \
        "${extra_args[@]}" \
        "$fname" > /dev/null
    log_ok "플레이버 '${fname}' 생성 완료 (vCPU: ${fvcpu}, RAM: ${fram}MB, Disk: ${fdisk}GB)"
}

delete_flavor() {
    echo
    openstack flavor list -f value -c Name | sort
    echo
    local fname
    fname=$(prompt_input "삭제할 플레이버 이름" "")
    [ -z "$fname" ] && return 0

    prompt_confirm "플레이버 '${fname}' 를 삭제하시겠습니까?" || return 0
    openstack flavor delete "$fname"
    log_ok "플레이버 '${fname}' 삭제 완료"
}

# ── 메인 루프 ─────────────────────────────────────────────────────────
log_header "플레이버 관리"

while true; do
    echo -e "  ${BOLD}메뉴${NC}"
    echo "    1) 플레이버 목록"
    echo "    2) 프리셋 일괄 생성 (m1.tiny ~ m1.xlarge)"
    echo "    3) 커스텀 플레이버 생성"
    echo "    4) 플레이버 삭제"
    echo "    0) 종료"
    echo

    read -rp "  선택: " menu_choice
    echo
    case "$menu_choice" in
        1) list_flavors ;;
        2) create_presets ;;
        3) create_custom ;;
        4) delete_flavor ;;
        0) break ;;
        *) echo "  올바른 번호를 입력하세요." ;;
    esac
    echo
done
