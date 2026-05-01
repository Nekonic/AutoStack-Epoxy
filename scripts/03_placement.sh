#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

[ "$MY_ROLE" = "controller" ] || { log_warn "Placement은 Controller 노드에서만 실행합니다."; exit 0; }
[ -f /root/admin-openrc ] || { log_error "admin-openrc 없음. Keystone 먼저 설치하세요."; exit 1; }
source /root/admin-openrc

log_header "Placement 설치"

# ── DB 생성 ───────────────────────────────────────────────────────────
log_step "데이터베이스 생성"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS placement;
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
log_ok "placement DB 생성 완료"

# ── Keystone 등록 ─────────────────────────────────────────────────────
log_step "Keystone 사용자/서비스/엔드포인트 등록"
openstack user show placement &>/dev/null \
    || openstack user create --domain default --password "${COMMON_PASS}" placement
openstack role assignment list --project service --user placement --role admin --names 2>/dev/null | grep -q placement \
    || openstack role add --project service --user placement admin

openstack service show placement &>/dev/null \
    || openstack service create --name placement --description "Placement API" placement

for iface in public internal admin; do
    openstack endpoint list --service placement --interface "$iface" --region RegionOne -f value -c ID \
        | grep -q . \
        || openstack endpoint create --region RegionOne placement "$iface" http://controller:8778
done
log_ok "Keystone 등록 완료"

# ── 패키지 설치 ───────────────────────────────────────────────────────
log_step "패키지 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q placement-api
log_ok "placement-api 설치 완료"

# ── placement.conf 설정 ───────────────────────────────────────────────
log_step "placement.conf 설정"
PLACEMENT_CONF=/etc/placement/placement.conf

crudini --set "$PLACEMENT_CONF" placement_database connection \
    "mysql+pymysql://placement:${COMMON_PASS}@controller/placement"

crudini --set "$PLACEMENT_CONF" api auth_strategy "keystone"

crudini --set "$PLACEMENT_CONF" keystone_authtoken www_authenticate_uri "http://controller:5000"
crudini --set "$PLACEMENT_CONF" keystone_authtoken auth_url            "http://controller:5000/v3"
crudini --set "$PLACEMENT_CONF" keystone_authtoken memcached_servers   "controller:11211"
crudini --set "$PLACEMENT_CONF" keystone_authtoken auth_type           "password"
crudini --set "$PLACEMENT_CONF" keystone_authtoken project_domain_name "Default"
crudini --set "$PLACEMENT_CONF" keystone_authtoken user_domain_name    "Default"
crudini --set "$PLACEMENT_CONF" keystone_authtoken project_name        "service"
crudini --set "$PLACEMENT_CONF" keystone_authtoken username            "placement"
crudini --set "$PLACEMENT_CONF" keystone_authtoken password            "${COMMON_PASS}"

log_ok "placement.conf 설정 완료"

# ── DB sync ───────────────────────────────────────────────────────────
log_step "DB sync"
su -s /bin/sh -c "placement-manage db sync" placement
log_ok "DB sync 완료"

# ── 서비스 재시작 ─────────────────────────────────────────────────────
log_step "서비스 재시작"
service apache2 restart
log_ok "Apache 재시작 완료"

# ── 검증 ──────────────────────────────────────────────────────────────
log_step "검증"
DEBIAN_FRONTEND=noninteractive apt install -y -q python3-osc-placement -q 2>/dev/null || true
placement-status upgrade check \
    && log_ok "Placement 정상 동작 확인" \
    || { log_error "Placement 검증 실패"; exit 1; }

log_header "Placement 설치 완료"
