#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/openstack-deploy/env.sh"

source "${SCRIPT_DIR}/lib/ui.sh"
[ -f "$ENV_FILE" ] || die "env.sh 없음. setup.sh를 먼저 실행하세요."
source "$ENV_FILE"

PASS=0; FAIL=0; SKIP=0

_test_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
_test_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
_test_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
_test_info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }

# 서비스 활성화 여부
_check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        _test_pass "서비스 실행 중: $svc"
    else
        _test_fail "서비스 중단됨: $svc (systemctl status $svc 로 확인)"
    fi
}

# HTTP 응답 코드 확인
_check_http() {
    local url="$1" expect="${2:-200}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")
    if [ "$code" = "$expect" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        _test_pass "HTTP 응답: $url → $code"
    else
        _test_fail "HTTP 응답 실패: $url → $code (예상: $expect)"
    fi
}

# openstack CLI 명령 실행 후 키워드 포함 여부
_check_os_cmd() {
    local desc="$1" keyword="$2"
    shift 2
    local out
    if out=$("$@" 2>&1) && echo "$out" | grep -q "$keyword"; then
        _test_pass "$desc"
    else
        _test_fail "$desc"
        _test_info "출력: $(echo "$out" | head -3)"
    fi
}

# ── 인프라 (Controller 전용) ──────────────────────────────────────────
test_infrastructure() {
    echo -e "\n${BOLD}[인프라]${NC}"

    # MariaDB
    if mysql -uroot -e "SHOW DATABASES;" &>/dev/null; then
        local dbs
        dbs=$(mysql -uroot -e "SHOW DATABASES;" 2>/dev/null | grep -E "keystone|glance|nova|neutron|placement|cinder" | tr '\n' ' ')
        _test_pass "MariaDB 접속 가능 | OpenStack DB: ${dbs:-없음}"
    else
        _test_fail "MariaDB 접속 실패"
    fi

    # RabbitMQ
    if rabbitmqctl status &>/dev/null; then
        local users
        users=$(rabbitmqctl list_users 2>/dev/null | grep openstack | awk '{print $1}')
        _test_pass "RabbitMQ 실행 중 | openstack 사용자: ${users:-미확인}"
    else
        _test_fail "RabbitMQ 접속 실패"
    fi

    # Memcached
    if echo "stats" | nc -q1 "$MY_IP" 11211 2>/dev/null | grep -q "STAT"; then
        _test_pass "Memcached 응답 정상"
    else
        _test_fail "Memcached 응답 없음"
    fi

    # etcd
    if etcdctl --endpoints="http://${MY_IP}:2379" endpoint health 2>/dev/null | grep -q "healthy"; then
        _test_pass "etcd 클러스터 healthy"
    else
        _test_fail "etcd 응답 실패"
    fi
}

# ── Keystone ──────────────────────────────────────────────────────────
test_keystone() {
    echo -e "\n${BOLD}[Keystone]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    _check_service apache2

    # 토큰 발급
    local token_out
    if token_out=$(openstack token issue 2>&1) && echo "$token_out" | grep -q "expires"; then
        local expires
        expires=$(echo "$token_out" | awk '/expires/ {print $4}')
        _test_pass "토큰 발급 성공 (만료: $expires)"
    else
        _test_fail "토큰 발급 실패"
        return
    fi

    # 서비스 카탈로그
    local svc_count
    svc_count=$(openstack service list -f value -c Name 2>/dev/null | wc -l)
    _test_pass "서비스 카탈로그: ${svc_count}개"

    # 엔드포인트
    local ep_count
    ep_count=$(openstack endpoint list -f value -c ID 2>/dev/null | wc -l)
    _test_pass "엔드포인트: ${ep_count}개"

    # 프로젝트 확인
    _check_os_cmd "service 프로젝트 존재" "service" openstack project show service
    _check_os_cmd "admin 프로젝트 존재" "admin"   openstack project show admin
}

# ── Glance ────────────────────────────────────────────────────────────
test_glance() {
    echo -e "\n${BOLD}[Glance]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    _check_service glance-api
    _check_http "http://controller:9292/"

    local img_count
    img_count=$(openstack image list -f value -c ID 2>/dev/null | wc -l)
    if [ "$img_count" -gt 0 ]; then
        local img_names
        img_names=$(openstack image list -f value -c Name 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
        _test_pass "이미지 ${img_count}개 등록됨: $img_names"
    else
        _test_fail "등록된 이미지 없음 (cirros 업로드 확인 필요)"
    fi

    # Glance API 직접 테스트
    local token
    token=$(openstack token issue -f value -c id 2>/dev/null)
    if curl -s -H "X-Auth-Token: $token" http://controller:9292/v2/images 2>/dev/null | grep -q "images"; then
        _test_pass "Glance API v2 응답 정상"
    else
        _test_fail "Glance API v2 응답 실패"
    fi
}

# ── Placement ─────────────────────────────────────────────────────────
test_placement() {
    echo -e "\n${BOLD}[Placement]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    _check_http "http://controller:8778/"

    # placement-status
    if placement-status upgrade check 2>/dev/null | grep -q "Success"; then
        _test_pass "placement-status upgrade check: 모두 Success"
    else
        _test_fail "placement-status upgrade check 실패"
    fi

    # Resource class 목록
    local rc_count
    rc_count=$(openstack --os-placement-api-version 1.2 resource class list -f value -c name 2>/dev/null | wc -l)
    _test_pass "Resource class: ${rc_count}개"
}

# ── Nova ──────────────────────────────────────────────────────────────
test_nova_controller() {
    echo -e "\n${BOLD}[Nova - Controller]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    for svc in nova-api nova-scheduler nova-conductor nova-novncproxy; do
        _check_service "$svc"
    done

    _check_http "http://controller:8774/"

    # Cell 목록
    local cell_out
    if cell_out=$(su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova 2>/dev/null) \
        && echo "$cell_out" | grep -q "cell0"; then
        local cell_count
        cell_count=$(echo "$cell_out" | grep -c "| cell" || true)
        _test_pass "Cell 구성 정상 (cell0, cell1 포함: ${cell_count}개)"
    else
        _test_fail "Cell 구성 실패"
    fi

    # Compute 서비스 목록
    local compute_svcs
    compute_svcs=$(openstack compute service list -f value -c Binary -c State 2>/dev/null)
    local up_count down_count
    up_count=$(echo "$compute_svcs" | grep -c "up" || true)
    down_count=$(echo "$compute_svcs" | grep -c "down" || true)
    if [ "$up_count" -gt 0 ]; then
        _test_pass "Nova 서비스 up: ${up_count}개, down: ${down_count}개"
    else
        _test_fail "Nova 서비스 up 상태 없음"
    fi

    # nova-compute 노드 등록 확인
    local compute_nodes
    compute_nodes=$(openstack compute service list --service nova-compute -f value -c Host 2>/dev/null | tr '\n' ' ')
    if [ -n "$compute_nodes" ]; then
        _test_pass "등록된 Compute 노드: $compute_nodes"
    else
        _test_fail "등록된 Compute 노드 없음 — './scripts/04_nova.sh discover' 실행 필요"
    fi

    # nova-status
    if nova-status upgrade check 2>/dev/null | grep -v "Warning" | grep -q "Success"; then
        _test_pass "nova-status upgrade check 통과"
    else
        _test_fail "nova-status upgrade check 실패 (Compute 노드 미등록 상태일 수 있음)"
    fi
}

test_nova_compute() {
    echo -e "\n${BOLD}[Nova - Compute]${NC}"
    _check_service nova-compute

    local virt_type
    virt_type=$(crudini --get /etc/nova/nova.conf libvirt virt_type 2>/dev/null || echo "unknown")
    _test_info "virt_type: $virt_type"

    if [ "$virt_type" = "kvm" ]; then
        _test_pass "KVM 가속 사용 중"
    else
        _test_pass "QEMU 에뮬레이션 사용 중 (KVM 없음)"
    fi

    if nova-compute --version &>/dev/null 2>&1 || nova-compute --version 2>&1 | grep -qE "[0-9]+\.[0-9]+"; then
        _test_pass "nova-compute 바이너리 정상"
    fi
}

# ── Neutron ───────────────────────────────────────────────────────────
test_neutron_controller() {
    echo -e "\n${BOLD}[Neutron - Controller]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    for svc in neutron-server neutron-openvswitch-agent neutron-dhcp-agent \
               neutron-metadata-agent neutron-l3-agent; do
        _check_service "$svc"
    done

    _check_http "http://controller:9696/"

    # 에이전트 상태
    local agent_out
    agent_out=$(openstack network agent list -f value -c "Agent Type" -c Alive 2>/dev/null)
    local alive_count dead_count
    alive_count=$(echo "$agent_out" | grep -c ":-)" || true)
    dead_count=$(echo "$agent_out"  | grep -c "xxx" || true)

    if [ "$alive_count" -gt 0 ] && [ "$dead_count" -eq 0 ]; then
        _test_pass "Neutron 에이전트 전체 alive: ${alive_count}개"
    elif [ "$dead_count" -gt 0 ]; then
        _test_fail "비정상 에이전트: ${dead_count}개 (openstack network agent list 확인)"
    else
        _test_fail "에이전트 응답 없음"
    fi

    # OVS 브리지
    if ovs-vsctl br-exists br-provider 2>/dev/null; then
        local ports
        ports=$(ovs-vsctl list-ports br-provider 2>/dev/null | tr '\n' ' ')
        _test_pass "OVS br-provider 존재 | 포트: ${ports:-없음}"
    else
        _test_fail "OVS br-provider 없음"
    fi
}

test_neutron_compute() {
    echo -e "\n${BOLD}[Neutron - Compute]${NC}"
    _check_service neutron-openvswitch-agent

    if ovs-vsctl br-exists br-provider 2>/dev/null; then
        local ports
        ports=$(ovs-vsctl list-ports br-provider 2>/dev/null | tr '\n' ' ')
        _test_pass "OVS br-provider 존재 | 포트: ${ports:-없음}"
    else
        _test_fail "OVS br-provider 없음"
    fi
}

# ── Horizon ───────────────────────────────────────────────────────────
test_horizon() {
    echo -e "\n${BOLD}[Horizon]${NC}"
    _check_service apache2

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "http://localhost/horizon/" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|301|302)$ ]]; then
        _test_pass "Horizon 응답: HTTP $code"
    else
        _test_fail "Horizon 응답 실패: HTTP $code"
    fi

    # Django settings 확인
    if grep -q "controller:11211" /etc/openstack-dashboard/local_settings.py 2>/dev/null; then
        _test_pass "Horizon Memcached 설정 확인"
    else
        _test_fail "Horizon Memcached 설정 없음"
    fi
}

# ── Cinder ────────────────────────────────────────────────────────────
test_cinder_controller() {
    echo -e "\n${BOLD}[Cinder - Controller]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음 — Keystone 미설치"; return; }
    source /root/admin-openrc

    _check_service cinder-scheduler
    _check_http "http://controller:8776/"

    # 볼륨 서비스 목록
    local vol_svcs
    vol_svcs=$(openstack volume service list -f value -c Binary -c State 2>/dev/null)
    local up_count down_count
    up_count=$(echo "$vol_svcs"  | grep -c "up"   || true)
    down_count=$(echo "$vol_svcs" | grep -c "down" || true)

    if [ "$up_count" -gt 0 ]; then
        _test_pass "Cinder 서비스 up: ${up_count}개, down: ${down_count}개"
    else
        _test_fail "Cinder 서비스 up 없음 — Block 노드 배포 여부 확인"
    fi
}

test_cinder_block() {
    echo -e "\n${BOLD}[Cinder - Block]${NC}"
    _check_service cinder-volume
    _check_service tgt

    # LVM VG 확인
    if vgs cinder-volumes &>/dev/null; then
        local vg_info
        vg_info=$(vgs --noheadings -o vg_name,vg_size,vg_free cinder-volumes 2>/dev/null | tr -s ' ')
        _test_pass "LVM VG cinder-volumes 존재:$vg_info"
    else
        _test_fail "LVM VG cinder-volumes 없음"
    fi

    # tgt 설정
    if [ -f /etc/tgt/conf.d/cinder.conf ]; then
        _test_pass "tgt cinder.conf 존재"
    else
        _test_fail "tgt cinder.conf 없음"
    fi
}

# ── 전체 연동 테스트 (Controller 전용) ───────────────────────────────
test_integration() {
    echo -e "\n${BOLD}[통합 테스트 - Controller]${NC}"
    [ -f /root/admin-openrc ] || { _test_skip "admin-openrc 없음"; return; }
    source /root/admin-openrc

    # Nova ↔ Placement 연동
    local rp_count
    rp_count=$(openstack --os-placement-api-version 1.2 resource provider list \
        -f value -c uuid 2>/dev/null | wc -l)
    if [ "$rp_count" -gt 0 ]; then
        _test_pass "Nova ↔ Placement 연동: Resource Provider ${rp_count}개"
    else
        _test_fail "Nova ↔ Placement 연동 실패 (Resource Provider 없음)"
    fi

    # Neutron ↔ Nova 연동
    if openstack network agent list -f value -c "Agent Type" 2>/dev/null | grep -q "Open vSwitch"; then
        _test_pass "Nova ↔ Neutron 연동: OVS 에이전트 확인"
    else
        _test_fail "Nova ↔ Neutron 연동 실패"
    fi

    # 카탈로그 전체 확인
    local catalog_svcs
    catalog_svcs=$(openstack catalog list -f value -c Name 2>/dev/null | sort | tr '\n' ', ' | sed 's/,$//')
    _test_info "서비스 카탈로그: $catalog_svcs"

    # 필수 서비스 존재 여부
    for svc in keystone glance nova neutron placement; do
        if openstack catalog list -f value -c Name 2>/dev/null | grep -q "^${svc}$"; then
            _test_pass "카탈로그: $svc 등록됨"
        else
            _test_fail "카탈로그: $svc 없음"
        fi
    done
    if openstack catalog list -f value -c Name 2>/dev/null | grep -q "cinderv3\|volumev3"; then
        _test_pass "카탈로그: cinder(volumev3) 등록됨"
    else
        _test_fail "카탈로그: cinder 없음 (Cinder 미설치 또는 오류)"
    fi
}

# ── 메인 ─────────────────────────────────────────────────────────────
log_header "AutoStack-Epoxy 설치 검증 테스트"
echo -e "  노드: ${BOLD}${MY_HOSTNAME}${NC} (${MY_IP}) | 역할: ${BOLD}${MY_ROLE}${NC}\n"

case "$MY_ROLE" in
    controller)
        test_infrastructure
        test_keystone
        test_glance
        test_placement
        test_nova_controller
        test_neutron_controller
        test_horizon
        test_cinder_controller
        test_integration
        ;;
    compute)
        test_nova_compute
        test_neutron_compute
        ;;
    block)
        test_cinder_block
        ;;
esac

# ── 결과 요약 ─────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))
echo
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${BOLD}  테스트 결과 요약${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "  전체: ${TOTAL}  ${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}  ${YELLOW}SKIP: ${SKIP}${NC}"
echo

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ 모든 테스트 통과${NC}"
else
    echo -e "  ${RED}${BOLD}✗ ${FAIL}개 실패 — 위 항목을 확인하세요${NC}"
fi
echo -e "${BOLD}══════════════════════════════════════${NC}"

[ "$FAIL" -eq 0 ]
