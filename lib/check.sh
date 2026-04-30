#!/bin/bash

_pass() { log_ok "$1"; }
_warn() { log_warn "$1"; }
_fail() { log_error "$1"; }

check_os() {
    local ver codename
    ver=$(lsb_release -rs 2>/dev/null)
    codename=$(lsb_release -cs 2>/dev/null)
    if [[ "$ver" == "24.04" && "$codename" == "noble" ]]; then
        _pass "OS: Ubuntu 24.04 LTS (Noble)"
    else
        _fail "OS: Ubuntu 24.04 필요 (현재: Ubuntu $ver $codename)"
    fi
}

check_nic_mgmt() {
    if ! nic_exists "$MGMT_IF"; then
        _fail "Management NIC ($MGMT_IF): 존재하지 않음"
        return
    fi
    local ip
    ip=$(get_nic_ip "$MGMT_IF")
    if [ -z "$ip" ]; then
        _fail "Management NIC ($MGMT_IF): IP 미할당"
    else
        _pass "Management NIC ($MGMT_IF): $ip"
    fi
}

check_nic_provider() {
    if nic_exists "$PROVIDER_IF"; then
        _pass "Provider NIC ($PROVIDER_IF): 존재함"
    else
        _fail "Provider NIC ($PROVIDER_IF): 존재하지 않음"
    fi
}

check_promisc() {
    if ! nic_exists "$PROVIDER_IF"; then
        _fail "Promiscuous 테스트 불가 — Provider NIC ($PROVIDER_IF) 없음"
        return
    fi
    if test_promisc "$PROVIDER_IF"; then
        _pass "Promiscuous mode ($PROVIDER_IF): 지원"
    else
        _fail "Promiscuous mode ($PROVIDER_IF): 불가 — Neutron 동작 불가 (VM 설정에서 무차별 모드 활성화 필요)"
    fi
}

check_bridge() {
    ip link add br-os-check type bridge 2>/dev/null
    if ip link show br-os-check &>/dev/null; then
        ip link delete br-os-check 2>/dev/null
        _pass "Bridge 생성 지원: 확인"
    else
        _fail "Bridge 생성 불가 — bridge 커널 모듈 확인 필요"
    fi
}

check_vxlan() {
    ip link add vxlan-os-check type vxlan id 9998 dev "$MGMT_IF" dport 4789 2>/dev/null
    if ip link show vxlan-os-check &>/dev/null; then
        ip link delete vxlan-os-check 2>/dev/null
        _pass "VXLAN 지원: 확인"
    else
        _fail "VXLAN 불가 — vxlan 커널 모듈 확인 필요"
    fi
}

check_ip_forward() {
    local val
    val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$val" = "1" ]; then
        _pass "IP Forwarding: 활성화"
    else
        _warn "IP Forwarding: 비활성화 (배포 시 자동 설정됨)"
    fi
}

check_gateway() {
    if ping -c1 -W2 "$MGMT_GW" &>/dev/null; then
        _pass "Management 게이트웨이 ($MGMT_GW): 응답"
    else
        _warn "Management 게이트웨이 ($MGMT_GW): 응답 없음"
    fi
}

check_internet() {
    if ping -c1 -W3 8.8.8.8 &>/dev/null; then
        _pass "인터넷 연결: 확인"
    else
        _warn "인터넷 연결: 없음 — apt 패키지 설치 불가"
    fi
}

check_ram() {
    local total_kb total_gb required=0
    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    total_gb=$((total_kb / 1024 / 1024))
    case "$MY_ROLE" in
        controller) required=8 ;;
        compute)    required=4 ;;
        block)      required=2 ;;
    esac
    if [ "$total_gb" -ge "$required" ]; then
        _pass "RAM: ${total_gb}GB (최소 ${required}GB)"
    else
        _warn "RAM: ${total_gb}GB — 최소 ${required}GB 권장"
    fi
}

check_kvm() {
    if [ -e /dev/kvm ]; then
        _pass "KVM: /dev/kvm 존재"
    else
        _warn "KVM: /dev/kvm 없음 — virt_type=qemu 로 동작 (성능 저하)"
    fi
}

check_disk_block() {
    local found=0
    for disk in /dev/sd? /dev/vd? /dev/nvme?n?; do
        [ -b "$disk" ] || continue
        local mounted pv_used
        mounted=$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -c '/' || true)
        pv_used=$(pvs --noheadings -o pv_name 2>/dev/null | grep -c "^[[:space:]]*${disk}" || true)
        if [ "$mounted" -eq 0 ] && [ "$pv_used" -eq 0 ]; then
            local size
            size=$(lsblk -dno SIZE "$disk" 2>/dev/null)
            _pass "LVM용 미사용 디스크: $disk ($size)"
            found=1
            break
        fi
    done
    [ "$found" -eq 0 ] && _fail "LVM용 미사용 디스크 없음 — Block 노드에 추가 디스크 필요"
}

check_port_conflicts() {
    local ports=(3306 5672 11211 2379 5000 8774 8778 9292 9696 8776 80)
    local conflicts=()
    for port in "${ports[@]}"; do
        ss -tlnp 2>/dev/null | grep -q ":${port} " && conflicts+=("$port")
    done
    if [ ${#conflicts[@]} -eq 0 ]; then
        _pass "포트 충돌: 없음"
    else
        _warn "이미 사용 중인 포트: ${conflicts[*]}"
    fi
}
