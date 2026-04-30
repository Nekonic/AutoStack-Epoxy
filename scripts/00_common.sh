#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/openstack-deploy/env.sh

log_header "공통 환경 설정 (${MY_HOSTNAME} / ${MY_ROLE})"

# ── Hostname ──────────────────────────────────────────────────────────
log_step "Hostname 설정"
hostnamectl set-hostname "$MY_HOSTNAME"
log_ok "hostname: $MY_HOSTNAME"

# ── /etc/hosts ───────────────────────────────────────────────────────
log_step "/etc/hosts 설정"
sed -i '/^127\.0\.1\.1/s/^/#/' /etc/hosts
sed -i '/# openstack-deploy-begin/,/# openstack-deploy-end/d' /etc/hosts
cat >> /etc/hosts <<EOF
# openstack-deploy-begin
${CONTROLLER_IP}    controller
${MY_IP}            ${MY_HOSTNAME}
# openstack-deploy-end
EOF
log_ok "/etc/hosts 업데이트 완료"

# ── 기본 패키지 ───────────────────────────────────────────────────────
log_step "기본 패키지 설치"
apt update -q
DEBIAN_FRONTEND=noninteractive apt install -y -q net-tools crudini curl wget
log_ok "기본 패키지 설치 완료"

# ── Netplan (Provider NIC) ────────────────────────────────────────────
log_step "Netplan 설정"
cat > /etc/netplan/99-openstack.yaml <<EOF
network:
  version: 2
  ethernets:
    ${MGMT_IF}:
      addresses:
        - ${MY_IP}/$(echo "$MGMT_CIDR" | cut -d'/' -f2)
      nameservers:
        addresses:
          - ${MGMT_DNS}
        search: []
      routes:
        - to: default
          via: ${MGMT_GW}
    ${PROVIDER_IF}:
      dhcp4: false
EOF
chmod 600 /etc/netplan/99-openstack.yaml
netplan apply
log_ok "Netplan 적용 완료"

# ── Chrony ───────────────────────────────────────────────────────────
log_step "Chrony (NTP) 설치 및 설정"
DEBIAN_FRONTEND=noninteractive apt install -y -q chrony

if [ "$MY_ROLE" = "controller" ]; then
    # Controller: 외부 NTP 서버 + 내부망 허용
    cat > /etc/chrony/chrony.conf <<EOF
pool ntp.ubuntu.com        iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2
server time.bora.net iburst
allow $(echo "$MGMT_CIDR" | cut -d'/' -f1)/$(echo "$MGMT_CIDR" | cut -d'/' -f2)
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF
else
    # Compute/Block: Controller를 NTP 서버로 사용
    cat > /etc/chrony/chrony.conf <<EOF
server controller iburst
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF
fi

service chrony restart
sleep 2
log_ok "Chrony 설정 완료"

# ── Controller 전용: 인프라 서비스 ───────────────────────────────────
[ "$MY_ROLE" != "controller" ] && exit 0

log_step "OpenStack 클라이언트 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q python3-openstackclient
log_ok "python3-openstackclient 설치 완료"

# MariaDB
log_step "MariaDB 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q mariadb-server python3-pymysql

cat > /etc/mysql/mariadb.conf.d/99-openstack.cnf <<EOF
[mysqld]
bind-address = ${MY_IP}
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

service mysql restart
log_ok "MariaDB 설치 완료"

# RabbitMQ
log_step "RabbitMQ 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q rabbitmq-server

if ! rabbitmqctl list_users 2>/dev/null | grep -q "^openstack"; then
    rabbitmqctl add_user openstack "${COMMON_PASS}"
fi
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
log_ok "RabbitMQ 설정 완료"

# Memcached
log_step "Memcached 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q memcached python3-memcache

sed -i "s/^-l .*/-l ${MY_IP}/" /etc/memcached.conf
grep -q "^-l ${MY_IP}" /etc/memcached.conf || echo "-l ${MY_IP}" >> /etc/memcached.conf

service memcached restart
log_ok "Memcached 설정 완료"

# etcd
log_step "etcd 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q etcd-server 2>/dev/null \
    || DEBIAN_FRONTEND=noninteractive apt install -y -q etcd

cat > /etc/default/etcd <<EOF
ETCD_NAME="controller"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"
ETCD_INITIAL_CLUSTER="controller=http://${MY_IP}:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${MY_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${MY_IP}:2379"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://${MY_IP}:2379"
EOF

systemctl enable etcd
systemctl restart etcd
log_ok "etcd 설정 완료"

log_header "공통 환경 설정 완료"
