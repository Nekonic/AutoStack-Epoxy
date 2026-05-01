#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

# discover 모드: Controller에서 Compute 노드 등록
if [ "${1:-}" = "discover" ]; then
    [ "$MY_ROLE" = "controller" ] || { log_error "discover는 Controller에서 실행하세요."; exit 1; }
    source ~/admin-openrc
    log_header "Compute 노드 등록 (discover_hosts)"
    su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
    echo
    openstack compute service list
    log_ok "Compute 노드 등록 완료"
    exit 0
fi

# ── Controller: Nova API/Scheduler/Conductor ──────────────────────────
if [ "$MY_ROLE" = "controller" ]; then
    [ -f ~/admin-openrc ] || { log_error "admin-openrc 없음. Keystone 먼저 설치하세요."; exit 1; }
    source ~/admin-openrc

    log_header "Nova 설치 (Controller)"

    log_step "데이터베이스 생성"
    mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS nova_api;
CREATE DATABASE IF NOT EXISTS nova;
CREATE DATABASE IF NOT EXISTS nova_cell0;
GRANT ALL PRIVILEGES ON nova_api.*   TO 'nova'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON nova_api.*   TO 'nova'@'%'         IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON nova.*       TO 'nova'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON nova.*       TO 'nova'@'%'         IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%'         IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
    log_ok "nova DB 생성 완료"

    log_step "Keystone 사용자/서비스/엔드포인트 등록"
    openstack user show nova &>/dev/null \
        || openstack user create --domain default --password "${COMMON_PASS}" nova
    openstack role assignment list --project service --user nova --role admin --names 2>/dev/null | grep -q nova \
        || openstack role add --project service --user nova admin

    openstack service show nova &>/dev/null \
        || openstack service create --name nova --description "OpenStack Compute" compute

    for iface in public internal admin; do
        openstack endpoint list --service nova --interface "$iface" --region RegionOne -f value -c ID \
            | grep -q . \
            || openstack endpoint create --region RegionOne compute "$iface" http://controller:8774/v2.1
    done
    log_ok "Keystone 등록 완료"

    log_step "패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q \
        nova-api nova-conductor nova-novncproxy nova-scheduler
    log_ok "Nova 패키지 설치 완료"

    log_step "nova.conf 설정 (Controller)"
    NOVA_CONF=/etc/nova/nova.conf

    crudini --set "$NOVA_CONF" DEFAULT state_path     "/var/lib/nova"
    crudini --set "$NOVA_CONF" DEFAULT transport_url  "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$NOVA_CONF" DEFAULT my_ip          "${MY_IP}"

    crudini --set "$NOVA_CONF" api auth_strategy "keystone"

    crudini --set "$NOVA_CONF" api_database connection \
        "mysql+pymysql://nova:${COMMON_PASS}@controller/nova_api"
    crudini --set "$NOVA_CONF" database connection \
        "mysql+pymysql://nova:${COMMON_PASS}@controller/nova"

    crudini --set "$NOVA_CONF" glance api_servers "http://controller:9292"

    crudini --set "$NOVA_CONF" keystone_authtoken www_authenticate_uri  "http://controller:5000/"
    crudini --set "$NOVA_CONF" keystone_authtoken auth_url              "http://controller:5000/"
    crudini --set "$NOVA_CONF" keystone_authtoken memcached_servers     "controller:11211"
    crudini --set "$NOVA_CONF" keystone_authtoken auth_type             "password"
    crudini --set "$NOVA_CONF" keystone_authtoken project_domain_name   "Default"
    crudini --set "$NOVA_CONF" keystone_authtoken user_domain_name      "Default"
    crudini --set "$NOVA_CONF" keystone_authtoken project_name          "service"
    crudini --set "$NOVA_CONF" keystone_authtoken username              "nova"
    crudini --set "$NOVA_CONF" keystone_authtoken password              "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" service_user send_service_user_token "true"
    crudini --set "$NOVA_CONF" service_user auth_url                "http://controller:5000/"
    crudini --set "$NOVA_CONF" service_user auth_strategy           "keystone"
    crudini --set "$NOVA_CONF" service_user auth_type               "password"
    crudini --set "$NOVA_CONF" service_user project_domain_name     "Default"
    crudini --set "$NOVA_CONF" service_user project_name            "service"
    crudini --set "$NOVA_CONF" service_user user_domain_name        "Default"
    crudini --set "$NOVA_CONF" service_user username                "nova"
    crudini --set "$NOVA_CONF" service_user password                "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" oslo_concurrency lock_path "/var/lib/nova/tmp"

    crudini --set "$NOVA_CONF" placement region_name         "RegionOne"
    crudini --set "$NOVA_CONF" placement project_domain_name "Default"
    crudini --set "$NOVA_CONF" placement project_name        "service"
    crudini --set "$NOVA_CONF" placement auth_type           "password"
    crudini --set "$NOVA_CONF" placement user_domain_name    "Default"
    crudini --set "$NOVA_CONF" placement auth_url            "http://controller:5000/v3"
    crudini --set "$NOVA_CONF" placement username            "placement"
    crudini --set "$NOVA_CONF" placement password            "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" vnc enabled                     "true"
    crudini --set "$NOVA_CONF" vnc server_listen               '$my_ip'
    crudini --set "$NOVA_CONF" vnc server_proxyclient_address  '$my_ip'

    log_ok "nova.conf 설정 완료"

    log_step "DB sync 및 Cell 설정"
    su -s /bin/sh -c "nova-manage api_db sync" nova
    su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
    su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova 2>/dev/null || true
    su -s /bin/sh -c "nova-manage db sync" nova
    log_ok "DB sync 완료"

    log_step "서비스 재시작"
    for svc in nova-api nova-scheduler nova-conductor nova-novncproxy; do
        service "$svc" restart
    done
    log_ok "Nova 서비스 재시작 완료"

    log_step "검증"
    sleep 3
    nova-status upgrade check \
        && log_ok "Nova (Controller) 정상 동작 확인" \
        || log_warn "nova-status 경고 — Compute 노드 미등록 상태일 수 있음"

    log_header "Nova (Controller) 설치 완료"
    echo -e "  Compute 노드 배포 후: ${BOLD}sudo ./scripts/04_nova.sh discover${NC}"
    exit 0
fi

# ── Compute: Nova Compute ─────────────────────────────────────────────
if [ "$MY_ROLE" = "compute" ]; then
    log_header "Nova 설치 (Compute)"

    log_step "패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q nova-compute
    log_ok "nova-compute 설치 완료"

    log_step "nova.conf 설정 (Compute)"
    NOVA_CONF=/etc/nova/nova.conf

    crudini --set "$NOVA_CONF" DEFAULT state_path    "/var/lib/nova"
    crudini --set "$NOVA_CONF" DEFAULT transport_url "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$NOVA_CONF" DEFAULT my_ip         "${MY_IP}"

    crudini --set "$NOVA_CONF" api auth_strategy "keystone"

    crudini --set "$NOVA_CONF" glance api_servers "http://controller:9292"

    crudini --set "$NOVA_CONF" keystone_authtoken www_authenticate_uri  "http://controller:5000/"
    crudini --set "$NOVA_CONF" keystone_authtoken auth_url              "http://controller:5000/"
    crudini --set "$NOVA_CONF" keystone_authtoken memcached_servers     "controller:11211"
    crudini --set "$NOVA_CONF" keystone_authtoken auth_type             "password"
    crudini --set "$NOVA_CONF" keystone_authtoken project_domain_name   "Default"
    crudini --set "$NOVA_CONF" keystone_authtoken user_domain_name      "Default"
    crudini --set "$NOVA_CONF" keystone_authtoken project_name          "service"
    crudini --set "$NOVA_CONF" keystone_authtoken username              "nova"
    crudini --set "$NOVA_CONF" keystone_authtoken password              "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" service_user send_service_user_token "true"
    crudini --set "$NOVA_CONF" service_user auth_url                "http://controller:5000/"
    crudini --set "$NOVA_CONF" service_user auth_strategy           "keystone"
    crudini --set "$NOVA_CONF" service_user auth_type               "password"
    crudini --set "$NOVA_CONF" service_user project_domain_name     "Default"
    crudini --set "$NOVA_CONF" service_user project_name            "service"
    crudini --set "$NOVA_CONF" service_user user_domain_name        "Default"
    crudini --set "$NOVA_CONF" service_user username                "nova"
    crudini --set "$NOVA_CONF" service_user password                "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" oslo_concurrency lock_path "/var/lib/nova/tmp"

    crudini --set "$NOVA_CONF" placement region_name         "RegionOne"
    crudini --set "$NOVA_CONF" placement project_domain_name "Default"
    crudini --set "$NOVA_CONF" placement project_name        "service"
    crudini --set "$NOVA_CONF" placement auth_type           "password"
    crudini --set "$NOVA_CONF" placement user_domain_name    "Default"
    crudini --set "$NOVA_CONF" placement auth_url            "http://controller:5000/v3"
    crudini --set "$NOVA_CONF" placement username            "placement"
    crudini --set "$NOVA_CONF" placement password            "${COMMON_PASS}"

    crudini --set "$NOVA_CONF" vnc enabled                      "true"
    crudini --set "$NOVA_CONF" vnc server_listen                "0.0.0.0"
    crudini --set "$NOVA_CONF" vnc server_proxyclient_address   '$my_ip'
    crudini --set "$NOVA_CONF" vnc novncproxy_base_url          "http://controller:6080/vnc_auto.html"

    # KVM 지원 여부에 따라 virt_type 설정
    if [ -e /dev/kvm ] && grep -qE '(vmx|svm)' /proc/cpuinfo; then
        crudini --set "$NOVA_CONF" libvirt virt_type "kvm"
        log_ok "virt_type=kvm (하드웨어 가속 사용)"
    else
        crudini --set "$NOVA_CONF" libvirt virt_type "qemu"
        log_warn "virt_type=qemu (KVM 없음 — 성능 저하)"
    fi

    log_ok "nova.conf 설정 완료"

    log_step "서비스 재시작"
    service nova-compute restart
    log_ok "nova-compute 재시작 완료"

    log_header "Nova (Compute) 설치 완료"
    exit 0
fi

log_warn "이 역할(${MY_ROLE})에서는 Nova가 실행되지 않습니다."
