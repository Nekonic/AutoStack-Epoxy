#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

[ "$MY_ROLE" = "controller" ] || { log_warn "Glance은 Controller 노드에서만 실행합니다."; exit 0; }
[ -f ~/admin-openrc ] || { log_error "admin-openrc 없음. Keystone 먼저 설치하세요."; exit 1; }
source ~/admin-openrc

log_header "Glance 설치"

# ── DB 생성 ───────────────────────────────────────────────────────────
log_step "데이터베이스 생성"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
log_ok "glance DB 생성 완료"

# ── Keystone 등록 ─────────────────────────────────────────────────────
log_step "Keystone 사용자/서비스/엔드포인트 등록"
openstack user show glance &>/dev/null \
    || openstack user create --domain default --password "${COMMON_PASS}" glance
openstack role assignment list --project service --user glance --role admin --names 2>/dev/null | grep -q glance \
    || openstack role add --project service --user glance admin

openstack service show glance &>/dev/null \
    || openstack service create --name glance --description "OpenStack Image" image

for iface in public internal admin; do
    openstack endpoint list --service glance --interface "$iface" --region RegionOne -f value -c ID \
        | grep -q . \
        || openstack endpoint create --region RegionOne image "$iface" http://controller:9292
done
log_ok "Keystone 등록 완료"

# ── 패키지 설치 ───────────────────────────────────────────────────────
log_step "패키지 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q glance
log_ok "glance 설치 완료"

# ── glance-api.conf 설정 ──────────────────────────────────────────────
log_step "glance-api.conf 설정"
GLANCE_CONF=/etc/glance/glance-api.conf

crudini --set "$GLANCE_CONF" database connection \
    "mysql+pymysql://glance:${COMMON_PASS}@controller/glance"

crudini --set "$GLANCE_CONF" keystone_authtoken www_authenticate_uri "http://controller:5000"
crudini --set "$GLANCE_CONF" keystone_authtoken auth_url              "http://controller:5000"
crudini --set "$GLANCE_CONF" keystone_authtoken memcached_servers     "controller:11211"
crudini --set "$GLANCE_CONF" keystone_authtoken auth_type             "password"
crudini --set "$GLANCE_CONF" keystone_authtoken project_domain_name   "Default"
crudini --set "$GLANCE_CONF" keystone_authtoken user_domain_name      "Default"
crudini --set "$GLANCE_CONF" keystone_authtoken project_name          "service"
crudini --set "$GLANCE_CONF" keystone_authtoken username              "glance"
crudini --set "$GLANCE_CONF" keystone_authtoken password              "${COMMON_PASS}"

crudini --set "$GLANCE_CONF" paste_deploy flavor "keystone"

crudini --set "$GLANCE_CONF" DEFAULT enabled_backends     "fs:file"
crudini --set "$GLANCE_CONF" glance_store default_backend "fs"
crudini --set "$GLANCE_CONF" fs         filesystem_store_datadir "/var/lib/glance/images/"

# oslo_limit: endpoint_id는 실제 생성된 public endpoint ID로 설정
ENDPOINT_ID=$(openstack endpoint list --service glance --interface public --region RegionOne -f value -c ID)
crudini --set "$GLANCE_CONF" oslo_limit auth_url          "http://controller:5000"
crudini --set "$GLANCE_CONF" oslo_limit auth_type         "password"
crudini --set "$GLANCE_CONF" oslo_limit user_domain_id    "default"
crudini --set "$GLANCE_CONF" oslo_limit username          "glance"
crudini --set "$GLANCE_CONF" oslo_limit system_scope      "all"
crudini --set "$GLANCE_CONF" oslo_limit password          "${COMMON_PASS}"
crudini --set "$GLANCE_CONF" oslo_limit endpoint_id       "${ENDPOINT_ID}"
crudini --set "$GLANCE_CONF" oslo_limit region_name       "RegionOne"

log_ok "glance-api.conf 설정 완료 (endpoint_id: ${ENDPOINT_ID})"

# ── glance 시스템 롤 부여 ─────────────────────────────────────────────
openstack role add --user glance --user-domain Default --system all reader 2>/dev/null || true

# ── DB sync ───────────────────────────────────────────────────────────
log_step "DB sync"
su -s /bin/sh -c "glance-manage db_sync" glance
log_ok "DB sync 완료"

# ── 서비스 재시작 ─────────────────────────────────────────────────────
log_step "서비스 재시작"
service glance-api restart

log_info "glance-api 기동 대기 중 (최대 60초)..."
for i in $(seq 1 30); do
    if bash -c "echo >/dev/tcp/controller/9292" 2>/dev/null; then
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        log_error "glance-api가 60초 내에 기동되지 않았습니다."
        systemctl status glance-api --no-pager -l | tail -20
        journalctl -u glance-api --no-pager -n 30
        exit 1
    fi
done
sleep 1
log_ok "glance-api 기동 완료"

# ── Cirros 이미지 업로드 ──────────────────────────────────────────────
log_step "Cirros 테스트 이미지 업로드"
CIRROS_VER="0.6.2"
CIRROS_IMG="/tmp/cirros-${CIRROS_VER}-x86_64-disk.img"
if ! openstack image show cirros &>/dev/null; then
    if [ ! -f "$CIRROS_IMG" ]; then
        wget -q --show-progress -O "$CIRROS_IMG" \
            "http://download.cirros-cloud.net/${CIRROS_VER}/cirros-${CIRROS_VER}-x86_64-disk.img"
    fi
    openstack image create "cirros" \
        --file "$CIRROS_IMG" \
        --disk-format qcow2 \
        --container-format bare \
        --public
    log_ok "cirros ${CIRROS_VER} 이미지 업로드 완료"
else
    log_ok "cirros 이미지 이미 존재 — 스킵"
fi

# ── 검증 ──────────────────────────────────────────────────────────────
log_step "검증"
openstack image show cirros &>/dev/null \
    && log_ok "Glance 정상 동작 확인" \
    || { log_error "Glance 검증 실패"; exit 1; }

log_header "Glance 설치 완료"
