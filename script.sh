#!/bin/bash
#################### x-ui-pro v2.4.3 @ github.com/GFW4Fun ##############################################
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: command failed (exit ${rc})" >&2; exit "$rc"' ERR

if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges; re-executing via sudo..."
    exec sudo bash "$0" "$@"
fi
##############################INFO######################################################################
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}
echo;msg_inf '           ___    _   _   _  '	;
msg_inf		 ' \/ __ | |  | __ |_) |_) / \ '	;
msg_inf		 ' /\    |_| _|_   |   | \ \_/ '	; echo
##################################Variables#############################################################
XUIDB="/etc/x-ui/x-ui.db"
domain=""
MASTER_IP=""
UNINSTALL="x"
INSTALL="y"
PNLNUM=1
CFALLOW="n"
BLOCK_RU="y"
MODE="master"
AUTODOMAIN="n"
# Why: Dedicated internal port for Xray Steal-Oneself fallback, preventing infinite loopback to 443
ANTILOOP_PORT=9443
# Hardened SSH port (default 60022 if configured or specified via -ssh_port)
SSH_PORT=""
release=""
green='\e[1;32m'
yellow='\e[1;33m'
red='\e[1;31m'
blue='\e[1;34m'
plain='\e[0m'

if command -v apt-get >/dev/null 2>&1; then
    Pak="apt-get"
elif command -v apt >/dev/null 2>&1; then
    Pak="apt"
elif command -v yum >/dev/null 2>&1; then
    Pak="yum"
else
    echo "Unsupported package manager." >&2
    exit 1
fi

################################Get arguments###########################################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    -auto_domain) AUTODOMAIN="$2"; shift 2;;
    -install) INSTALL="$2"; shift 2;;
    -panel) PNLNUM="$2"; shift 2;;
    -subdomain) domain="$2"; shift 2;;
    -reality_domain) shift 2;; # deprecated, ignored
    -ONLY_CF_IP_ALLOW) CFALLOW="$2"; shift 2;;
    -uninstall) UNINSTALL="$2"; shift 2;;
    -block_ru) BLOCK_RU="$2"; shift 2;;
    -mode) MODE="$2"; shift 2;;
    -master_ip) MASTER_IP="$2"; shift 2;;
    -ssh_port) SSH_PORT="$2"; shift 2;;
    *) shift 1;;
  esac
done


##############################Uninstall#################################################################
UNINSTALL_XUI(){
	systemctl stop x-ui nginx 2>/dev/null || true
	systemctl disable x-ui nginx 2>/dev/null || true
	printf 'y\n' | x-ui uninstall 2>/dev/null || true
	rm -rf "/etc/x-ui/" "/usr/local/x-ui/" "/usr/bin/x-ui/" "/usr/bin/x-ui-temp"
	rm -rf /etc/systemd/system/x-ui.service /etc/systemd/system/x-ui.service.d
	rm -rf /etc/systemd/system/nginx.service.d
	rm -f /dev/shm/xhttp.sock /dev/shm/nginx-http.sock
	rm -f /etc/sysctl.d/99-xui-tuning.conf
	rm -f /etc/logrotate.d/xui-nginx
	rm -f /etc/fail2ban/jail.d/99-nginx-probe.local /etc/fail2ban/jail.d/99-sshd.local /etc/fail2ban/filter.d/nginx-probe.conf /var/log/nginx/probe.log
	rm -f /etc/ssh/sshd_config.d/99-custom-port.conf
	rm -f /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
	systemctl restart fail2ban 2>/dev/null || true
	systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
	rm -rf /etc/letsencrypt /root/cert
	rm -f /etc/apt/sources.list.d/nginx-mainline.list /etc/apt/preferences.d/99-nginx-mainline /usr/share/keyrings/nginx-archive-keyring.gpg
	crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|nginx" | crontab -
	sysctl --system 2>/dev/null || true
	systemctl daemon-reload 2>/dev/null || true
	$Pak -y remove nginx nginx-common nginx-core nginx-full libnginx-mod-stream python3-certbot-nginx certbot 2>/dev/null || true
	$Pak -y purge nginx nginx-common nginx-core nginx-full libnginx-mod-stream python3-certbot-nginx certbot 2>/dev/null || true
	$Pak -y autoremove 2>/dev/null || true
	$Pak -y autoclean 2>/dev/null || true
	rm -rf "/var/www/html/" "/etc/nginx/" "/usr/share/nginx/" "/var/log/nginx/"
}
if [[ ${UNINSTALL} == *"y"* ]]; then
	UNINSTALL_XUI	
	clear && msg_ok "Completely Uninstalled!" && exit 1
fi

###############################Install Required Packages & Utilities####################################
setup_nginx_mainline_repo() {
    # Why: Nginx Mainline (>=1.27) is required for native HTTP/2 proxying (proxy_http_version 2)
    # and http2_recv_buffer_size, eliminating gRPC-framing overhead for raw xHTTP streaming.
    if [[ "$Pak" != "apt" && "$Pak" != "apt-get" ]]; then
        return 0
    fi

    # Ensure prerequisite utilities for GPG key import and repo setup
    if ! command -v gpg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        $Pak -y update
        $Pak -y install curl gnupg lsb-release ca-certificates
    fi

    install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    # Import official nginx signing GPG key
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg

    local os_id distro_codename
    os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-ubuntu}")
    [[ "$os_id" != "debian" ]] && os_id="ubuntu"
    distro_codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
    if [[ -z "$distro_codename" ]] && command -v lsb_release >/dev/null 2>&1; then
        distro_codename=$(lsb_release -cs)
    fi

    # Add official Nginx Mainline repository
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/${os_id} ${distro_codename} nginx" \
        > /etc/apt/sources.list.d/nginx-mainline.list

    # Pinning: prefer official nginx.org packages over distribution packages
    cat > /etc/apt/preferences.d/99-nginx-mainline << 'PREF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 1001
PREF

    # Remove conflicting distribution packages if present
    $Pak -y remove nginx-full nginx-common nginx-core libnginx-mod-stream 2>/dev/null || true
}

install_dependencies() {
	msg_inf "Installing required system packages and utilities..."
	version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release 2>/dev/null || true)
	if [[ "$version" == "20" || "$version" == "22" || "$version" == "24" ]]; then
		echo "Версия системы: Ubuntu $version"
	fi

	if [[ "$Pak" == "apt" || "$Pak" == "apt-get" ]]; then
		export DEBIAN_FRONTEND=noninteractive
		setup_nginx_mainline_repo
		$Pak -y update
		$Pak -y install \
			curl \
			wget \
			jq \
			bash \
			sudo \
			netcat-openbsd \
			psmisc \
			procps \
			tar \
			unzip \
			sqlite3 \
			python3 \
			ufw \
			ca-certificates \
			openssl \
			tzdata \
			lsb-release \
			gnupg \
			dnsutils \
			nginx \
			certbot \
			python3-certbot-nginx \
			fail2ban \
			unattended-upgrades
	else
		$Pak -y update
		$Pak -y install \
			curl \
			wget \
			jq \
			bash \
			sudo \
			nc \
			psmisc \
			procps-ng \
			tar \
			unzip \
			sqlite \
			python3 \
			ufw \
			ca-certificates \
			openssl \
			tzdata \
			nginx \
			certbot \
			fail2ban \
			unattended-upgrades 2>/dev/null || true
	fi

	systemctl daemon-reload 2>/dev/null || true
	systemctl enable --now nginx 2>/dev/null || true
	msg_ok "All required utilities installed successfully!"
}

##################################Unattended Upgrades Setup#############################################
setup_unattended_upgrades() {
    # Why: Ensure Linux kernel and OS packages receive automatic security fixes without manual intervention.
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        return 0
    fi
    msg_inf "Configuring automatic security updates (unattended-upgrades)..."
    mkdir -p /etc/apt/apt.conf.d

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infrastructure-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable --now unattended-upgrades 2>/dev/null || true
    msg_ok "Automatic security updates configured successfully!"
}

if [[ ${INSTALL} != "n" ]]; then
	install_dependencies
	setup_unattended_upgrades
fi

# Cleanup old / legacy services
systemctl stop x-ui 2>/dev/null || true
rm -rf /etc/systemd/system/x-ui.service
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/stream-enabled /etc/nginx/snippets /etc/nginx/conf.d
rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*

##################################generate ports and paths#############################################################
declare -A USED_PORTS=()
USED_PORTS["${ANTILOOP_PORT}"]=1

get_port() {
    echo $(( ((RANDOM << 15) | RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    local out=""
    while [[ ${#out} -lt $length ]]; do
        out+=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length" || true)
    done
    printf '%s\n' "${out:0:length}"
}

check_free() {
    local port="$1"
    ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1
}

make_port() {
    local port
    while true; do
        port=$(get_port)
        [[ -z ${USED_PORTS[$port]+x} ]] || continue
        if check_free "$port"; then
            USED_PORTS["$port"]=1
            printf '%s\n' "$port"
            return 0
        fi
    done
}

# Reuse existing ports and paths if x-ui.db already exists
panel_port=""
panel_path=""
xhttp_port=""

if [[ -f "$XUIDB" ]]; then
    _db_val() { sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='$1' LIMIT 1;" 2>/dev/null || true; }
    _db_inbound_port() { sqlite3 "$XUIDB" "SELECT port FROM inbounds WHERE protocol='$1' LIMIT 1;" 2>/dev/null || true; }
    
    saved_panel_port=$(_db_val "webPort")
    saved_panel_path=$(_db_val "webBasePath")
    
    [[ "$saved_panel_port" =~ ^[0-9]+$ ]] && [[ "$saved_panel_port" -gt 1024 ]] && panel_port="$saved_panel_port"
    [[ -n "$saved_panel_path" ]] && panel_path=$(echo "$saved_panel_path" | tr -d '/')
    
    saved_xhttp_port=$(_db_inbound_port "vless" | head -n 1)
    [[ "$saved_xhttp_port" =~ ^[0-9]+$ ]] && [[ "$saved_xhttp_port" -gt 1024 ]] && xhttp_port="$saved_xhttp_port"
fi

[[ -z "$panel_port" ]] && panel_port=$(make_port)
[[ -z "$panel_path" ]] && panel_path=$(gen_random_string 10)
[[ -z "$xhttp_port" ]] && xhttp_port=$(make_port)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)

# --- get public IPv4 early (for auto-domain mode)
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>/dev/null | awk '/ src / {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
if ! [[ "$IP4" =~ $IP4_REGEX ]]; then
    IP4=$(curl -4fsS --max-time 10 https://ipv4.icanhazip.com | tr -d '[:space:]' || true)
fi

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    # panel domain: x.x.x.x.cdn-one.org
    domain="${IP4}.cdn-one.org"
fi

##############################Domain Validations########################################################
validate_domain() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" != .* && "$value" != *. ]] || return 1
    [[ "$value" != *..* ]] || return 1
    [[ "$value" != *"'"* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
}

sql_escape() {
    local value="$1"
    value=${value//\'/\'\'}
    printf '%s' "$value"
}

while true; do	
	if [[ -n "$domain" ]]; then
		domain=$(echo "$domain" 2>&1 | tr -d '[:space:]')
		if validate_domain "$domain"; then
			break
		else
			msg_err "Invalid domain format: $domain"
			domain=""
		fi
	fi
	echo -en "Enter available subdomain (sub.domain.tld): " && read -r domain 
done

SubDomain=$(echo "$domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
MainDomain=$(echo "$domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] ; then
	MainDomain=${domain}
fi

if [[ -z "$SSH_PORT" ]]; then
	if [ -t 0 ] && [[ "$AUTODOMAIN" != "y" ]]; then
		echo -en "Enter SSH port to harden server [default: 60022, press Enter for 60022, or 22 to keep]: " && read -r input_ssh_port
		SSH_PORT="${input_ssh_port:-60022}"
	else
		SSH_PORT="22"
	fi
fi

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 22 ] || [ "$SSH_PORT" -gt 65535 ]; then
	msg_err "Invalid SSH port: $SSH_PORT. Falling back to 22."
	SSH_PORT=22
fi

setup_ssh_port() {
    local target_port="${SSH_PORT:-22}"
    if [[ "$target_port" == "22" ]]; then
        msg_inf "SSH port remains standard 22."
        return 0
    fi

    msg_inf "Hardening SSH: moving from port 22 to $target_port..."
    # Guarantee firewall allows the new port BEFORE touching sshd configuration
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${target_port}/tcp" >/dev/null 2>&1 || true
    fi

    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-custom-port.conf << EOF
# Custom hardened SSH port configured by vpn_script
Port ${target_port}
EOF

    # Verify sshd configuration syntax before applying
    if command -v sshd >/dev/null 2>&1; then
        if ! sshd -t 2>/dev/null; then
            msg_err "sshd configuration syntax test failed with drop-in. Reverting to port 22."
            rm -f /etc/ssh/sshd_config.d/99-custom-port.conf
            return 1
        fi
    fi

    # Reload / restart SSH daemon safely (does not terminate active established connections)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service ssh reload 2>/dev/null || service ssh restart 2>/dev/null || true
    fi

    # Remove port 22 from UFW now that the new port is active
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
    fi
    msg_ok "SSH moved to port $target_port successfully."
}

###############################Prepare Ports and Firewalls for SSL######################################
# Keep the firewall enabled while Certbot binds to ports 80/443.
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
systemctl stop nginx 2>/dev/null || true
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true
##################################GET SERVER IPv4-6#####################################################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"
IP4=$(ip route get 8.8.8.8 2>/dev/null | awk '/ src / {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
IP6=$(ip route get 2620:fe::fe 2>/dev/null | awk '/ src / {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
[[ "$IP4" =~ $IP4_REGEX ]] || IP4=$(curl -4fsS --max-time 10 https://ipv4.icanhazip.com | tr -d '[:space:]' || true)
[[ "$IP6" =~ $IP6_REGEX ]] || IP6=$(curl -6fsS --max-time 10 https://ipv6.icanhazip.com | tr -d '[:space:]' || true)
##############################Install SSL###############################################################

dns_preflight_check() {
    # Why: Verify public DNS A-record points to this server IP before invoking Certbot.
    # Prevents triggering Let's Encrypt rate limits (failed validation limits: 5 failures/hour).
    local dom="$1"
    local server_ip="${IP4:-}"
    local resolved_ip=""

    [[ -z "$dom" ]] && return 0

    msg_inf "DNS preflight: checking A-record for ${dom}..."

    # Try authoritative public DNS via dig, fallback to getent
    if command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short +time=5 +tries=2 "$dom" A @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.' | head -n1 || true)
    fi
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    fi

    if [[ -z "$resolved_ip" ]]; then
        msg_err "Domain ${dom} does not resolve (NXDOMAIN). Check your DNS A-record."
        return 1
    elif [[ -n "$server_ip" && "$resolved_ip" != "$server_ip" ]]; then
        msg_err "IP mismatch: ${dom} resolves to ${resolved_ip}, but server IP is ${server_ip}."
        msg_inf "Wait for DNS propagation (TTL) or verify DNS management console."
        return 1
    fi

    msg_ok "DNS preflight passed: ${dom} -> ${resolved_ip}"
    return 0
}

resolve_to_ip () {
    local host="$1"
    # get first A-record
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    if ! dns_preflight_check "$domain"; then
        msg_err "Auto-domain $domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
fi


resolve_cert_path() {
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        return 0
    fi
    local alt_dir
    alt_dir=$(ls -d /etc/letsencrypt/live/${domain}-*/ 2>/dev/null | sort -V | tail -n 1)
    if [[ -n "$alt_dir" && -f "${alt_dir}fullchain.pem" ]]; then
        mkdir -p "/etc/letsencrypt/live/${domain}"
        ln -sf "${alt_dir}fullchain.pem" "/etc/letsencrypt/live/${domain}/fullchain.pem"
        ln -sf "${alt_dir}privkey.pem" "/etc/letsencrypt/live/${domain}/privkey.pem"
        return 0
    fi
    return 1
}

mkdir -p /var/www/html
if ! resolve_cert_path; then
    if ! dns_preflight_check "$domain"; then
        if [[ -t 0 ]]; then
            read -rp "DNS check failed. Continue requesting SSL certificate anyway? [y/N]: " continue_ssl || true
            if [[ ! "$continue_ssl" =~ ^[Yy]$ ]]; then
                msg_err "Aborting SSL certificate generation due to DNS check failure."
                exit 1
            fi
        else
            msg_inf "Non-interactive mode detected; continuing with certbot attempt..."
        fi
    fi

    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --cert-name "$domain" --keep-until-expiring -d "$domain" || \
    certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --register-unsafely-without-email --cert-name "$domain" --keep-until-expiring -d "$domain" || true
    resolve_cert_path || true
fi

if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
 	systemctl start nginx >/dev/null 2>&1 || true
	msg_err "$domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi
################################# Certbot renewal hook ##################################################
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx 2>/dev/null || /usr/sbin/nginx -s reload 2>/dev/null || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
################################# Access to configs only with cloudflare#################################

###################################Get Installed XUI Port/Path##########################################
if [[ -f $XUIDB ]]; then
	XUIPORT=$(sqlite3 -list "$XUIDB" 'SELECT "value" FROM settings WHERE "key"="webPort" LIMIT 1;' 2>&1)
	XUIPATH=$(sqlite3 -list "$XUIDB" 'SELECT "value" FROM settings WHERE "key"="webBasePath" LIMIT 1;' 2>&1)
if [[ $XUIPORT -gt 0 && $XUIPORT != "54321" && $XUIPORT != "2053" ]] && [[ ${#XUIPORT} -gt 4 ]]; then
	RNDSTR=$(echo "$XUIPATH" 2>&1 | tr -d '/')
	PORT=$XUIPORT
	sqlite3 "$XUIDB" <<EOF
	DELETE FROM "settings" WHERE ( "key"="webCertFile" ) OR ( "key"="webKeyFile" ); 
	INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  "");
	INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile", "");
EOF
fi
fi
#################################Nginx Config###########################################################
# Why: Ensure /dev/shm tmpfs directory exists for high-performance zero-copy Unix domain socket
install -d -m 755 /dev/shm

install -d -m 700 "/root/cert/${domain}"
chmod 700 /root/cert/
rm -f /root/cert/${domain}/*

ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${domain}/privkey.pem /root/cert/${domain}/privkey.pem

mkdir -p /etc/nginx/stream-enabled /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/snippets /etc/nginx/conf.d
rm -f /etc/nginx/conf.d/default.conf
# Why: Public L4 stream router listens on both IPv4 and IPv6 (if available).
# Internal upstream uses RAM unix socket (/dev/shm/nginx-http.sock), avoiding loopback TCP overhead.
IPV6_STREAM=""
if [[ -f /proc/net/if_inet6 ]]; then
    IPV6_STREAM="listen         [::]:443;"
fi

cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${domain}           www;
    default              www;
}

# Why: Primary upstream uses RAM-based Unix domain socket (/dev/shm/nginx-http.sock)
# to eliminate TCP loopback handshake overhead and syscall round-trips for xHTTP/XMUX.
upstream www {
    server unix:/dev/shm/nginx-http.sock;
}

# Why: L4 Failover upstream for REALITY / Steal-Oneself routing.
# When Xray core restarts or is temporarily unavailable, traffic fails over to the
# local mask site (backup socket) instead of terminating with connection refused,
# preventing active DPI probing detection.
upstream reality_failover {
    server 127.0.0.1:${ANTILOOP_PORT};
    server unix:/dev/shm/nginx-http.sock backup;
}

server {
    proxy_protocol on;
    listen          443;
    ${IPV6_STREAM}
    proxy_pass      \$sni_name;
    ssl_preread     on;
}

EOF

# Why: Load dynamic stream module only if module file exists and not already loaded/built-in
if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]] && ! grep -rq "ngx_stream_module" /etc/nginx/ 2>/dev/null; then
    sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
fi

sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf 2>/dev/null || true

# Worker rlimit (idempotent)
sed -i "/worker_rlimit_nofile/d" /etc/nginx/nginx.conf 2>/dev/null || true
echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf

# Stream block inclusion (idempotent)
sed -i "/stream-enabled/d" /etc/nginx/nginx.conf 2>/dev/null || true
echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf

# HTTP block inclusions (idempotent)
sed -i "/http2_recv_buffer_size/d" /etc/nginx/nginx.conf 2>/dev/null || true
sed -i '/http {/a \    http2_recv_buffer_size 16m;' /etc/nginx/nginx.conf

sed -i "/sites-enabled/d" /etc/nginx/nginx.conf 2>/dev/null || true
sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf

grep -q "conf\.d/\*\.conf;" /etc/nginx/nginx.conf 2>/dev/null || sed -i '/http {/a \    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf

# Prepare probe log file and directory with secure permissions
mkdir -p /var/log/nginx
touch /var/log/nginx/probe.log
chmod 640 /var/log/nginx/probe.log
NGX_LOG_USER=$(awk '$1=="user" {gsub(";", "", $2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null || echo "www-data")
[[ -z "$NGX_LOG_USER" ]] && NGX_LOG_USER="www-data"
chown "${NGX_LOG_USER}:adm" /var/log/nginx/probe.log 2>/dev/null || chown www-data:adm /var/log/nginx/probe.log 2>/dev/null || true

# Nginx Rate Limiting and Attack Probe Logging
mkdir -p /etc/nginx/conf.d
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


cat > "/etc/nginx/sites-available/${domain}" << EOF
# Why: Reject direct IP scans and TLS handshakes with missing/non-matching SNI,
# preventing active probing and certificate disclosure on the unix domain socket.
server {
    listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}

server {
# =====================================================================
# VLESS XHTTP STREAM-ONE (Native HTTP/2 Proxying)
# =====================================================================
location /videos/media/ts/1080/ {
    # Why: Stream-One uses GET for downlink and POST for uplink; reject invalid methods early
    if (\$request_method !~ ^(GET|POST)\$) {
        return 404;
    }

    # Why: Native HTTP/2 Cleartext (h2c) proxying without gRPC framing overhead
    proxy_http_version 2;
    proxy_pass http://127.0.0.1:${xhttp_port};

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

    # Zero-log policy for active proxy traffic
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
	if (\$request_uri ~ "(\"|'|\`|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
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
	listen 127.0.0.1:${ANTILOOP_PORT} ssl;
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

cat > "/etc/nginx/snippets/includes.conf" << EOF
	location / { try_files \$uri \$uri/ =404; }
EOF

##################################Check Nginx status####################################################
if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
	rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
	ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
	ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/" 2>/dev/null
else
	msg_err "${domain} nginx config not exist!" && exit 1
fi

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
    echo "--- NGINX CONFIG ERROR DIAGNOSTIC ---" >&2
    nginx -t >&2 || true
    echo "--------------------------------------" >&2
    msg_err "nginx config is not ok!" && exit 1
else
	systemctl start nginx 2>/dev/null || service nginx start 2>/dev/null || true
fi

########################################Update X-UI Port/Path for first INSTALL#########################
UPDATE_XUIDB(){
if [[ -f "$XUIDB" ]]; then
        systemctl stop x-ui 2>/dev/null || true
        # Why: Restrict directory and database permissions so non-root users cannot read sensitive credentials/tokens
        chmod 700 /etc/x-ui
        chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true
        XRAY_BIN=$(xray_bin)
        [[ -x "$XRAY_BIN" ]] || { msg_err "Xray binary not found: $XRAY_BIN"; return 1; }
        client_id=$("$XRAY_BIN" uuid)
        emoji_flag=$(LC_ALL=C curl -fsS --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji // ""' || true)
        [[ "$emoji_flag" == "null" ]] && emoji_flag=""
        vlessenc_output=$("$XRAY_BIN" vlessenc 2>/dev/null || true)
        vless_decryption=$(echo "$vlessenc_output" | grep '"decryption":' | tail -n 1 | sed 's/.*"decryption": "\(.*\)".*/\1/' || true)
        vless_encryption=$(echo "$vlessenc_output" | grep '"encryption":' | tail -n 1 | sed 's/.*"encryption": "\(.*\)".*/\1/' || true)
        [[ -z "$vless_decryption" ]] && vless_decryption="none"
        [[ -z "$vless_encryption" ]] && vless_encryption="none"
        sql_domain=$(sql_escape "$domain")
        sql_emoji_flag=$(sql_escape "$emoji_flag")
       	sqlite3 "$XUIDB" <<EOF
		 INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("subClashEnable",  'false');
		 INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("subEnableRouting",  'false');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("subEnable",  'false');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("webListen",  '127.0.0.1');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("webDomain",  '');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("webCertFile",  '');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("webKeyFile",  '');
       	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("sessionMaxAge",  '60');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("pageSize",  '50');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("expireDiff",  '0');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("trafficDiff",  '0');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("remarkModel",  '-ieo');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotEnable",  'false');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotToken",  '');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotProxy",  '');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotAPIServer",  '');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotChatId",  '');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgRunTime",  '@daily');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotBackup",  'false');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgBotLoginNotify",  'true');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgCpu",  '80');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("tgLang",  'en-US');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("timeLocation",  'Europe/Moscow');
             INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("secretEnable",  'false');
	     INSERT OR REPLACE INTO "settings" ("key", "value") VALUES ("datepicker",  'gregorian');
EOF

        inbound_count=$(sqlite3 "$XUIDB" "SELECT count(*) FROM inbounds;" 2>/dev/null || echo "0")
        if [[ "$inbound_count" -eq 0 ]]; then
            sqlite3 "$XUIDB" <<EOF
             DELETE FROM "client_traffics";
             DELETE FROM "inbounds";
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','firstX','0','0','0','0','0');
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${sql_emoji_flag} xhttp',
	     '1',
             '0',
	     '127.0.0.1',
             '${xhttp_port}',
	     'vless',
             '{
  "clients": [
    {
      "id": "${client_id}",
      "flow": "xtls-rprx-vision",
      "email": "firstX",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": 0,
      "subId": "first",
      "comment": "",
      "reset": 0,
      "created_at": 1788682100924,
      "updated_at": 1788682100000
    }
  ],
  "decryption": "${vless_decryption}",
  "encryption": "${vless_encryption}"
}','{
  "network": "xhttp",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "xhttpSettings": {
    "path": "/videos/media/ts/1080/",
    "host": "${domain}",
    "mode": "stream-one",
    "xPaddingBytes": "128-1120",
    "xPaddingObfsMode": true,
    "xPaddingKey": "X-Amz-Meta-Trace",
    "xPaddingHeader": "X-Amz-Security-Token",
    "xPaddingPlacement": "header",
    "xPaddingMethod": "tokenish",
    "sessionIDPlacement": "header",
    "sessionIDKey": "x-amz-cf-id",
    "sessionIDTable": "Base62",
    "sessionIDLength": "16-32",
    "seqPlacement": "header",
    "seqKey": "x-amz-cf-pop",
    "scMaxBufferedPosts": 30,
    "scStreamUpServerSecs": "20-80",
    "uplinkHTTPMethod": "POST",
    "enableXmux": true,
    "xmux": {
      "maxConcurrency": "0",
      "maxConnections": "1-3",
      "cMaxReuseTimes": "300-600",
      "hMaxRequestTimes": "1000-2000",
      "hMaxReusableSecs": "1200-2400",
      "hKeepAlivePeriod": 600
    }
  },
  "sockopt": {
    "tcpcongestion": "bbr",
    "trustedXForwardedFor": [
      "X-Real-IP"
    ],
    "acceptProxyProtocol": false
  }
}',
             'in-${xhttp_port}-tcp',
	     '{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','firstHy2','0','0','0','0','0');
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${sql_emoji_flag} hysteria2',
	     '1',
             '0',
	     '0.0.0.0',
             '443',
	     'hysteria',
             '{
  "version": 2,
  "auth": "${client_id}",
  "users": [
    {
      "auth": "${client_id}",
      "email": "firstHy2",
      "enable": true
    }
  ],
  "clients": [
    {
      "id": "${client_id}",
      "auth": "${client_id}",
      "email": "firstHy2",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true
    }
  ]
}',
             '{
  "network": "hysteria",
  "security": "tls",
  "tlsSettings": {
    "alpn": [
      "h3"
    ],
    "minVersion": "1.3",
    "certificates": [
      {
        "certificateFile": "/root/cert/${domain}/fullchain.pem",
        "keyFile": "/root/cert/${domain}/privkey.pem"
      }
    ]
  },
  "hysteriaSettings": {
    "version": 2,
    "auth": "${client_id}",
    "udpIdleTimeout": 60,
    "masquerade": {
      "type": "proxy",
      "url": "http://127.0.0.1:80",
      "rewriteHost": true
    }
  },
  "sockopt": {
    "tcpcongestion": "bbr",
    "trustedXForwardedFor": [
      "X-Real-IP"
    ]
  }
}',
             'in-443-udp',
	     '{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
EOF
        else
            msg_inf "Existing inbounds detected ($inbound_count). Preserving users and keys."
        fi
/usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}"
/usr/local/x-ui/x-ui cert -webCert "/root/cert/${domain}/fullchain.pem" -webCertKey "/root/cert/${domain}/privkey.pem"
# Why: Re-enforce strict directory and database permissions following CLI configuration updates
chmod 700 /etc/x-ui
chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true
systemctl restart x-ui 2>/dev/null || true
else
	msg_err "x-ui.db file not exist! Maybe x-ui isn't installed." && exit 1;
fi
}
##############################Upgrade Xray-core to latest##############################################
upgrade_xray_core() {
    local XRAY_LATEST TMP_DIR XRAY_ASSET TARGET
    XRAY_LATEST=$(curl -fsS --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [[ -z "$XRAY_LATEST" ]]; then
        msg_err "Failed to fetch latest Xray-core version (rate limit or network error). Keeping existing binary."
        return 0
    fi

    case "$(arch)" in
        amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        386) XRAY_ASSET="Xray-linux-32.zip" ;;
        arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        armv5|armv6)
            msg_err "Xray automatic upgrade is not supported for $(arch). Install a compatible Xray binary manually."
            return 0
            ;;
        *) msg_err "Unsupported Xray architecture: $(arch)"; return 0 ;;
    esac

    TARGET="$(xray_bin)"
    [[ -n "$TARGET" ]] || return 0

    msg_inf "Upgrading Xray-core to ${XRAY_LATEST} (${XRAY_ASSET})..."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' RETURN

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o "${TMP_DIR}/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_LATEST}/${XRAY_ASSET}" 2>/dev/null; then
        msg_err "Failed to download Xray-core archive. Keeping existing binary."
        return 0
    fi

    unzip -tqq "${TMP_DIR}/xray.zip" || { msg_err "Corrupted Xray zip archive. Keeping existing binary."; return 0; }
    unzip -o "${TMP_DIR}/xray.zip" xray -d "${TMP_DIR}/extract" >/dev/null
    install -m 0755 "${TMP_DIR}/extract/xray" "$TARGET"

    systemctl restart x-ui 2>/dev/null || true
    msg_ok "Xray-core updated to ${XRAY_LATEST}"
}
##############################RU-Block (Outbound block for RU resources)################################
apply_ru_block() {
    msg_inf "Configuring RU-Block (Outbound block for RU resources)..."

    # Backup database
    if [[ -f "$XUIDB" ]]; then
        cp "$XUIDB" "${XUIDB}.backup_ru"
        msg_ok "Database backed up to ${XUIDB}.backup_ru"
        # Why: Restrict permissions on database backup file immediately upon creation
        chmod 700 /etc/x-ui
        chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true
    fi

    # Download latest geo databases
    msg_inf "Downloading latest geo databases (geosite_RU.dat, geoip.dat, geosite.dat)..."
    mkdir -p /usr/local/x-ui/bin
    curl -fsSL --connect-timeout 10 --max-time 60 "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite_RU.dat 2>/dev/null || true
    curl -fsSL --connect-timeout 10 --max-time 60 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o /usr/local/x-ui/bin/geoip.dat 2>/dev/null || true
    curl -fsSL --connect-timeout 10 --max-time 60 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -o /usr/local/x-ui/bin/geosite.dat 2>/dev/null || true
    ln -sf /usr/local/x-ui/bin/geoip.dat /usr/local/x-ui/bin/geoip_IR.dat

    if [[ ! -s /usr/local/x-ui/bin/geosite_RU.dat ]]; then
        msg_err "geosite_RU.dat is missing or empty. Skipping RU-Block rule injection to prevent Xray startup crash."
        return 0
    fi

    # Inject RU-Block rule, outbounds and DNS/hosts via Python
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

    # 1. Outbounds (direct and blocked)
    if "outbounds" not in config or not isinstance(config["outbounds"], list) or len(config["outbounds"]) == 0:
        config["outbounds"] = [
            {
                "protocol": "freedom",
                "tag": "direct",
                "settings": {
                    "domainStrategy": "UseIP"
                }
            },
            {
                "protocol": "blackhole",
                "tag": "blocked",
                "settings": {}
            }
        ]
    else:
        existing_tags = [o.get("tag") for o in config["outbounds"] if isinstance(o, dict)]
        if "direct" not in existing_tags:
            config["outbounds"].append({
                "protocol": "freedom",
                "tag": "direct",
                "settings": {"domainStrategy": "UseIP"}
            })
        if "blocked" not in existing_tags:
            config["outbounds"].append({
                "protocol": "blackhole",
                "tag": "blocked",
                "settings": {}
            })

    # 2. DNS & Hosts
    if "dns" not in config or not isinstance(config["dns"], dict):
        config["dns"] = {
            "servers": [
                "https+local://1.1.1.1/dns-query",
                "1.1.1.1",
                "8.8.8.8",
                "localhost"
            ],
            "hosts": {
                "domain:googleapis.cn": "googleapis.com"
            }
        }
    else:
        if "servers" not in config["dns"] or not config["dns"]["servers"]:
            config["dns"]["servers"] = [
                "https+local://1.1.1.1/dns-query",
                "1.1.1.1",
                "8.8.8.8",
                "localhost"
            ]
        if "hosts" not in config["dns"] or not config["dns"]["hosts"]:
            config["dns"]["hosts"] = {
                "domain:googleapis.cn": "googleapis.com"
            }

    # 3. Routing rules
    user_rules = [
        {
            "type": "field",
            "inboundTag": ["api"],
            "outboundTag": "api"
        },
        {
            "type": "field",
            "enabled": True,
            "domain": ["ext:geosite_RU.dat:ru-blocked-all"],
            "ip": ["geoip:ru", "ext:geoip_IR.dat:ru"],
            "outboundTag": "blocked"
        },
        {
            "type": "field",
            "ip": ["geoip:private"],
            "outboundTag": "blocked"
        },
        {
            "type": "field",
            "protocol": ["bittorrent"],
            "outboundTag": "blocked"
        },
        {
            "type": "field",
            "enabled": True,
            "port": "443",
            "network": "udp",
            "outboundTag": "blocked"
        }
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

    cursor.execute("SELECT 1 FROM settings WHERE key = 'xrayTemplateConfig'")
    if cursor.fetchone():
        cursor.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (json.dumps(config, indent=2),))
    else:
        cursor.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (json.dumps(config, indent=2),))

    conn.commit()
    conn.close()
    print("RU-Block, Outbounds and Hosts injected successfully.")
except Exception as e:
    print(f"Error injecting RU-Block rule: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    # Why: Enforce strict directory and database permissions after RU-Block rules injection
    chmod 700 /etc/x-ui
    chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true

    # Restart x-ui to apply
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        systemctl restart x-ui 2>/dev/null || true
    fi
    msg_ok "RU-Block active. Rollback: cp ${XUIDB}.backup_ru ${XUIDB} && systemctl restart x-ui"
}
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

xray_bin() {
    case "$(arch)" in
        amd64) printf '%s\n' '/usr/local/x-ui/bin/xray-linux-amd64' ;;
        386)   printf '%s\n' '/usr/local/x-ui/bin/xray-linux-386' ;;
        arm64) printf '%s\n' '/usr/local/x-ui/bin/xray-linux-arm64' ;;
        armv7|armv6|armv5) printf '%s\n' '/usr/local/x-ui/bin/xray-linux-arm' ;;
        s390x) printf '%s\n' '/usr/local/x-ui/bin/xray-linux-s390x' ;;
        *) return 1 ;;
    esac
}

config_after_install() {
    # Do not expose or temporarily enable well-known default credentials.
    /usr/local/x-ui/x-ui migrate
    # Why: Restrict permissions immediately after migration initializes the database
    chmod 700 /etc/x-ui 2>/dev/null || true
    chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true
}

install_panel() {
apt-get update && apt-get install -y -q wget curl tar tzdata
    cd /usr/local/
    
    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls --max-time 15 "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls --max-time 15 "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
            if [[ ! -n "$tag_version" ]]; then
                tag_version="v2.4.9"
                echo -e "${yellow}GitHub API rate limit or network issue; using default stable version: ${tag_version}${plain}"
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        wget -N -O "/usr/local/x-ui-linux-$(arch).tar.gz" "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"
        
        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi
        
        url="https://github.com/MHSanaei/3x-ui/releases/download/v${tag_version_numeric}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    fi
    wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui.sh${plain}"
        exit 1
    fi
    
    # Stop x-ui service and remove old resources
    if [[ -e /usr/local/x-ui/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui 2>/dev/null || true
        fi
        rm /usr/local/x-ui/ -rf
    fi
    
    # Extract resources and set permissions
    tar -zxf "x-ui-linux-$(arch).tar.gz"
    rm x-ui-linux-$(arch).tar.gz -f
    
    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh
    
    # Normalize legacy ARM binary name used by the panel.
    if [[ "$(arch)" == "armv5" || "$(arch)" == "armv6" || "$(arch)" == "armv7" ]]; then
        mv -f "bin/xray-linux-$(arch)" bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)
    
    # Update x-ui cli and se set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
	config_after_install
    
    if [[ $release == "alpine" ]]; then
        wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
    else
        # Why: Enable service on startup, but do NOT start x-ui here.
        # Defer starting until webListen='127.0.0.1' is written to the database to eliminate 0.0.0.0 bind race window.
        cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable x-ui 2>/dev/null || true
    fi
    
    echo -e "${green}x-ui ${tag_version}${plain} installation finished..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"

}

######################Sysctl Kernel Tuning##############################################################
apply_sysctl_tuning() {
    # Why: Optimize Linux kernel for high-concurrency proxy workloads, UDP transport (Hysteria 2 / AWG),
    # xHTTP streaming stall prevention, and routing forwarding.
    cat > /etc/sysctl.d/99-xui-tuning.conf << 'SYSCTL'
# --- Congestion control & queuing (BBR) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- File descriptors & filesystem watcher limits ---
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# --- TCP connection handshake & backlog (prevents drops under high connection bursts) ---
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384

# --- TCP Fast Open (0-RTT client & server handshake) ---
net.ipv4.tcp_fastopen = 3

# --- TIME_WAIT recycling for rapid short-lived connection reuse ---
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1

# --- Memory buffers for TCP and UDP (Hysteria 2 / AmneziaWG) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- xHTTP stream stall prevention (reduces bufferbloat on active streams) ---
net.ipv4.tcp_notsent_lowat = 16384

# --- Path MTU discovery (prevents packet fragmentation bottlenecks) ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024

# --- Dirty page writeback latency reduction ---
vm.dirty_ratio = 6
vm.dirty_background_ratio = 3

# --- IP forwarding for inbound/outbound tunneling ---
net.ipv4.ip_forward = 1
SYSCTL

    sysctl --system 2>/dev/null || true
}

###################################Install X-UI#########################################################
if [[ "${MODE}" == "node" ]]; then
    # Node mode: install panel without master DB setup
    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        install_panel
    fi
    upgrade_xray_core || true
    /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}" 2>/dev/null || true
    if [[ -f "$XUIDB" ]]; then
        # Why: Ensure webListen is bound strictly to loopback interface on node instances
        sqlite3 "$XUIDB" "INSERT OR REPLACE INTO \"settings\" (\"key\", \"value\") VALUES ('webListen', '127.0.0.1');"
        # Why: Enforce strict permissions on panel directory and sqlite database files
        chmod 700 /etc/x-ui
        chmod 600 /etc/x-ui/x-ui.db* 2>/dev/null || true
    fi
    systemctl restart x-ui 2>/dev/null || true

    # Why: Apply kernel network performance optimizations on node instances
    apply_sysctl_tuning

    # Why: Enforce firewall isolation on node instances, restricting panel port access to master node IP
    if command -v ufw >/dev/null 2>&1; then
        ufw default deny incoming || true
        ufw default allow outgoing || true
        ufw allow "${SSH_PORT:-22}/tcp" || true
        ufw allow 80/tcp || true
        ufw allow 443/tcp || true
        ufw allow 443/udp || true
        if [[ -n "${MASTER_IP}" ]]; then
            ufw allow from "${MASTER_IP}" to any port "${panel_port}" proto tcp || true
        fi
        ufw --force enable || true
    fi
    setup_ssh_port

    msg_inf "=== NODE DEPLOYMENT COMPLETE ==="
    msg_inf "Node IP: ${IP4}"
    msg_inf "Panel: https://${domain}/${panel_path}/"
    echo -e "Username:  ${config_username}"
    echo -e "Password:  ${config_password}"
    if [[ -n "${MASTER_IP}" ]]; then
        msg_inf "To add this node on Master (${MASTER_IP}):"
        msg_inf "  Address: ${IP4}, Port: ${panel_port}"
    fi
    exit 0
fi

if [[ ! -f /usr/local/x-ui/x-ui ]]; then
    install_panel
fi

XRAY_BIN=$(xray_bin)
[[ -x "$XRAY_BIN" ]] || { msg_err "Xray binary is missing: $XRAY_BIN"; exit 1; }
UPDATE_XUIDB
upgrade_xray_core || true
if [[ "${BLOCK_RU}" == *"y"* ]]; then
    apply_ru_block
fi
if ! systemctl is-enabled --quiet x-ui 2>/dev/null; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable x-ui.service 2>/dev/null || true
fi
systemctl restart x-ui 2>/dev/null || true
nginx -t
systemctl restart nginx 2>/dev/null || true

######################enable bbr and tune system########################################################
apply_sysctl_tuning

# LimitNOFILE for Nginx
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'SYSD'
[Service]
LimitNOFILE=65535
SYSD

# LimitNOFILE for x-ui
mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf << 'SYSD'
[Service]
LimitNOFILE=65535
SYSD

systemctl daemon-reload 2>/dev/null || true

# Logrotate for Nginx (aggressive: 3 days with compression)
cat > /etc/logrotate.d/xui-nginx << 'LOGR'
/var/log/nginx/*.log {
    daily
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
    endscript
}
LOGR




#################################Fail2ban Configuration################################################
setup_fail2ban() {
    msg_inf "Configuring Fail2ban anti-probing, rate limiting, and SSH protection..."
    mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /var/log/nginx
    touch /var/log/nginx/probe.log /var/log/auth.log
    chmod 640 /var/log/nginx/probe.log /var/log/auth.log
    chown www-data:adm /var/log/nginx/probe.log 2>/dev/null || true

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

    local ssh_jail_port="${SSH_PORT:-22}"
    cat > /etc/fail2ban/jail.d/99-sshd.local << EOF
[sshd]
enabled   = true
port      = ${ssh_jail_port}
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 3
findtime  = 600
bantime   = 86400
banaction = ufw
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service fail2ban restart 2>/dev/null || true
    fi
}
setup_fail2ban

######################install_fake_site#################################################################

FAKE_SITE_TMP=$(mktemp -d)
if wget -qO "$FAKE_SITE_TMP/repo.tar.gz" "https://github.com/mozaroc/3x-ui-pro/archive/refs/heads/main.tar.gz" \
	&& tar -xzf "$FAKE_SITE_TMP/repo.tar.gz" -C "$FAKE_SITE_TMP" --strip-components=3 "3x-ui-pro-main/assets/fake-sites"; then
	FAKE_SITES=("$FAKE_SITE_TMP"/site-*/)
	FAKE_SITE="${FAKE_SITES[$((RANDOM % ${#FAKE_SITES[@]}))]}"
	msg_inf "Random fake site template: $(basename "$FAKE_SITE")"
	mkdir -p /var/www/html
	rm -rf /var/www/html/*
	cp -a "$FAKE_SITE". /var/www/html/
	msg_ok "Fake site installed successfully!"
else
	msg_err "Failed to download fake site templates!"
	# Fallback: generate a minimal corporate placeholder
	mkdir -p /var/www/html
	cat > /var/www/html/index.html << 'FAKEHTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Service Status</title>
<style>body{font-family:system-ui;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#f8f9fa;color:#495057;}
.c{text-align:center;}.c h1{font-size:2rem;margin-bottom:.5rem;}.c p{color:#868e96;}</style></head>
<body><div class="c"><h1>Service Operational</h1><p>All systems are running normally.</p></div></body>
</html>
FAKEHTML
fi
rm -rf "$FAKE_SITE_TMP"



######################cronjob for ssl/reload service/cloudflareips######################################
if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|cloudflareips" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo '@daily x-ui restart > /dev/null 2>&1 && (systemctl reload nginx 2>/dev/null || /usr/sbin/nginx -s reload 2>/dev/null);') | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo '@monthly certbot renew --webroot -w /var/www/html --quiet && (systemctl reload nginx 2>/dev/null || /usr/sbin/nginx -s reload 2>/dev/null);') | crontab - 2>/dev/null || true
fi
##################################ufw###################################################################
if command -v ufw >/dev/null 2>&1; then
    ufw default deny incoming || true
    ufw default allow outgoing || true
    ufw allow "${SSH_PORT:-22}/tcp" || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 443/udp || true
    ufw --force enable || true
fi
setup_ssh_port

# Build direct client connection URI (VLESS xHTTP stream-one)
if [[ -z "$client_id" && -f "$XUIDB" ]]; then
    client_id=$(sqlite3 "$XUIDB" "SELECT json_extract(settings, '$.clients[0].id') FROM inbounds WHERE protocol='vless' LIMIT 1;" 2>/dev/null || true)
fi
if [[ -z "$vless_encryption" && -f "$XUIDB" ]]; then
    vless_encryption=$(sqlite3 "$XUIDB" "SELECT json_extract(settings, '$.encryption') FROM inbounds WHERE protocol='vless' LIMIT 1;" 2>/dev/null || true)
fi
[[ -z "$vless_encryption" || "$vless_encryption" == "null" ]] && vless_encryption="none"
[[ -z "$emoji_flag" ]] && emoji_flag=$(LC_ALL=C curl -fsS --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji // ""' 2>/dev/null || true)
[[ "$emoji_flag" == "null" ]] && emoji_flag=""

CLIENT_VLESS_URL="vless://${client_id}@${domain}:443?type=xhttp&security=tls&encryption=${vless_encryption}&flow=xtls-rprx-vision&path=%2Fvideos%2Fmedia%2Fts%2F1080%2F&mode=stream-one&sni=${domain}#${emoji_flag}%20${domain}%20(xHTTP)"
CLIENT_HY2_URL="hysteria2://${client_id}@${domain}:443/?sni=${domain}&alpn=h3#${emoji_flag}%20${domain}%20(Hysteria2)"

##################################Show Details##########################################################

if systemctl is-active --quiet x-ui 2>/dev/null; then
    clear
    printf '0\n' | x-ui | grep --color=never -i ':' || true
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	nginx -T | grep -i 'ssl_certificate\|ssl_certificate_key'
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	certbot certificates | grep -i 'Path:\|Domains:\|Expiry Date:'

#	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
#	if [[ -n $IP4 ]] && [[ "$IP4" =~ $IP4_REGEX ]]; then 
#		msg_inf "IPv4: http://$IP4:$PORT/$RNDSTR/"
#	fi
#	if [[ -n $IP6 ]] && [[ "$IP6" =~ $IP6_REGEX ]]; then 
#		msg_inf "IPv6: http://[$IP6]:$PORT/$RNDSTR/"
#	fi

	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
 	echo -e "Username:  ${config_username} \n" 
	echo -e "Password:  ${config_password} \n" 
	if [[ "${SSH_PORT:-22}" != "22" ]]; then
		msg_inf "SSH Hardened Port: ${SSH_PORT} (Connect with: ssh -p ${SSH_PORT} root@${domain})\n"
	fi
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "Direct Client Connection (VLESS-xHTTP):"
	echo -e "${CLIENT_VLESS_URL}\n"
	msg_inf "Direct Client Connection (Hysteria 2 UDP Backup):"
	echo -e "${CLIENT_HY2_URL}\n"
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "Please Save this Screen!!"	
else
	nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
	msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
fi
#################################################N-joy##################################################
