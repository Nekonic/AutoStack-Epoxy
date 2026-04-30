#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/AutoStack-Epoxy/env.sh

setup_ovs_bridge() {
    log_step "OVS br-provider 브리지 설정"
    if ! ovs-vsctl br-exists br-provider; then
        ovs-vsctl add-br br-provider
        log_ok "br-provider 생성 완료"
    else
        log_ok "br-provider 이미 존재"
    fi

    if ! ovs-vsctl port-to-br "$PROVIDER_IF" &>/dev/null; then
        ip addr flush dev "$PROVIDER_IF" 2>/dev/null || true
        ip link set "$PROVIDER_IF" up
        ovs-vsctl add-port br-provider "$PROVIDER_IF"
        log_ok "${PROVIDER_IF} → br-provider 연결 완료"
    else
        log_ok "${PROVIDER_IF} 이미 br-provider에 연결됨"
    fi
}

# ── Controller ────────────────────────────────────────────────────────
if [ "$MY_ROLE" = "controller" ]; then
    [ -f /root/admin-openrc ] || { log_error "admin-openrc 없음. Keystone 먼저 설치하세요."; exit 1; }
    source /root/admin-openrc

    log_header "Neutron 설치 (Controller)"

    log_step "데이터베이스 생성"
    mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '${COMMON_PASS}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '${COMMON_PASS}';
FLUSH PRIVILEGES;
EOF
    log_ok "neutron DB 생성 완료"

    log_step "Keystone 사용자/서비스/엔드포인트 등록"
    openstack user show neutron &>/dev/null \
        || openstack user create --domain default --password "${COMMON_PASS}" neutron
    openstack role assignment list --project service --user neutron --role admin --names 2>/dev/null | grep -q neutron \
        || openstack role add --project service --user neutron admin

    openstack service show neutron &>/dev/null \
        || openstack service create --name neutron --description "OpenStack Networking" network

    for iface in public internal admin; do
        openstack endpoint list --service neutron --interface "$iface" --region RegionOne -f value -c ID \
            | grep -q . \
            || openstack endpoint create --region RegionOne network "$iface" http://controller:9696
    done
    log_ok "Keystone 등록 완료"

    log_step "패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q \
        neutron-server neutron-plugin-ml2 \
        neutron-openvswitch-agent neutron-l3-agent \
        neutron-dhcp-agent neutron-metadata-agent
    log_ok "Neutron 패키지 설치 완료"

    log_step "neutron.conf 설정"
    NEUTRON_CONF=/etc/neutron/neutron.conf

    crudini --set "$NEUTRON_CONF" DEFAULT core_plugin                        "ml2"
    crudini --set "$NEUTRON_CONF" DEFAULT service_plugins                    "router"
    crudini --set "$NEUTRON_CONF" DEFAULT transport_url                      "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$NEUTRON_CONF" DEFAULT auth_strategy                      "keystone"
    crudini --set "$NEUTRON_CONF" DEFAULT notify_nova_on_port_status_changes "true"
    crudini --set "$NEUTRON_CONF" DEFAULT notify_nova_on_port_data_changes   "true"

    crudini --set "$NEUTRON_CONF" database connection \
        "mysql+pymysql://neutron:${COMMON_PASS}@controller/neutron"

    crudini --set "$NEUTRON_CONF" keystone_authtoken www_authenticate_uri  "http://controller:5000"
    crudini --set "$NEUTRON_CONF" keystone_authtoken auth_url              "http://controller:5000"
    crudini --set "$NEUTRON_CONF" keystone_authtoken memcached_servers     "controller:11211"
    crudini --set "$NEUTRON_CONF" keystone_authtoken auth_type             "password"
    crudini --set "$NEUTRON_CONF" keystone_authtoken project_domain_name   "Default"
    crudini --set "$NEUTRON_CONF" keystone_authtoken user_domain_name      "Default"
    crudini --set "$NEUTRON_CONF" keystone_authtoken project_name          "service"
    crudini --set "$NEUTRON_CONF" keystone_authtoken username              "neutron"
    crudini --set "$NEUTRON_CONF" keystone_authtoken password              "${COMMON_PASS}"

    crudini --set "$NEUTRON_CONF" nova auth_url            "http://controller:5000"
    crudini --set "$NEUTRON_CONF" nova auth_type           "password"
    crudini --set "$NEUTRON_CONF" nova project_domain_name "Default"
    crudini --set "$NEUTRON_CONF" nova user_domain_name    "Default"
    crudini --set "$NEUTRON_CONF" nova region_name         "RegionOne"
    crudini --set "$NEUTRON_CONF" nova project_name        "service"
    crudini --set "$NEUTRON_CONF" nova username            "nova"
    crudini --set "$NEUTRON_CONF" nova password            "${COMMON_PASS}"

    crudini --set "$NEUTRON_CONF" oslo_concurrency lock_path "/var/lib/neutron/tmp"
    log_ok "neutron.conf 설정 완료"

    log_step "ml2_conf.ini 설정"
    ML2_CONF=/etc/neutron/plugins/ml2/ml2_conf.ini

    crudini --set "$ML2_CONF" ml2 type_drivers        "flat,vlan,vxlan"
    crudini --set "$ML2_CONF" ml2 tenant_network_types "vxlan"
    crudini --set "$ML2_CONF" ml2 mechanism_drivers   "openvswitch,l2population"
    crudini --set "$ML2_CONF" ml2 extension_drivers   "port_security"

    crudini --set "$ML2_CONF" ml2_type_flat  flat_networks "provider"
    crudini --set "$ML2_CONF" ml2_type_vxlan vni_ranges    "1:1000"
    log_ok "ml2_conf.ini 설정 완료"

    log_step "openvswitch_agent.ini 설정 (Controller)"
    OVS_CONF=/etc/neutron/plugins/ml2/openvswitch_agent.ini

    crudini --set "$OVS_CONF" ovs bridge_mappings "provider:br-provider"
    crudini --set "$OVS_CONF" ovs local_ip        "${MY_IP}"
    crudini --set "$OVS_CONF" agent tunnel_types  "vxlan"
    crudini --set "$OVS_CONF" agent l2_population "true"
    crudini --set "$OVS_CONF" securitygroup enable_security_group "true"
    crudini --set "$OVS_CONF" securitygroup firewall_driver       "openvswitch"
    log_ok "openvswitch_agent.ini 설정 완료"

    log_step "l3_agent.ini 설정"
    L3_CONF=/etc/neutron/l3_agent.ini
    crudini --set "$L3_CONF" DEFAULT interface_driver      "openvswitch"
    crudini --set "$L3_CONF" DEFAULT external_network_bridge ""
    crudini --set "$L3_CONF" DEFAULT agent_mode            "legacy"
    log_ok "l3_agent.ini 설정 완료"

    log_step "dhcp_agent.ini 설정"
    DHCP_CONF=/etc/neutron/dhcp_agent.ini
    crudini --set "$DHCP_CONF" DEFAULT interface_driver          "openvswitch"
    crudini --set "$DHCP_CONF" DEFAULT dhcp_driver               "neutron.agent.linux.dhcp.Dnsmasq"
    crudini --set "$DHCP_CONF" DEFAULT enable_isolated_metadata  "true"
    log_ok "dhcp_agent.ini 설정 완료"

    log_step "metadata_agent.ini 설정"
    META_CONF=/etc/neutron/metadata_agent.ini
    crudini --set "$META_CONF" DEFAULT nova_metadata_host          "controller"
    crudini --set "$META_CONF" DEFAULT metadata_proxy_shared_secret "${COMMON_PASS}"
    log_ok "metadata_agent.ini 설정 완료"

    log_step "nova.conf에 neutron 섹션 추가"
    NOVA_CONF=/etc/nova/nova.conf
    crudini --set "$NOVA_CONF" neutron auth_url                    "http://controller:5000"
    crudini --set "$NOVA_CONF" neutron auth_type                   "password"
    crudini --set "$NOVA_CONF" neutron project_domain_name         "Default"
    crudini --set "$NOVA_CONF" neutron user_domain_name            "Default"
    crudini --set "$NOVA_CONF" neutron region_name                 "RegionOne"
    crudini --set "$NOVA_CONF" neutron project_name                "service"
    crudini --set "$NOVA_CONF" neutron username                    "neutron"
    crudini --set "$NOVA_CONF" neutron password                    "${COMMON_PASS}"
    crudini --set "$NOVA_CONF" neutron service_metadata_proxy      "true"
    crudini --set "$NOVA_CONF" neutron metadata_proxy_shared_secret "${COMMON_PASS}"
    log_ok "nova.conf neutron 섹션 추가 완료"

    log_step "DB sync"
    su -s /bin/sh -c "neutron-db-manage \
        --config-file /etc/neutron/neutron.conf \
        --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
        upgrade head" neutron
    log_ok "neutron DB sync 완료"

    setup_ovs_bridge

    log_step "서비스 재시작"
    service nova-api restart
    service neutron-server restart
    service neutron-openvswitch-agent restart
    service neutron-dhcp-agent restart
    service neutron-metadata-agent restart
    service neutron-l3-agent restart
    log_ok "Neutron 서비스 재시작 완료"

    log_step "검증"
    sleep 3
    openstack network agent list \
        && log_ok "Neutron 에이전트 확인 완료" \
        || { log_error "Neutron 에이전트 확인 실패"; exit 1; }

    log_header "Neutron (Controller) 설치 완료"
    exit 0
fi

# ── Compute ───────────────────────────────────────────────────────────
if [ "$MY_ROLE" = "compute" ]; then
    log_header "Neutron 설치 (Compute)"

    log_step "패키지 설치"
    DEBIAN_FRONTEND=noninteractive apt install -y -q neutron-openvswitch-agent
    log_ok "neutron-openvswitch-agent 설치 완료"

    log_step "neutron.conf 설정 (Compute)"
    NEUTRON_CONF=/etc/neutron/neutron.conf
    crudini --set "$NEUTRON_CONF" DEFAULT core_plugin   "ml2"
    crudini --set "$NEUTRON_CONF" DEFAULT transport_url "rabbit://openstack:${COMMON_PASS}@controller:5672/"
    crudini --set "$NEUTRON_CONF" oslo_concurrency lock_path "/var/lib/neutron/tmp"
    log_ok "neutron.conf 설정 완료"

    log_step "openvswitch_agent.ini 설정 (Compute)"
    OVS_CONF=/etc/neutron/plugins/ml2/openvswitch_agent.ini
    crudini --set "$OVS_CONF" ovs bridge_mappings "provider:br-provider"
    crudini --set "$OVS_CONF" ovs local_ip        "${MY_IP}"
    crudini --set "$OVS_CONF" agent tunnel_types  "vxlan"
    crudini --set "$OVS_CONF" agent l2_population "true"
    crudini --set "$OVS_CONF" securitygroup enable_security_group "true"
    crudini --set "$OVS_CONF" securitygroup firewall_driver       "openvswitch"
    log_ok "openvswitch_agent.ini 설정 완료"

    log_step "nova.conf에 neutron 섹션 추가"
    NOVA_CONF=/etc/nova/nova.conf
    crudini --set "$NOVA_CONF" neutron auth_url            "http://controller:5000"
    crudini --set "$NOVA_CONF" neutron auth_type           "password"
    crudini --set "$NOVA_CONF" neutron project_domain_name "Default"
    crudini --set "$NOVA_CONF" neutron user_domain_name    "Default"
    crudini --set "$NOVA_CONF" neutron region_name         "RegionOne"
    crudini --set "$NOVA_CONF" neutron project_name        "service"
    crudini --set "$NOVA_CONF" neutron username            "neutron"
    crudini --set "$NOVA_CONF" neutron password            "${COMMON_PASS}"
    log_ok "nova.conf neutron 섹션 추가 완료"

    setup_ovs_bridge

    log_step "서비스 재시작"
    service nova-compute restart
    service neutron-openvswitch-agent restart
    log_ok "서비스 재시작 완료"

    log_header "Neutron (Compute) 설치 완료"
    exit 0
fi

log_warn "이 역할(${MY_ROLE})에서는 Neutron이 실행되지 않습니다."
