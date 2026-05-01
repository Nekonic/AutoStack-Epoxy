#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

[ "$MY_ROLE" = "controller" ] || { log_warn "Keystone은 Controller 노드에서만 실행합니다."; exit 0; }

log_header "Keystone 설치"

# ── DB 생성 ───────────────────────────────────────────────────────────
log_step "데이터베이스 생성"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
log_ok "keystone DB 생성 완료"

# ── 패키지 설치 ───────────────────────────────────────────────────────
log_step "패키지 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q keystone
log_ok "keystone 설치 완료"

# ── keystone.conf 설정 ────────────────────────────────────────────────
log_step "keystone.conf 설정"
crudini --set /etc/keystone/keystone.conf database connection \
    "mysql+pymysql://keystone:${COMMON_PASS}@controller/keystone"
crudini --set /etc/keystone/keystone.conf token provider fernet
log_ok "keystone.conf 설정 완료"

# ── DB sync ───────────────────────────────────────────────────────────
log_step "DB sync"
su -s /bin/sh -c "keystone-manage db_sync" keystone
log_ok "DB sync 완료"

# ── Fernet 키 설정 ────────────────────────────────────────────────────
log_step "Fernet 키 초기화"
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
log_ok "Fernet 초기화 완료"

# ── Bootstrap ─────────────────────────────────────────────────────────
log_step "Bootstrap"
keystone-manage bootstrap \
    --bootstrap-password "${COMMON_PASS}" \
    --bootstrap-admin-url    http://controller:5000/v3/ \
    --bootstrap-internal-url http://controller:5000/v3/ \
    --bootstrap-public-url   http://controller:5000/v3/ \
    --bootstrap-region-id    RegionOne
log_ok "Bootstrap 완료"

# ── Apache 설정 ───────────────────────────────────────────────────────
log_step "Apache 설정"
grep -q "^ServerName" /etc/apache2/apache2.conf \
    || echo "ServerName controller" >> /etc/apache2/apache2.conf
systemctl enable apache2
service apache2 restart
log_ok "Apache 재시작 완료"

# ── admin-openrc 생성 ─────────────────────────────────────────────────
log_step "admin-openrc 생성"
cat > /root/admin-openrc <<'RCEOF'
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
RCEOF
cat >> /root/admin-openrc <<EOF
export OS_PASSWORD=${COMMON_PASS}
EOF
cat >> /root/admin-openrc <<'RCEOF'
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2

# venv-like 프롬프트 표시
if [ -z "${OS_PREV_PS1:-}" ]; then
    export OS_PREV_PS1="${PS1:-}"
fi
export PS1="(openstack:${OS_USERNAME}@${OS_PROJECT_NAME}) ${OS_PREV_PS1}"

openstack-deactivate() {
    export PS1="${OS_PREV_PS1:-}"
    unset OS_PROJECT_DOMAIN_NAME OS_USER_DOMAIN_NAME OS_PROJECT_NAME \
          OS_USERNAME OS_PASSWORD OS_AUTH_URL \
          OS_IDENTITY_API_VERSION OS_IMAGE_API_VERSION OS_PREV_PS1
    unset -f openstack-deactivate
    echo "OpenStack 환경 비활성화됨"
}

echo "OpenStack 활성화: ${OS_USERNAME} @ ${OS_PROJECT_NAME} (비활성화: openstack-deactivate)"
RCEOF
chmod 600 /root/admin-openrc
log_ok "/root/admin-openrc 생성 완료"

# ── 프로젝트 / 사용자 생성 ────────────────────────────────────────────
log_step "서비스 프로젝트 및 Demo 생성"
source /root/admin-openrc

openstack project show service &>/dev/null \
    || openstack project create --domain default --description "Service Project" service

openstack project show demo &>/dev/null \
    || openstack project create --domain default --description "Demo Project" demo

openstack user show demo &>/dev/null \
    || openstack user create --domain default --password "${COMMON_PASS}" demo

openstack role show user &>/dev/null \
    || openstack role create user

openstack role assignment list --project demo --user demo --role user --names 2>/dev/null | grep -q demo \
    || openstack role add --project demo --user demo user

log_ok "프로젝트/사용자 생성 완료"

# ── 검증 ──────────────────────────────────────────────────────────────
log_step "검증"
openstack token issue | grep -q "expires" \
    && log_ok "Keystone 정상 동작 확인" \
    || { log_error "Keystone 검증 실패"; exit 1; }

log_header "Keystone 설치 완료"
