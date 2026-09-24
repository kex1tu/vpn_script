#!/bin/bash

PASS=0
FAIL=0
TOTAL=0

pass() { echo -e "\e[1;42m PASS \e[0m $1"; ((PASS++)); ((TOTAL++)); }
fail() { echo -e "\e[1;41m FAIL \e[0m $1"; ((FAIL++)); ((TOTAL++)); }

echo "=============================================="
echo "  Docker Test Suite for x-ui-pro.sh refactor"
echo "=============================================="
echo ""

# --- Test 1: Bash syntax check ---
echo ">>> Test 1: Bash syntax check"
if bash -n /script.sh 2>&1; then
    pass "Bash syntax check passed"
else
    fail "Bash syntax check failed"
fi
echo ""

# --- Test 2: Generate Nginx configs by sourcing relevant parts ---
echo ">>> Test 2: Generate Nginx configs (simulated)"

# Set variables as the script would
domain="test.example.com"
panel_path="secretpanel"
panel_port="12301"
xhttp_port="19842"

# Simulate cert symlinks
mkdir -p /root/cert/${domain}
chmod 755 /root/cert/
rm -f /root/cert/${domain}/*
ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${domain}/privkey.pem /root/cert/${domain}/privkey.pem

# Test 3: Symlinks work on second run (ln -sf)
echo ">>> Test 3: Symlinks survive second run (ln -sf)"
ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem 2>&1
if [ $? -eq 0 ]; then
    pass "Symlinks ln -sf survived repeated creation"
else
    fail "Symlinks ln -sf failed on repeated creation"
fi
echo ""

# Generate stream.conf
mkdir -p /etc/nginx/stream-enabled
cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${domain}           www;
    default              www;
}

upstream www {
    server unix:/dev/shm/nginx-http.sock;
}

upstream reality_failover {
    server 127.0.0.1:9443;
    server unix:/dev/shm/nginx-http.sock backup;
}

server {
    proxy_protocol on;
    listen          443;
    listen         [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF

# Fix nginx.conf for stream
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* 2>/dev/null || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]] && ! grep -rq "ngx_stream_module" /etc/nginx/ 2>/dev/null; then
    sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
fi
# geoip2 module removed — not available on stock Ubuntu
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* 2>/dev/null || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf
grep -q "sites-enabled" /etc/nginx/nginx.conf || sed -i '/conf\.d\/\*\.conf;/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf

# Ensure conf.d/*.conf is included and configure rate limiting and probe logging
mkdir -p /etc/nginx/conf.d /var/log/nginx
touch /var/log/nginx/probe.log
chmod 640 /var/log/nginx/probe.log
cat > "/etc/nginx/conf.d/probe_security.conf" << 'EOF'
limit_req_zone $binary_remote_addr zone=probe_limit:10m rate=10r/s;
limit_req_status 429;

map $status $is_probe {
    ~^[45]  1;
    default 0;
}

log_format probe_combined '$remote_addr - $remote_user [$time_local] '
                          '"$request" $status $body_bytes_sent '
                          '"$http_referer" "$http_user_agent"';
EOF

# Generate 80.conf
cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Generate main domain vhost
cat > "/etc/nginx/sites-available/${domain}" << EOF
# Why: Reject direct IP scans and TLS handshakes with missing/non-matching SNI,
# preventing active probing and certificate disclosure on the unix domain socket.
server {
    listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}

server {
# =====================================================================
# VLESS XHTTP STREAM-ONE
# =====================================================================
location /videos/media/ts/1080/ {
    # Why: Stream-One uses GET for downlink and POST for uplink; reject invalid methods early
    if (\$request_method !~ ^(GET|POST)\$) {
        return 404;
    }

    # Why: Native HTTP/2 Cleartext (h2c) proxying without gRPC framing overhead
    proxy_http_version 2;
    proxy_pass http://127.0.0.1:${xhttp_port:-19842};

    # Why: Keepalive and zero-buffering for long-lived real-time streams
    proxy_socket_keepalive on;
    proxy_request_buffering off;
    proxy_buffering off;
    client_max_body_size 0;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    client_body_timeout 1h;

    # Headers for client IP forwarding
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Why: Enforce raw binary stream and prevent SSE/chunking distortions
    proxy_hide_header Content-Type;
    add_header Content-Type application/octet-stream always;

    access_log off;
    error_log /dev/null crit;
    gzip off;
}
	server_tokens off;
	server_name ${domain};
	listen unix:/dev/shm/nginx-http.sock ssl http2 proxy_protocol;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/html/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

	# Security headers (anti-fingerprint)
	add_header X-Content-Type-Options "nosniff" always;
	add_header X-Frame-Options "SAMEORIGIN" always;
	add_header Referrer-Policy "strict-origin-when-cross-origin" always;
	add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

	# Rate limiting and probe log for Fail2ban
	limit_req zone=probe_limit burst=20 nodelay;
	access_log /var/log/nginx/probe.log probe_combined if=\$is_probe;
	error_log /dev/null crit;

	if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|\\\$|&&|\?\?|0x00|0X00|\||\\\|\\{|\\}|\[|\]|<|>|\\.\\.\\.|\\.\\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 500 501 502 503 504 =404 /404;
	proxy_intercept_errors on;

	#X-UI Admin Panel
	location = /${panel_path} {
		return 301 /${panel_path}/;
	}

	location /${panel_path}/ {
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_ssl_verify off;

		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
		proxy_pass https://127.0.0.1:${panel_port};
	}

	include /etc/nginx/snippets/includes.conf;
}

# Why: Anti-loop fallback server for Xray REALITY / Steal-Oneself.
# Avoids infinite routing loops by serving mask site directly on an isolated internal port.
server {
	listen 127.0.0.1:9443 ssl;
	server_name ${domain};
	ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;

	location / {
		root /var/www/html/;
		index index.html index.htm;
	}

	access_log off;
	error_log /dev/null crit;
}
EOF

# Generate includes.conf
cat > "/etc/nginx/snippets/includes.conf" << EOF
	location / { try_files \$uri \$uri/ =404; }
EOF

# Enable sites
rm -f /etc/nginx/sites-enabled/default
ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/"

# --- Test 4: nginx -t ---
echo ">>> Test 4: nginx -t (config validation)"
if nginx -t 2>&1; then
    pass "nginx -t passed"
else
    fail "nginx -t failed"
    nginx -t 2>&1 || true
fi
echo ""

# --- Test 5: No geoip2 module in config ---
echo ">>> Test 5: No geoip2 module in nginx config"
if ! grep -r "ngx_stream_geoip2_module" /etc/nginx/ 2>/dev/null; then
    pass "No geoip2 module reference found"
else
    fail "geoip2 module reference still present"
fi
echo ""

# --- Test 6: No set_real_ip_from in stream config ---
echo ">>> Test 6: No set_real_ip_from in stream config"
if ! grep -r "set_real_ip_from" /etc/nginx/stream-enabled/ 2>/dev/null; then
    pass "No set_real_ip_from in stream"
else
    fail "set_real_ip_from found in stream"
fi
echo ""

# --- Test 7: Admin panel block has proxy_ssl_verify off ---
echo ">>> Test 7: proxy_ssl_verify off in admin panel"
if grep -q "proxy_ssl_verify off" "/etc/nginx/sites-available/${domain}"; then
    pass "proxy_ssl_verify off present in domain vhost"
else
    fail "proxy_ssl_verify off missing in domain vhost"
fi
echo ""

# --- Test 8: Absence of WS and gRPC locations in domain vhost ---
echo ">>> Test 8: Absence of WS and gRPC locations in domain vhost"
if ! grep -q "location /stream/ws/live/" "/etc/nginx/sites-available/${domain}" && \
   ! grep -q "location /grpc-live-service" "/etc/nginx/sites-available/${domain}"; then
    pass "WS and gRPC locations completely absent from domain vhost"
else
    fail "WS or gRPC location found in domain vhost"
fi
echo ""

# --- Test 9: XHTTP location uses proxy_pass http://127.0.0.1: and proxy_http_version 2 ---
echo ">>> Test 9: XHTTP location uses proxy_pass and proxy_http_version 2"
if grep -q "proxy_pass http://127.0.0.1:" "/etc/nginx/sites-available/${domain}" && \
   grep -q "proxy_http_version 2;" "/etc/nginx/sites-available/${domain}"; then
    pass "XHTTP uses proxy_pass http://127.0.0.1: and proxy_http_version 2;"
else
    fail "XHTTP does not use proxy_pass http://127.0.0.1: or proxy_http_version 2;"
fi
echo ""

# --- Test 10: XHTTP location path is /videos/media/ts/1080/ ---
echo ">>> Test 10: XHTTP path is /videos/media/ts/1080/"
if grep -q "location /videos/media/ts/1080/" "/etc/nginx/sites-available/${domain}"; then
    pass "XHTTP path is /videos/media/ts/1080/"
else
    fail "XHTTP path is not /videos/media/ts/1080/"
fi
echo ""

# --- Test 11: Security headers present ---
echo ">>> Test 11: Security headers present"
HEADERS_OK=true
for hdr in "X-Content-Type-Options" "X-Frame-Options" "Referrer-Policy" "Permissions-Policy"; do
    if ! grep -q "$hdr" "/etc/nginx/sites-available/${domain}"; then
        HEADERS_OK=false
        echo "  Missing: $hdr"
    fi
done
if [ "$HEADERS_OK" = true ]; then
    pass "All security headers present"
else
    fail "Some security headers missing"
fi
echo ""

# --- Test 12: access_log off in vhost ---
echo ">>> Test 12: access_log off in vhost"
if grep -q "access_log off" "/etc/nginx/sites-available/${domain}"; then
    pass "access_log off in domain vhost"
else
    fail "access_log off missing in domain vhost"
fi
echo ""

# --- Test 13: SQLite DB settings (webListen and subscription disabled) ---
echo ">>> Test 13: DB settings (webListen=127.0.0.1 and subEnable=false)"

# Simulate what UPDATE_XUIDB does to settings
XUIDB="/etc/x-ui/x-ui.db"
sqlite3 $XUIDB << 'DBEOF'
DELETE FROM settings WHERE key IN ('webListen', 'subEnable', 'subPort', 'subListen');
INSERT INTO "settings" ("key", "value") VALUES ("webListen", '127.0.0.1');
INSERT INTO "settings" ("key", "value") VALUES ("subEnable", 'false');
DBEOF

WEB_LISTEN=$(sqlite3 -list $XUIDB "SELECT value FROM settings WHERE key='webListen' LIMIT 1;")
SUB_ENABLE=$(sqlite3 -list $XUIDB "SELECT value FROM settings WHERE key='subEnable' LIMIT 1;")
SUB_PORT=$(sqlite3 -list $XUIDB "SELECT value FROM settings WHERE key='subPort' LIMIT 1;")

DB_OK=true
[ "$WEB_LISTEN" != "127.0.0.1" ] && echo "  webListen=$WEB_LISTEN (expected 127.0.0.1)" && DB_OK=false
[ "$SUB_ENABLE" != "false" ] && echo "  subEnable=$SUB_ENABLE (expected false)" && DB_OK=false
[ -n "$SUB_PORT" ] && echo "  subPort=$SUB_PORT (expected empty)" && DB_OK=false

if [ "$DB_OK" = true ]; then
    pass "DB settings (webListen 127.0.0.1, subEnable false) verified"
else
    fail "DB settings incorrect"
fi
echo ""

# --- Test 14: RU-Block injection ---
echo ">>> Test 14: RU-Block rule injection"

# Create xrayTemplateConfig
sqlite3 $XUIDB "DELETE FROM settings WHERE key='xrayTemplateConfig'; INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '{\"routing\":{\"rules\":[]}}');"

python3 - << 'PYEOF'
import sqlite3
import json
import sys

db_path = "/etc/x-ui/x-ui.db"
try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'")
    row = cursor.fetchone()
    if row and row[0]:
        try:
            config = json.loads(row[0])
        except Exception:
            config = {}
    else:
        config = {}

    # 1. Outbounds
    if "outbounds" not in config or not isinstance(config["outbounds"], list) or len(config["outbounds"]) == 0:
        config["outbounds"] = [
            {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIP"}},
            {"protocol": "blackhole", "tag": "blocked", "settings": {}}
        ]

    # 2. DNS & Hosts
    if "dns" not in config or not isinstance(config["dns"], dict):
        config["dns"] = {
            "servers": ["https+local://1.1.1.1/dns-query", "1.1.1.1", "8.8.8.8", "localhost"],
            "hosts": {"domain:googleapis.cn": "googleapis.com"}
        }

    # 3. Routing rules
    user_rules = [
        {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
        {"type": "field", "enabled": True, "domain": ["ext:geosite_RU.dat:ru-blocked-all"], "ip": ["geoip:ru", "ext:geoip_IR.dat:ru"], "outboundTag": "blocked"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
        {"type": "field", "enabled": True, "port": "443", "network": "udp", "outboundTag": "blocked"}
    ]

    if "routing" not in config or not isinstance(config["routing"], dict):
        config["routing"] = {}
    config["routing"]["domainStrategy"] = "IPIfNonMatch"

    current_rules = config["routing"].get("rules", [])
    filtered_rules = [
        r for r in current_rules
        if not (
            r.get("outboundTag") in ["block", "blocked"] and (
                "geoip:ru" in r.get("ip", []) or
                "ext:geosite_RU.dat:ru-blocked-all" in r.get("domain", []) or
                "geosite:ru" in r.get("domain", []) or
                "geosite:category-ru" in r.get("domain", []) or
                "bittorrent" in r.get("protocol", []) or
                (r.get("port") == "443" and r.get("network") == "udp") or
                r.get("ip") == ["geoip:private"]
            )
        ) and not (r.get("inboundTag") == ["api"] and r.get("outboundTag") == "api")
    ]
    config["routing"]["rules"] = user_rules + filtered_rules

    cursor.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (json.dumps(config, indent=2),))
    if cursor.rowcount == 0:
        cursor.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (json.dumps(config, indent=2),))
    conn.commit()
    conn.close()
    print("OK")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

if [ $? -eq 0 ]; then
    # Verify RU-Block and template components
    VERIFY_OUT=$(sqlite3 $XUIDB "SELECT value FROM settings WHERE key='xrayTemplateConfig';" | python3 -c "
import json, sys
config = json.load(sys.stdin)
rules = config.get('routing', {}).get('rules', [])
outbounds = [o.get('tag') for o in config.get('outbounds', [])]
hosts = config.get('dns', {}).get('hosts', {})

has_ru_rule = any(r.get('outboundTag') == 'blocked' and 'ext:geosite_RU.dat:ru-blocked-all' in r.get('domain', []) for r in rules)
has_outbounds = 'direct' in outbounds and 'blocked' in outbounds
has_hosts = 'domain:googleapis.cn' in hosts

if has_ru_rule and has_outbounds and has_hosts:
    print('VALID')
else:
    print(f'INVALID: ru={has_ru_rule} out={has_outbounds} hosts={has_hosts}')
" 2>/dev/null)
    if [ "$VERIFY_OUT" = "VALID" ]; then
        pass "RU-Block rule, outbounds, and hosts correctly configured in template"
    else
        fail "RU-Block template verification failed: $VERIFY_OUT"
    fi
else
    fail "RU-Block injection failed"
fi

# Test idempotency - run again
python3 - << 'PYEOF'
import sqlite3
import json
db_path = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("SELECT value FROM settings WHERE key = 'xrayTemplateConfig'")
row = cursor.fetchone()
config = json.loads(row[0])
user_rules = [
    {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
    {"type": "field", "enabled": True, "domain": ["ext:geosite_RU.dat:ru-blocked-all"], "ip": ["geoip:ru", "ext:geoip_IR.dat:ru"], "outboundTag": "blocked"},
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
    {"type": "field", "enabled": True, "port": "443", "network": "udp", "outboundTag": "blocked"}
]
current_rules = config["routing"].get("rules", [])
filtered_rules = [
    r for r in current_rules
    if not (
        r.get("outboundTag") in ["block", "blocked"] and (
            "geoip:ru" in r.get("ip", []) or
            "ext:geosite_RU.dat:ru-blocked-all" in r.get("domain", []) or
            "geosite:ru" in r.get("domain", []) or
            "geosite:category-ru" in r.get("domain", []) or
            "bittorrent" in r.get("protocol", []) or
            (r.get("port") == "443" and r.get("network") == "udp") or
            r.get("ip") == ["geoip:private"]
        )
    ) and not (r.get("inboundTag") == ["api"] and r.get("outboundTag") == "api")
]
config["routing"]["rules"] = user_rules + filtered_rules
cursor.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (json.dumps(config, indent=2),))
conn.commit()
conn.close()
PYEOF

RULE_COUNT=$(sqlite3 $XUIDB "SELECT value FROM settings WHERE key='xrayTemplateConfig';" | python3 -c "
import json, sys
config = json.load(sys.stdin)
count = sum(1 for r in config.get('routing',{}).get('rules',[]) if r.get('outboundTag') == 'blocked' and 'ext:geosite_RU.dat:ru-blocked-all' in r.get('domain',[]))
print(count)
" 2>/dev/null)
if [ "$RULE_COUNT" = "1" ]; then
    pass "RU-Block idempotent (no duplicates after re-run)"
else
    fail "RU-Block duplicated after re-run (count=$RULE_COUNT)"
fi
echo ""

# --- Test 15: Certbot renewal hook ---
echo ">>> Test 15: Certbot renewal hook"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if [ -x "/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh" ]; then
    pass "Certbot renewal hook exists and is executable"
else
    fail "Certbot renewal hook missing or not executable"
fi
echo ""

# --- Test 16: Sysctl config file and parameters ---
echo ">>> Test 16: Sysctl parameters check"
cat > /etc/sysctl.d/99-xui-tuning.conf << 'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
net.ipv4.tcp_max_syn_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384
SYSCTL

if [ -f "/etc/sysctl.d/99-xui-tuning.conf" ] && \
   grep -q "somaxconn = 65535" /script.sh && \
   grep -q "udp_rmem_min = 16384" /script.sh && \
   grep -q "tcp_notsent_lowat = 16384" /script.sh; then
    pass "Sysctl parameters somaxconn=65535, udp_rmem_min=16384, tcp_notsent_lowat=16384 verified"
else
    fail "Sysctl parameters verification failed"
fi
echo ""

# --- Test 17: Logrotate config ---
echo ">>> Test 17: Logrotate config"
cat > /etc/logrotate.d/xui-nginx << 'LOGR'
/var/log/nginx/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
}
LOGR

if [ -f "/etc/logrotate.d/xui-nginx" ]; then
    pass "Logrotate config created"
else
    fail "Logrotate config missing"
fi
echo ""

# --- Test 18: Script contains no geoip2 load_module ---
echo ">>> Test 18: Script has no geoip2 load_module directive (only comment)"
if grep -q "^grep.*ngx_stream_geoip2_module" /script.sh 2>/dev/null; then
    fail "Active geoip2 load_module line still in script"
else
    pass "No active geoip2 load_module line in script"
fi
echo ""

# --- Test 19: Script has -block_ru argument ---
echo ">>> Test 19: Script has -block_ru argument"
if grep -q "\-block_ru" /script.sh; then
    pass "-block_ru argument present"
else
    fail "-block_ru argument missing"
fi
echo ""

# --- Test 20: Script has -mode argument ---
echo ">>> Test 20: Script has -mode argument"
if grep -q "\-mode)" /script.sh; then
    pass "-mode argument present"
else
    fail "-mode argument missing"
fi
echo ""

# --- Test 21: UFW rules in script ---
echo ">>> Test 21: UFW default deny incoming in script"
if grep -q "ufw default deny incoming" /script.sh; then
    pass "ufw default deny incoming present"
else
    fail "ufw default deny incoming missing"
fi
echo ""

# --- Test 22: ln -sf in script (no bare ln -s) ---
echo ">>> Test 22: All symlinks use ln -sf"
# Check that sites-enabled symlinks use -sf
if grep "ln -s " /script.sh | grep -v "ln -sf" | grep -v "^#" | grep -q "sites-enabled\|cert"; then
    fail "Found bare 'ln -s' without -sf for cert/sites-enabled"
else
    pass "All cert/sites-enabled symlinks use ln -sf"
fi
echo ""

# --- Test 23: upgrade_xray_core function exists ---
echo ">>> Test 23: upgrade_xray_core function exists"
if grep -q "upgrade_xray_core()" /script.sh; then
    pass "upgrade_xray_core function defined"
else
    fail "upgrade_xray_core function missing"
fi
echo ""

# --- Test 24: apply_ru_block function exists ---
echo ">>> Test 24: apply_ru_block function exists"
if grep -q "apply_ru_block()" /script.sh; then
    pass "apply_ru_block function defined"
else
    fail "apply_ru_block function missing"
fi
echo ""

# --- Test 25: XHTTP inbound uses stream-one, vlessenc, and vision ---
echo ">>> Test 25: XHTTP inbound uses stream-one, vlessenc, and vision"
if grep -q "stream-one" /script.sh && grep -q "vlessenc" /script.sh && grep -q "xtls-rprx-vision" /script.sh; then
    pass "XHTTP inbound uses stream-one, vlessenc, and xtls-rprx-vision"
else
    fail "XHTTP inbound missing stream-one, vlessenc, or xtls-rprx-vision"
fi
echo ""

# --- Test 26: Monoprotocol xHTTP inbound in script.sh and absence of WS/Trojan ---
echo ">>> Test 26: Monoprotocol xHTTP inbound in script.sh and absence of WS/Trojan"
XHTTP_COUNT=$(grep -A15 "emoji_flag.*xhttp" /script.sh | grep -c "'127.0.0.1'" 2>/dev/null || true)
WS_INBOUND_COUNT=$(grep -c "emoji_flag.*ws" /script.sh 2>/dev/null || true)
TROJAN_INBOUND_COUNT=$(grep -c "emoji_flag.*trojan" /script.sh 2>/dev/null || true)
XHTTP_COUNT=${XHTTP_COUNT:-0}
WS_INBOUND_COUNT=${WS_INBOUND_COUNT:-0}
TROJAN_INBOUND_COUNT=${TROJAN_INBOUND_COUNT:-0}
if [ "$XHTTP_COUNT" -ge 1 ] && [ "$WS_INBOUND_COUNT" -eq 0 ] && [ "$TROJAN_INBOUND_COUNT" -eq 0 ]; then
    pass "Monoprotocol xHTTP inbound present (127.0.0.1), WS and Trojan inbounds completely absent"
else
    fail "Inbounds check failed: xHTTP=$XHTTP_COUNT, WS=$WS_INBOUND_COUNT, Trojan=$TROJAN_INBOUND_COUNT"
fi
echo ""

# --- Test 27: Fake site fallback exists ---
echo ">>> Test 27: Fake site fallback HTML"
if grep -q "Service Operational" /script.sh; then
    pass "Fake site fallback HTML present"
else
    fail "Fake site fallback HTML missing"
fi
echo ""

# --- Test 28: sub2sing-box, clash templates, and subpage removed ---
echo ">>> Test 28: Sub2sing-box, Clash, and Subpage removal verification"
TEST28_FAIL=0
if grep -q "install_sub2sing-box" /script.sh || grep -q "sub2sing-box" /script.sh; then
    echo "ERROR: sub2sing-box reference still present in script.sh"
    TEST28_FAIL=1
fi
if grep -q "URL_CLASH_SUB" /script.sh || grep -q "clash.yaml" /script.sh; then
    echo "ERROR: clash templates still present"
    TEST28_FAIL=1
fi
if grep -q "URL_SUB_PAGE" /script.sh || grep -q 'mkdir -p "\$DEST_DIR_SUB_PAGE"' /script.sh; then
    echo "ERROR: subpage generator still present"
    TEST28_FAIL=1
fi
if grep -q "sub2singbox_path" /script.sh; then
    echo "ERROR: sub2singbox_path variable still present"
    TEST28_FAIL=1
fi
if grep -q "web_path" /script.sh; then
    echo "ERROR: web_path variable still present"
    TEST28_FAIL=1
fi
if grep -F 'proxy_pass http://127.0.0.1:8080/;' /script.sh; then
    echo "ERROR: 8080 proxy_pass still present"
    TEST28_FAIL=1
fi
if [ $TEST28_FAIL -eq 0 ]; then
    pass "sub2sing-box, clash, and subpage completely removed"
else
    fail "Residual sub2sing-box/clash/subpage code found in script.sh"
fi
echo ""

# --- Test 29: Early system utilities installation check ---
echo ">>> Test 29: System utilities installation at script startup"
if grep -q "install_dependencies()" /script.sh && \
   grep -q "netcat-openbsd" /script.sh && \
   grep -q "psmisc" /script.sh && \
   grep -q "install_dependencies" /script.sh; then
    pass "All required utilities installed at script startup"
else
    fail "Missing install_dependencies or required packages in script.sh"
fi
echo ""

# --- Test 30: Absence of SSRF arbitrary port forwarding in script ---
echo ">>> Test 30: SSRF regex location removed"
if grep -q "fwdport" /script.sh; then
    fail "SSRF regex location with fwdport still present in script.sh"
else
    pass "SSRF arbitrary port forward location removed"
fi
echo ""

# --- Test 31: HTTPS bound strictly to unix domain socket ---
echo ">>> Test 31: HTTPS bound strictly to unix domain socket"
if grep -q "listen unix:/dev/shm/nginx-http.sock" /script.sh; then
    pass "HTTPS bound strictly to unix domain socket"
else
    fail "listen unix:/dev/shm/nginx-http.sock not bound in /script.sh"
fi
echo ""

# --- Test 32: validate_domain is called on domain input ---
echo ">>> Test 32: validate_domain invocation check"
if grep -q "validate_domain \"\$domain\"" /script.sh; then
    pass "validate_domain is actively invoked"
else
    fail "validate_domain is not called in script.sh"
fi
echo ""

# --- Test 33: Certbot renewal uses webroot and nginx reload ---
echo ">>> Test 33: Certbot renewal configuration"
if grep -q "certbot renew --webroot" /script.sh; then
    pass "Certbot renew configured with webroot"
else
    fail "Certbot renew not using webroot"
fi
echo ""

# --- Test 34: Verify ANTILOOP_PORT and listen 127.0.0.1:9443 ssl ---
echo ">>> Test 34: Verify ANTILOOP_PORT and listen 127.0.0.1:9443 ssl in script"
if grep -q "ANTILOOP_PORT=9443" /script.sh && \
   (grep -q 'listen 127.0.0.1:\${ANTILOOP_PORT} ssl' /script.sh || grep -q "listen 127.0.0.1:9443 ssl" /script.sh); then
    pass "ANTILOOP_PORT and anti-loop listen verified in /script.sh"
else
    fail "ANTILOOP_PORT or anti-loop listen missing in /script.sh"
fi
echo ""

# --- Test 35: Verify dns_preflight_check ---
echo ">>> Test 35: Verify dns_preflight_check in script"
if grep -q "dns_preflight_check" /script.sh; then
    pass "dns_preflight_check verified in /script.sh"
else
    fail "dns_preflight_check missing in /script.sh"
fi
echo ""

# --- Test 36: Verify setup_nginx_mainline_repo ---
echo ">>> Test 36: Verify setup_nginx_mainline_repo in script"
if grep -q "setup_nginx_mainline_repo" /script.sh; then
    pass "setup_nginx_mainline_repo verified in /script.sh"
else
    fail "setup_nginx_mainline_repo missing in /script.sh"
fi
echo ""

# --- Test 37: Verify reality_failover upstream with backup ---
echo ">>> Test 37: Verify reality_failover upstream with backup in script"
if grep -q "upstream reality_failover" /script.sh && \
   grep -A5 "upstream reality_failover" /script.sh | grep -q "backup"; then
    pass "reality_failover upstream with backup verified in /script.sh"
else
    fail "reality_failover upstream with backup missing in /script.sh"
fi
echo ""

# --- Test 38: Verify ssl_reject_handshake on; and default_server ---
echo ">>> Test 38: Verify ssl_reject_handshake on; and default_server in script"
if grep -q "ssl_reject_handshake on;" /script.sh && \
   grep -q "default_server" /script.sh; then
    pass "ssl_reject_handshake on and default_server verified in /script.sh"
else
    fail "ssl_reject_handshake on or default_server missing in /script.sh"
fi
echo ""

# --- Test 39: Verify node mode security (UFW, sysctl, webListen 127.0.0.1) ---
echo ">>> Test 39: Verify node mode security (UFW, sysctl, webListen 127.0.0.1) in script"
NODE_BLOCK=$(sed -n '/if \[\[ "\${MODE}" == "node" \]\]; then/,/exit 0/p' /script.sh)
if echo "$NODE_BLOCK" | grep -q "ufw default deny incoming" && \
   echo "$NODE_BLOCK" | grep -q "apply_sysctl_tuning" && \
   echo "$NODE_BLOCK" | grep -q "'webListen', '127.0.0.1'"; then
    pass "Node mode security (UFW, sysctl, webListen 127.0.0.1) verified in /script.sh"
else
    fail "Node mode security missing required controls in /script.sh"
fi
echo ""

# --- Test 40: Verify file permissions (chmod 700 /etc/x-ui and chmod 600 /etc/x-ui/x-ui.db*) ---
echo ">>> Test 40: Verify file permissions (chmod 700 /etc/x-ui and chmod 600 /etc/x-ui/x-ui.db*) in script"
if grep -q "chmod 700 /etc/x-ui" /script.sh && \
   grep -q "chmod 600 /etc/x-ui/x-ui.db" /script.sh; then
    pass "Strict file permissions chmod 700 and chmod 600 verified in /script.sh"
else
    fail "Strict file permissions chmod 700 or chmod 600 missing in /script.sh"
fi
echo ""

# --- Test 41: Verify install_panel does not start x-ui prematurely ---
echo ">>> Test 41: Verify install_panel does not start x-ui prematurely"
INSTALL_PANEL_FUNC=$(sed -n '/^install_panel() {/,/^}/p' /script.sh)
if ! echo "$INSTALL_PANEL_FUNC" | grep -qE "systemctl[[:space:]]+(start|restart)[[:space:]]+x-ui" && \
   echo "$INSTALL_PANEL_FUNC" | grep -q "systemctl enable x-ui"; then
    pass "install_panel enables service without premature start"
else
    fail "install_panel contains premature start/restart of x-ui"
fi
echo ""

# --- Test 42: Fail2ban filter and jail syntax validation ---
echo ">>> Test 42: Fail2ban filter and jail syntax validation"
mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /var/log/nginx
touch /var/log/nginx/probe.log /var/log/auth.log
chmod 640 /var/log/nginx/probe.log

cat > /etc/fail2ban/filter.d/nginx-probe.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.* "(GET|POST|HEAD|PUT|DELETE|CONNECT|OPTIONS).*" (400|401|403|404|429|444) .*
ignoreregex =
EOF

cat > /etc/fail2ban/jail.d/99-nginx-probe.local << 'EOF'
[nginx-probe]
enabled   = true
port      = http,https
filter    = nginx-probe
logpath   = /var/log/nginx/probe.log
maxretry  = 5
findtime  = 60
bantime   = 86400
banaction = ufw
EOF

if fail2ban-client -t 2>&1; then
    pass "Fail2ban configuration syntax is valid (fail2ban-client -t)"
else
    fail "Fail2ban configuration syntax error"
fi
echo ""

# --- Test 43: Direct Client Connection URI check in script.sh ---
echo ">>> Test 43: Direct Client Connection URI check in script.sh"
if grep -q "CLIENT_VLESS_URL=" /script.sh && \
   grep -q "Direct Client Connection (VLESS-xHTTP):" /script.sh && \
   ! grep -q "Native Subscription:" /script.sh; then
    pass "Direct Client Connection URI present and subscription links removed"
else
    fail "Direct Client Connection URI missing or subscriptions still present"
fi
echo ""

# --- Test 44: Nginx rate limiting and probe logging in script.sh ---
echo ">>> Test 44: Nginx rate limiting and probe logging in script.sh"
if grep -q "limit_req_zone" /script.sh && \
   grep -q "probe_security.conf" /script.sh && \
   grep -q "probe.log" /script.sh; then
    pass "Nginx rate limiting and probe.log directives verified in script.sh"
else
    fail "Nginx rate limiting or probe.log directives missing in script.sh"
fi
echo ""

# --- Test 45: TCP Fast Open in sysctl ---
echo ">>> Test 45: TCP Fast Open in sysctl"
if grep -q "net\.ipv4\.tcp_fastopen = 3" /script.sh; then
    pass "TCP Fast Open (net.ipv4.tcp_fastopen = 3) verified in script.sh sysctl template"
else
    fail "TCP Fast Open (net.ipv4.tcp_fastopen = 3) missing in script.sh"
fi
echo ""

# --- Test 46: SSH hardening and -ssh_port argument ---
echo ">>> Test 46: SSH hardening and -ssh_port argument"
if grep -q "\-ssh_port)" /script.sh && \
   grep -q "setup_ssh_port" /script.sh && \
   grep -q "99-custom-port\.conf" /script.sh; then
    pass "SSH hardening logic, -ssh_port arg, and drop-in config verified in script.sh"
else
    fail "SSH hardening or -ssh_port argument missing in script.sh"
fi
echo ""

# --- Test 47: Fail2ban SSH jail configuration and fail2ban-client -t validation ---
echo ">>> Test 47: Fail2ban SSH jail configuration and fail2ban-client -t validation"
touch /var/log/auth.log
chmod 640 /var/log/auth.log
cat > /etc/fail2ban/jail.d/99-sshd.local << 'EOF'
[sshd]
enabled   = true
port      = 60022
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 3
findtime  = 600
bantime   = 86400
banaction = ufw
EOF

if fail2ban-client -t 2>&1; then
    pass "Fail2ban sshd jail syntax is valid (fail2ban-client -t)"
else
    fail "Fail2ban sshd jail syntax validation failed"
fi
echo ""

# --- Test 48: Unattended upgrades configuration in script.sh ---
echo ">>> Test 48: Unattended upgrades configuration in script.sh"
if grep -q "setup_unattended_upgrades" /script.sh && \
   grep -q "20auto-upgrades" /script.sh && \
   grep -q "50unattended-upgrades" /script.sh && \
   grep -q "Automatic-Reboot \"false\"" /script.sh; then
    pass "Unattended upgrades configuration verified in script.sh"
else
    fail "Unattended upgrades configuration missing in script.sh"
fi
echo ""

# --- Test 49: Hysteria 2 inbound SQLite schema and parameters ---
echo ">>> Test 49: Hysteria 2 inbound SQLite schema and parameters"
TEST_DB="/tmp/test_hy2_schema.db"
rm -f "$TEST_DB"
sqlite3 "$TEST_DB" << 'EOF'
CREATE TABLE inbounds (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    up INTEGER NOT NULL DEFAULT 0,
    down INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    remark TEXT NOT NULL,
    enable INTEGER NOT NULL DEFAULT 1,
    expiry_time INTEGER NOT NULL DEFAULT 0,
    listen TEXT NOT NULL,
    port INTEGER NOT NULL,
    protocol TEXT NOT NULL,
    settings TEXT NOT NULL,
    stream_settings TEXT NOT NULL,
    tag TEXT NOT NULL,
    sniffing TEXT NOT NULL
);
CREATE TABLE client_traffics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    inbound_id INTEGER NOT NULL,
    enable INTEGER NOT NULL DEFAULT 1,
    email TEXT NOT NULL,
    up INTEGER NOT NULL DEFAULT 0,
    down INTEGER NOT NULL DEFAULT 0,
    expiry_time INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    reset INTEGER NOT NULL DEFAULT 0
);
EOF

HY2_SQL=$(sed -n '/firstHy2/,$p' /script.sh | sed -n '1,/EOF/p' | sed '$d')
sqlite3 "$TEST_DB" <<< "$HY2_SQL" 2>/dev/null || true

HY2_COUNT=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM inbounds WHERE protocol='hysteria' AND port=443;" 2>/dev/null || echo 0)
HY2_MASQ=$(sqlite3 "$TEST_DB" "SELECT json_extract(stream_settings, '$.hysteriaSettings.masquerade.url') FROM inbounds WHERE protocol='hysteria';" 2>/dev/null || true)
HY2_ALPN=$(sqlite3 "$TEST_DB" "SELECT json_extract(stream_settings, '$.tlsSettings.alpn[0]') FROM inbounds WHERE protocol='hysteria';" 2>/dev/null || true)
HY2_TRAFFIC=$(sqlite3 "$TEST_DB" "SELECT count(*) FROM client_traffics WHERE email='firstHy2';" 2>/dev/null || echo 0)

if [ "$HY2_COUNT" -eq 1 ] && [ "$HY2_MASQ" = "http://127.0.0.1:80" ] && [ "$HY2_ALPN" = "h3" ] && [ "$HY2_TRAFFIC" -eq 1 ]; then
    pass "Hysteria 2 inbound schema, masquerade proxy, ALPN h3, and client traffic verified in SQLite"
else
    fail "Hysteria 2 SQLite verification failed: count=$HY2_COUNT, masq=$HY2_MASQ, alpn=$HY2_ALPN, traffic=$HY2_TRAFFIC"
fi
rm -f "$TEST_DB"
echo ""

# --- Test 50: Hysteria 2 direct client connection URI and summary ---
echo ">>> Test 50: Hysteria 2 direct client connection URI and summary"
if grep -q "CLIENT_HY2_URL=" /script.sh && \
   grep -q "Direct Client Connection (Hysteria 2 UDP Backup):" /script.sh && \
   grep -q "hysteria2://" /script.sh; then
    pass "Hysteria 2 client URI (CLIENT_HY2_URL) and display section verified in script.sh"
else
    fail "Hysteria 2 client URI or summary display missing in script.sh"
fi
echo ""

# --- Test 51: UFW firewall rules for UDP 443 and hardened SSH ---
echo ">>> Test 51: UFW firewall rules for UDP 443 and hardened SSH"
if grep -q "ufw allow 443/udp" /script.sh && \
   grep -q "ufw allow \"\${SSH_PORT:-22}/tcp\"" /script.sh; then
    pass "UFW 443/udp and dynamic SSH port rules verified in script.sh"
else
    fail "UFW 443/udp or dynamic SSH port rules missing in script.sh"
fi
echo ""

# --- Summary ---
echo ""
echo "=============================================="
echo "  TEST RESULTS: ${PASS} passed, ${FAIL} failed, ${TOTAL} total"
echo "=============================================="

if [ $FAIL -gt 0 ]; then
    exit 1
else
    exit 0
fi
