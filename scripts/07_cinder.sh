#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

# ── Controller ────────────────────────────────────────────────────────
if [ "$MY_ROLE" = "controller" ]; then
    [ -f ~/admin-openrc ] || { log_error "admin-openrc 없음. Keystone 먼저 설치하세요."; exit 1; }
    source ~/admin-openrc

    log_header "Cinder 설치 (Controller)"

    log_step "데이터베이스 생성"
    mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
    log_ok "cinder DB 생성 완료"

    log_step "Keystone 사용자/서비스/엔드포인트 등록"
    openstack user show cinder &>/dev/null \
        || openstack user create --domain default --password "${COMMON_PASS}" cinder
    openstack role assignment list --project service --user cinder --role admin --names 2>/dev/null | grep -q cinder \
        || openstack role add --project service --user cinder admin

    openstack service show cinderv3 &>/dev/null \
        || openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3

    for iface in public internal admin; do
        openstack endpoint list --service cinderv3 --interface "$iface" --region RegionOne -f value -c ID \
            | grep -q . \
            || openstack endpoint create --region RegionOne volumev3 "$iface" \
                "http://controller:8776/v3/%(project_id)s"
    done
    log_ok "Keystone 등록 완료"

    log_step "패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q cinder-api cinder-scheduler
    log_ok "Cinder 패키지 설치 완료"

    log_step "cinder.conf 설정 (Controller)"
    CINDER_CONF=/etc/cinder/cinder.conf

    crudini --set "$CINDER_CONF" DEFAULT my_ip         "${MY_IP}"
    crudini --set "$CINDER_CONF" DEFAULT transport_url "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$CINDER_CONF" DEFAULT auth_strategy "keystone"
    crudini --set "$CINDER_CONF" DEFAULT state_path    "/var/lib/cinder"

    crudini --set "$CINDER_CONF" database connection \
        "mysql+pymysql://cinder:${COMMON_PASS}@controller/cinder"

    crudini --set "$CINDER_CONF" keystone_authtoken www_authenticate_uri  "http://controller:5000"
    crudini --set "$CINDER_CONF" keystone_authtoken auth_url              "http://controller:5000"
    crudini --set "$CINDER_CONF" keystone_authtoken memcached_servers     "controller:11211"
    crudini --set "$CINDER_CONF" keystone_authtoken auth_type             "password"
    crudini --set "$CINDER_CONF" keystone_authtoken project_domain_name   "default"
    crudini --set "$CINDER_CONF" keystone_authtoken user_domain_name      "default"
    crudini --set "$CINDER_CONF" keystone_authtoken project_name          "service"
    crudini --set "$CINDER_CONF" keystone_authtoken username              "cinder"
    crudini --set "$CINDER_CONF" keystone_authtoken password              "${COMMON_PASS}"

    crudini --set "$CINDER_CONF" oslo_concurrency lock_path "/var/lib/cinder/tmp"

    log_ok "cinder.conf 설정 완료"

    log_step "nova.conf에 cinder 섹션 추가"
    crudini --set /etc/nova/nova.conf cinder os_region_name "RegionOne"
    log_ok "nova.conf cinder 섹션 추가 완료"

    log_step "DB sync"
    su -s /bin/sh -c "cinder-manage db sync" cinder
    log_ok "cinder DB sync 완료"

    log_step "서비스 재시작"
    service nova-api restart
    service cinder-scheduler restart
    service apache2 restart
    log_ok "서비스 재시작 완료"

    log_step "검증"
    sleep 3
    openstack volume service list \
        && log_ok "Cinder (Controller) 정상 동작 확인" \
        || log_warn "Block 노드 미등록 — Block 노드 배포 후 재확인하세요"

    log_header "Cinder (Controller) 설치 완료"
    exit 0
fi

# ── Block ─────────────────────────────────────────────────────────────
if [ "$MY_ROLE" = "block" ]; then
    log_header "Cinder 설치 (Block)"

    # LVM 디스크 탐지
    log_step "LVM 디스크 탐지"
    LVM_DISK=""
    for disk in /dev/sd? /dev/vd? /dev/nvme?n?; do
        [ -b "$disk" ] || continue
        mounted=$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -c '/' || true)
        pv_used=$(pvs --noheadings -o pv_name 2>/dev/null | grep -c "^[[:space:]]*${disk}" || true)
        if [ "$mounted" -eq 0 ] && [ "$pv_used" -eq 0 ]; then
            LVM_DISK="$disk"
            break
        fi
    done

    if [ -z "$LVM_DISK" ]; then
        log_error "사용 가능한 LVM 디스크를 찾을 수 없습니다."
        log_error "미포맷 추가 디스크를 장착한 후 다시 실행하세요."
        exit 1
    fi
    log_ok "LVM 디스크: $LVM_DISK"

    log_step "LVM 패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q lvm2 thin-provisioning-tools
    log_ok "LVM 패키지 설치 완료"

    log_step "LVM PV/VG 구성"
    if ! pvs "$LVM_DISK" &>/dev/null; then
        pvcreate "$LVM_DISK"
    fi
    if ! vgs cinder-volumes &>/dev/null; then
        vgcreate cinder-volumes "$LVM_DISK"
    fi
    log_ok "cinder-volumes VG 준비 완료"

    log_step "lvm.conf 필터 설정"
    # cinder-volumes VG만 허용, 나머지 거부
    DISK_SHORT=$(basename "$LVM_DISK")
    sed -i '/^[[:space:]]*devices {/,/^[[:space:]]*}/ {
        /filter/d
    }' /etc/lvm/lvm.conf
    sed -i "/^[[:space:]]*devices {/a\\        filter = [ \"a/${DISK_SHORT}/\", \"r/.*/\"]" /etc/lvm/lvm.conf
    log_ok "lvm.conf 필터 설정 완료"

    log_step "Cinder Volume 패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q cinder-volume tgt
    log_ok "cinder-volume, tgt 설치 완료"

    log_step "cinder.conf 설정 (Block)"
    CINDER_CONF=/etc/cinder/cinder.conf

    crudini --set "$CINDER_CONF" DEFAULT transport_url       "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$CINDER_CONF" DEFAULT my_ip               "${MY_IP}"
    crudini --set "$CINDER_CONF" DEFAULT glance_api_servers  "http://controller:9292"
    crudini --set "$CINDER_CONF" DEFAULT auth_strategy       "keystone"
    crudini --set "$CINDER_CONF" DEFAULT state_path          "/var/lib/cinder"
    crudini --set "$CINDER_CONF" DEFAULT enabled_backends    "lvm"

    crudini --set "$CINDER_CONF" keystone_authtoken www_authenticate_uri  "http://controller:5000"
    crudini --set "$CINDER_CONF" keystone_authtoken auth_url              "http://controller:5000"
    crudini --set "$CINDER_CONF" keystone_authtoken memcached_servers     "controller:11211"
    crudini --set "$CINDER_CONF" keystone_authtoken auth_type             "password"
    crudini --set "$CINDER_CONF" keystone_authtoken project_domain_name   "default"
    crudini --set "$CINDER_CONF" keystone_authtoken user_domain_name      "default"
    crudini --set "$CINDER_CONF" keystone_authtoken project_name          "service"
    crudini --set "$CINDER_CONF" keystone_authtoken username              "cinder"
    crudini --set "$CINDER_CONF" keystone_authtoken password              "${COMMON_PASS}"

    crudini --set "$CINDER_CONF" database connection \
        "mysql+pymysql://cinder:${COMMON_PASS}@controller/cinder"

    # LVM 백엔드 설정 (docs 오류 수정: iscsi_helper → target_helper, tgtadm 사용)
    crudini --set "$CINDER_CONF" lvm volume_driver    "cinder.volume.drivers.lvm.LVMVolumeDriver"
    crudini --set "$CINDER_CONF" lvm volume_group     "cinder-volumes"
    crudini --set "$CINDER_CONF" lvm target_protocol  "iscsi"
    crudini --set "$CINDER_CONF" lvm target_helper    "tgtadm"

    crudini --set "$CINDER_CONF" oslo_concurrency lock_path "/var/lib/cinder/tmp"

    log_ok "cinder.conf 설정 완료"

    log_step "tgt 설정"
    mkdir -p /etc/tgt/conf.d
    echo "include /var/lib/cinder/volumes/*" > /etc/tgt/conf.d/cinder.conf
    log_ok "tgt 설정 완료"

    log_step "서비스 재시작"
    service tgt restart
    service cinder-volume restart
    log_ok "서비스 재시작 완료"

    log_header "Cinder (Block) 설치 완료"
    echo -e "  Controller에서 검증: ${BOLD}openstack volume service list${NC}"
    exit 0
fi

log_warn "이 역할(${MY_ROLE})에서는 Cinder가 실행되지 않습니다."
