#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

check_root
[ "$MY_ROLE" = "controller" ] || die "Controller 노드에서 실행하세요."
[ -f /root/admin-openrc ] || die "admin-openrc 없음. Keystone 먼저 설치하세요."
source /root/admin-openrc

# ── Ubuntu cloud image 목록 ────────────────────────────────────────────
UBUNTU_DISPLAY=(
    "Ubuntu 24.04 LTS (Noble)"
    "Ubuntu 22.04 LTS (Jammy)"
    "Ubuntu 20.04 LTS (Focal)"
)
UBUNTU_GLANCE_NAMES=(
    "ubuntu-24.04"
    "ubuntu-22.04"
    "ubuntu-20.04"
)
UBUNTU_URLS=(
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
)

# ── 유틸 ──────────────────────────────────────────────────────────────
download_file() {
    local url="$1" dest="$2"
    if command -v wget &>/dev/null; then
        wget -O "$dest" --show-progress "$url"
    else
        curl -L --progress-bar -o "$dest" "$url"
    fi
}

upload_to_glance() {
    local name="$1" path="$2" fmt="$3"
    shift 3

    if openstack image show "$name" &>/dev/null; then
        log_warn "이미지 '${name}' 이미 존재합니다."
        prompt_confirm "삭제 후 다시 업로드하시겠습니까?" || return 0
        openstack image delete "$name"
    fi

    log_info "Glance 업로드 중: $name"
    openstack image create "$name" \
        --file "$path" \
        --disk-format "$fmt" \
        --container-format bare \
        --public \
        "$@"
    log_ok "이미지 '${name}' 등록 완료"
}

# ── 기능 ──────────────────────────────────────────────────────────────
list_images() {
    echo
    openstack image list --long
    echo
}

download_ubuntu() {
    echo
    echo -e "  Ubuntu 버전 선택:"
    for i in "${!UBUNTU_DISPLAY[@]}"; do
        echo "    $((i+1))) ${UBUNTU_DISPLAY[$i]}"
    done
    echo

    local choice
    while true; do
        read -rp "  번호 선택 [1-${#UBUNTU_DISPLAY[@]}]: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] && \
            [ "$choice" -ge 1 ] && [ "$choice" -le "${#UBUNTU_DISPLAY[@]}" ] && break
        echo "  올바른 번호를 입력하세요."
    done

    local idx=$((choice-1))
    local name="${UBUNTU_GLANCE_NAMES[$idx]}"
    local url="${UBUNTU_URLS[$idx]}"
    local tmpfile="/tmp/$(basename "$url")"

    log_info "다운로드: $url"
    download_file "$url" "$tmpfile"

    upload_to_glance "$name" "$tmpfile" "qcow2" \
        --property os_distro=ubuntu \
        --property hw_disk_bus=virtio \
        --property hw_vif_model=virtio
    rm -f "$tmpfile"
}

upload_windows() {
    echo
    echo -e "  ${YELLOW}Windows 이미지 안내${NC}"
    echo -e "  VirtIO 드라이버와 cloudbase-init 이 포함된 QCOW2 파일이 필요합니다."
    echo -e "  미리 빌드된 이미지: https://cloudbase.it/windows-cloud-images/"
    echo

    local imgpath
    imgpath=$(prompt_input "이미지 파일 경로 (예: /root/windows-server-2022.qcow2)" "")
    [ -z "$imgpath" ] && return 0
    [ -f "$imgpath" ] || { log_error "파일 없음: $imgpath"; return 1; }

    local imgname diskfmt
    imgname=$(prompt_input "Glance 이미지 이름" "windows-server-2022")
    diskfmt=$(prompt_input "디스크 포맷 (qcow2/raw)" "qcow2")

    upload_to_glance "$imgname" "$imgpath" "$diskfmt" \
        --property os_type=windows \
        --property hw_disk_bus=virtio \
        --property hw_vif_model=virtio \
        --property os_require_quiesce=yes
}

upload_custom() {
    echo
    local imgpath imgname diskfmt
    imgpath=$(prompt_input "이미지 파일 경로" "")
    [ -z "$imgpath" ] && return 0
    [ -f "$imgpath" ] || { log_error "파일 없음: $imgpath"; return 1; }

    imgname=$(prompt_input "Glance 이미지 이름" "$(basename "$imgpath" | cut -d. -f1)")
    diskfmt=$(prompt_input "디스크 포맷 (qcow2/raw/vmdk/iso)" "qcow2")

    upload_to_glance "$imgname" "$imgpath" "$diskfmt"
}

delete_image() {
    echo
    openstack image list -f value -c Name -c ID | sort | column -t
    echo
    local imgname
    imgname=$(prompt_input "삭제할 이미지 이름 또는 ID" "")
    [ -z "$imgname" ] && return 0

    prompt_confirm "이미지 '${imgname}' 를 삭제하시겠습니까?" || return 0
    openstack image delete "$imgname"
    log_ok "이미지 '${imgname}' 삭제 완료"
}

# ── 메인 루프 ─────────────────────────────────────────────────────────
log_header "이미지 관리"

while true; do
    echo -e "  ${BOLD}메뉴${NC}"
    echo "    1) 이미지 목록"
    echo "    2) Ubuntu 이미지 다운로드 및 등록"
    echo "    3) Windows 이미지 업로드 (로컬 파일)"
    echo "    4) 커스텀 이미지 업로드 (로컬 파일)"
    echo "    5) 이미지 삭제"
    echo "    0) 종료"
    echo

    read -rp "  선택: " menu_choice
    echo
    case "$menu_choice" in
        1) list_images ;;
        2) download_ubuntu ;;
        3) upload_windows ;;
        4) upload_custom ;;
        5) delete_image ;;
        0) break ;;
        *) echo "  올바른 번호를 입력하세요." ;;
    esac
    echo
done
