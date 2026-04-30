#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/ui.sh"
source /etc/openstack-deploy/env.sh

[ "$MY_ROLE" = "controller" ] || { log_warn "Horizon은 Controller 노드에서만 실행합니다."; exit 0; }

log_header "Horizon 설치"

# ── 패키지 설치 ───────────────────────────────────────────────────────
log_step "패키지 설치"
DEBIAN_FRONTEND=noninteractive apt install -y -q openstack-dashboard
log_ok "openstack-dashboard 설치 완료"

# ── local_settings.py 설정 ────────────────────────────────────────────
log_step "local_settings.py 설정"
LOCAL_SETTINGS=/etc/openstack-dashboard/local_settings.py

# CACHES: memcached로 변경
python3 - <<'PYEOF'
import re

path = '/etc/openstack-dashboard/local_settings.py'
with open(path, 'r') as f:
    content = f.read()

# CACHES 블록 교체
caches_new = """CACHES = {
    'default': {
         'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
         'LOCATION': 'controller:11211',
    }
}"""
content = re.sub(
    r"CACHES\s*=\s*\{[^}]*(?:\{[^}]*\}[^}]*)?\}",
    caches_new,
    content,
    flags=re.DOTALL
)

# SESSION_ENGINE
if "SESSION_ENGINE" not in content:
    content += "\nSESSION_ENGINE = 'django.contrib.sessions.backends.cache'\n"
else:
    content = re.sub(
        r"^#?\s*SESSION_ENGINE\s*=.*$",
        "SESSION_ENGINE = 'django.contrib.sessions.backends.cache'",
        content,
        flags=re.MULTILINE
    )

with open(path, 'w') as f:
    f.write(content)
PYEOF

# OPENSTACK_HOST
sed -i "s|^OPENSTACK_HOST\s*=.*|OPENSTACK_HOST = \"controller\"|" "$LOCAL_SETTINGS"

# OPENSTACK_KEYSTONE_URL
sed -i "s|^OPENSTACK_KEYSTONE_URL\s*=.*|OPENSTACK_KEYSTONE_URL = \"http://%s:5000/v3\" % OPENSTACK_HOST|" \
    "$LOCAL_SETTINGS"

# OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT
grep -q "^OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT" "$LOCAL_SETTINGS" \
    && sed -i "s|^OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT.*|OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True|" \
        "$LOCAL_SETTINGS" \
    || echo "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True" >> "$LOCAL_SETTINGS"

# OPENSTACK_API_VERSIONS
grep -q "^OPENSTACK_API_VERSIONS" "$LOCAL_SETTINGS" \
    || cat >> "$LOCAL_SETTINGS" <<'EOF'
OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}
EOF

# OPENSTACK_KEYSTONE_DEFAULT_DOMAIN
grep -q "^OPENSTACK_KEYSTONE_DEFAULT_DOMAIN" "$LOCAL_SETTINGS" \
    && sed -i 's|^OPENSTACK_KEYSTONE_DEFAULT_DOMAIN.*|OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"|' \
        "$LOCAL_SETTINGS" \
    || echo 'OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"' >> "$LOCAL_SETTINGS"

# TIME_ZONE
sed -i 's|^TIME_ZONE\s*=.*|TIME_ZONE = "Asia/Seoul"|' "$LOCAL_SETTINGS"

# COMPRESS_OFFLINE
grep -q "^COMPRESS_OFFLINE" "$LOCAL_SETTINGS" \
    && sed -i "s|^COMPRESS_OFFLINE.*|COMPRESS_OFFLINE = False|" "$LOCAL_SETTINGS" \
    || echo "COMPRESS_OFFLINE = False" >> "$LOCAL_SETTINGS"

log_ok "local_settings.py 설정 완료"

# ── Apache 재로드 ─────────────────────────────────────────────────────
log_step "Apache 재로드"
systemctl reload apache2.service
log_ok "Apache 재로드 완료"

log_header "Horizon 설치 완료"
echo -e "  접속: ${BOLD}http://${MY_IP}/horizon${NC}"
echo -e "  도메인: Default | 사용자: admin | 패스워드: (설정한 값)"
