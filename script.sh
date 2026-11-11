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
UNINSTALL="n"
DRY_RUN=n
ADOPT_LEGACY=n
ADOPT_TOKEN=""
DNS_PROVIDER=""
SSH_CONFIRM=n
SSH_ROLLBACK=n
PUBLIC_IP4=""
PUBLIC_IP6=""
INSTALL="y"
BLOCK_RU="y"
AUTODOMAIN="n"
# Why: Dedicated internal port for Xray Steal-Oneself fallback, preventing infinite loopback to 443
ANTILOOP_PORT=9443
# Hardened SSH port (default 60022 if configured or specified via -ssh_port)
SSH_PORT=""
SSH_PORT_EXPLICIT=n
MASK_UPSTREAM=""
MASK_PORT=""
XHTTP_CONFIG_PATH=""
XHTTP_DOWNLOAD_PATH=""
REALITY_TARGET=""
REALITY_TARGET_EXPLICIT=n

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LIB_DIR="$SCRIPT_DIR/lib"
if [[ "$SCRIPT_DIR" == /usr/local/sbin ]]; then LIB_DIR=/usr/local/lib/vpn-script; fi
source "$LIB_DIR/deployment.sh"
source "$LIB_DIR/versions.conf"
source "$LIB_DIR/release.sh"
source "$LIB_DIR/ssh.sh"
source "$LIB_DIR/download.sh"

while (( $# > 0 )); do
    if (( $# < 2 )); then deployment_error "Missing value for $1"; exit 1; fi
    case "$1" in
        -auto_domain) AUTODOMAIN=$2 ;;
        -install) INSTALL=$2 ;;
        -subdomain) domain=$2 ;;
        -uninstall) UNINSTALL=$2 ;;
        -block_ru) BLOCK_RU=$2 ;;
        -ssh_port) SSH_PORT=$2; SSH_PORT_EXPLICIT=y ;;
        -mask_upstream) MASK_UPSTREAM=$2 ;;
        -mask_port) MASK_PORT=${2:?Missing mask port} ;;
        -xhttp_config_path) XHTTP_CONFIG_PATH=${2:?Missing xHTTP file path} ;;
        -xhttp_download_path) XHTTP_DOWNLOAD_PATH=${2:?Missing xHTTP download path} ;;
        -reality_target) REALITY_TARGET=$2; REALITY_TARGET_EXPLICIT=y ;;
        -dry_run) DRY_RUN=$2 ;;
        -adopt_legacy) ADOPT_LEGACY=$2 ;;
        -adopt_token) ADOPT_TOKEN=$2 ;;
        -dns_provider) DNS_PROVIDER=$2 ;;
        -ssh_confirm) SSH_CONFIRM=$2 ;;
        -ssh_rollback) SSH_ROLLBACK=$2 ;;
        -public_ip4) PUBLIC_IP4=$2 ;;
        -public_ip6) PUBLIC_IP6=$2 ;;
        *) deployment_error "Unknown option: $1"; exit 1 ;;
    esac
    shift 2
done

for option in UNINSTALL INSTALL BLOCK_RU AUTODOMAIN DRY_RUN ADOPT_LEGACY SSH_CONFIRM SSH_ROLLBACK; do
    if [[ "${!option}" != y && "${!option}" != n ]]; then
        deployment_error "$option must be y or n"
        exit 1
    fi
done
if [[ "$SSH_CONFIRM" == y || "$SSH_ROLLBACK" == y ]]; then
    if [[ "$DRY_RUN" == y || "$UNINSTALL" == y || ( "$SSH_CONFIRM" == y && "$SSH_ROLLBACK" == y ) ]]; then
        deployment_error "SSH confirmation and rollback require a single explicit action"
        exit 1
    fi
    deployment_lock
    if [[ "$SSH_CONFIRM" == y ]]; then
        ssh_migration_confirm
    else
        ssh_migration_rollback_expired
    fi
    exit
fi
case "$DNS_PROVIDER" in
    ""|xboxdns|geohide|comss|none) ;;
    *) deployment_error "Unknown DNS provider"; exit 1 ;;
esac
if [[ "$DRY_RUN" != y ]]; then
    deployment_lock
    if [[ -e "$STATE_DIR/active" || -L "$STATE_DIR/active" ]]; then
        if ! pending_deployment=$(deployment_active); then
            deployment_error "Cannot read the deployment recovery journal"
            exit 1
        fi
        if ! deployment_rollback "$pending_deployment"; then
            printf 'Rollback incomplete. Recovery data: %s\n' "$pending_deployment" >&2
            exit 1
        fi
    fi
    ssh_migration_rollback_expired
    if ssh_migration_pending; then
        deployment_error "Confirm the pending SSH migration or wait for its rollback"
        exit 1
    fi
fi
if [[ "$UNINSTALL" == y ]]; then
    deployment_uninstall
    exit
fi
Pak=apt-get

arch() {
    case "$(uname -m)" in
        x86_64) printf 'amd64\n' ;;
        aarch64) printf 'arm64\n' ;;
        *) deployment_error "Unsupported CPU architecture"; return 1 ;;
    esac
}

xray_bin() {
    local architecture
    architecture=$(arch) || return 1
    printf '/usr/local/x-ui/bin/xray-linux-%s\n' "$architecture"
}

check_installed_panel_version() {
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        local installed
        installed=$(/usr/local/x-ui/x-ui -v)
        installed=${installed##* }
        if dpkg --compare-versions "${installed#v}" gt "${PANEL_VERSION#v}"; then
            deployment_error "Installed panel is newer than the supported release"
            return 1
        fi
    fi
}

prepare_panel_release() {
    panel_needs_install=n
    local asset="x-ui-linux-$(arch).tar.gz" expected xray_actual installed
    case "$(arch)" in
        amd64) expected=$PANEL_SHA256_AMD64 ;;
        arm64) expected=$PANEL_SHA256_ARM64 ;;
    esac
    check_installed_panel_version || return 1
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        installed=$(/usr/local/x-ui/x-ui -v)
        installed=${installed##* }
        if [[ "$installed" == "${PANEL_VERSION#v}" ]]; then
            if [[ -x "/usr/local/x-ui/bin/xray-linux-$(arch)" ]]; then
                xray_actual=$("/usr/local/x-ui/bin/xray-linux-$(arch)" version)
                if [[ "$xray_actual" == "Xray ${XRAY_VERSION#v} "* ]]; then return 0; fi
            fi
        fi
    fi
    if [[ -f "/var/cache/vpn-script/$asset" ]] &&
        printf '%s  %s\n' "$expected" "/var/cache/vpn-script/$asset" | sha256sum --check --status; then
        cp -- "/var/cache/vpn-script/$asset" "$DEPLOYMENT/$asset"
    else
        curl -fL --retry 2 --max-time 180 --proto '=https' --proto-redir '=https' \
            "https://github.com/MHSanaei/3x-ui/releases/download/$PANEL_VERSION/$asset" \
            -o "$DEPLOYMENT/$asset"
    fi
    printf '%s  %s\n' "$expected" "$DEPLOYMENT/$asset" | sha256sum --check --status
    tar -xzf "$DEPLOYMENT/$asset" -C "$DEPLOYMENT"
    xray_actual=$("$DEPLOYMENT/x-ui/bin/xray-linux-$(arch)" version)
    [[ "$xray_actual" == "Xray ${XRAY_VERSION#v} "* ]] || { deployment_error "Unexpected Xray version"; return 1; }
    panel_needs_install=y
}

install_panel() {
    if [[ "$panel_needs_install" != y ]]; then return 0; fi
    install -d -m 755 /usr/local/x-ui
    cp -a -- "$DEPLOYMENT/x-ui/." /usr/local/x-ui/
    install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
    systemctl daemon-reload
}

###############################Install Required Packages & Utilities####################################
setup_nginx_mainline_repo() {
    install -d -m 755 /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d
    curl -fsSL https://nginx.org/keys/nginx_signing.key -o "$DEPLOYMENT/nginx.asc"
    gpg --batch --show-keys --with-colons "$DEPLOYMENT/nginx.asc" > "$DEPLOYMENT/nginx.keys"
    # A fetched key can contain unrelated public keys. Export only the approved key.
    local fingerprint
    install -d -m 700 "$DEPLOYMENT/gnupg"
    gpg --batch --homedir "$DEPLOYMENT/gnupg" --import "$DEPLOYMENT/nginx.asc" >/dev/null 2>&1
    : > /usr/share/keyrings/nginx-archive-keyring.gpg
    for fingerprint in $NGINX_SIGNING_FINGERPRINTS; do
        [[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]]
        grep -Fq ":${fingerprint}:" "$DEPLOYMENT/nginx.keys"
        gpg --batch --homedir "$DEPLOYMENT/gnupg" --export "$fingerprint" >> /usr/share/keyrings/nginx-archive-keyring.gpg
    done
    chmod 644 /usr/share/keyrings/nginx-archive-keyring.gpg
    printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/%s %s nginx\n' \
        "$os_id" "$distro_codename" > /etc/apt/sources.list.d/nginx-mainline.list
    cat > /etc/apt/preferences.d/99-nginx-mainline << 'PREF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
PREF
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    # Keep package maintainer scripts from publishing services before configuration is ready.
    local policy temporary
    policy=/usr/sbin/policy-rc.d
    if [[ -d "$policy" && ! -L "$policy" ]]; then
        deployment_error "The service-start policy is not a file"
        return 1
    fi
    if [[ -e "$policy" || -L "$policy" ]]; then cp -a -- "$policy" "$DEPLOYMENT/policy.original"; fi
    temporary=$(mktemp /usr/sbin/.vpn-script-policy.XXXXXXXX)
    printf '#!/bin/sh\nexit 101\n' > "$temporary"
    chmod 755 "$temporary"
    mv -fT -- "$temporary" "$policy"
    "$Pak" -y update
    "$Pak" -y --no-remove install curl gnupg ca-certificates
    setup_nginx_mainline_repo
    "$Pak" -y update
    local old_nginx
    old_nginx=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || :)
    if [[ -n "$old_nginx" && "$old_nginx" != "$NGINX_VERSION-1~$distro_codename" ]]; then
        (cd "$DEPLOYMENT" && "$Pak" download "nginx=$old_nginx")
    fi
    "$Pak" -y --no-remove install "nginx=$NGINX_VERSION-1~$distro_codename" \
        netcat-openbsd sqlite3 python3 python3-pip jq ufw openssl dnsutils certbot fail2ban python3-systemd
    rm -f -- "$policy"
    if [[ -e "$DEPLOYMENT/policy.original" || -L "$DEPLOYMENT/policy.original" ]]; then
        mv -T -- "$DEPLOYMENT/policy.original" "$policy"
    fi
}

validate_domain() {
    local name="$1" label
    local -a labels
    [[ "${#name}" -le 253 && "$name" == *.* && "$name" != *. && "$name" != *..* ]] || return 1
    IFS=. read -ra labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ "${#label}" -le 63 && "$label" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]] || return 1
    done
}

for required in python3 ip ss flock; do
    command -v "$required" >/dev/null || { deployment_error "Missing preflight command: $required"; exit 1; }
done
if [[ -f "$XUIDB" ]]; then
    command -v sqlite3 >/dev/null || { deployment_error "sqlite3 is required for an existing database"; exit 1; }
fi
for protected_directory in "$XUIDB" /etc/x-ui /usr/local/x-ui /usr/local/x-ui/bin \
    /usr/local/lib/vpn-script /usr/local/lib/vpn-script/probe-packages /etc/nginx; do
    if [[ -L "$protected_directory" ]]; then
        deployment_error "Managed installation path is a symbolic link: $protected_directory"
        exit 1
    fi
done
python3 - <<'PYTHON'
import os
from pathlib import Path

memory = next(int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:'))
cgroup_limit = Path('/sys/fs/cgroup/memory.max')
if cgroup_limit.exists() and cgroup_limit.read_text().strip().isdigit():
    memory = min(memory, int(cgroup_limit.read_text().strip()))
if memory < 512 * 1024**2:
    raise SystemExit('Preflight: at least 512 MiB of RAM is required')
size = 0
for root in (Path('/usr/local/x-ui'), Path('/etc/x-ui')):
    if root.exists():
        size += sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and not p.is_symlink())
required = max(512 * 1024**2, size * 2 + 256 * 1024**2)
for directory in ('/var/lib', '/usr/local'):
    fs = os.statvfs(directory)
    if fs.f_bavail * fs.f_frsize < required:
        raise SystemExit('Preflight: insufficient space for verified artifacts and recovery snapshots')
PYTHON
. /etc/os-release
os_id=$ID
distro_codename=${VERSION_CODENAME:-}
case "$os_id:$VERSION_ID:$distro_codename" in
    ubuntu:22.04:jammy|ubuntu:24.04:noble|debian:12:bookworm) ;;
    *) deployment_error "Unsupported operating system"; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) deployment_error "Unsupported CPU architecture"; exit 1 ;;
esac
dpkg --compare-versions "$NGINX_VERSION" ge "$NGINX_FUNCTIONAL_MIN" || {
    deployment_error "Pinned Nginx does not meet the HTTP/2 minimum"; exit 1;
}
dpkg --compare-versions "$NGINX_VERSION" ge "$NGINX_SECURITY_MIN" || {
    deployment_error "Pinned Nginx does not meet the security minimum"; exit 1;
}

if [[ "$AUTODOMAIN" == y ]]; then
    if [[ -z "$PUBLIC_IP4" ]]; then
        PUBLIC_IP4=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
    fi
    domain="${PUBLIC_IP4}.cdn-one.org"
elif [[ -z "$domain" && -t 0 ]]; then
    read -rp 'Enter available subdomain: ' domain
fi
domain=${domain,,}
LC_ALL=C validate_domain "$domain" || { deployment_error "Expected a valid fully qualified domain name"; exit 1; }
if [[ -z "$SSH_PORT" ]]; then
    saved_ssh_port=""
    if [[ -f "$STATE_DIR/config.json" ]]; then
        saved_ssh_port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ssh_port", ""))' "$STATE_DIR/config.json" 2>/dev/null || true)
    fi
    current_active_ssh=$(ssh_migration_current_port 2>/dev/null || true)

    if [[ -t 0 && "$AUTODOMAIN" != y ]]; then
        if [[ -n "$saved_ssh_port" && "$saved_ssh_port" =~ ^[1-9][0-9]{1,4}$ ]]; then
            default_ssh_port="$saved_ssh_port"
        elif [[ -n "$current_active_ssh" && "$current_active_ssh" != 22 ]]; then
            default_ssh_port="$current_active_ssh"
        else
            default_ssh_port=${current_active_ssh:-22}
        fi
        read -rp "Requested SSH port [$default_ssh_port]: " answer_ssh_port
        SSH_PORT=${answer_ssh_port:-$default_ssh_port}
        if [[ -n "$current_active_ssh" ]]; then
            if [[ "$SSH_PORT" != "$current_active_ssh" ]]; then
                SSH_PORT_EXPLICIT=y
            fi
        elif [[ "$SSH_PORT" != "${saved_ssh_port:-22}" ]]; then
            SSH_PORT_EXPLICIT=y
        fi
    else
        SSH_PORT="${saved_ssh_port:-${current_active_ssh:-22}}"
    fi
fi
if ! [[ "$SSH_PORT" =~ ^[1-9][0-9]{1,4}$ ]] || (( SSH_PORT < 22 || SSH_PORT > 65535 )); then
    deployment_error "Invalid SSH port"
    exit 1
fi
saved_mask=""
previous_xhttp_config=""
previous_xhttp_download=none
if [[ -f "$STATE_DIR/config.json" ]]; then
    saved_settings=$(python3 - "$STATE_DIR/config.json" <<'PYTHON'
import json
import sys
with open(sys.argv[1]) as source:
    config = json.load(source)
for key, default in (("mask_upstream", ""), ("xhttp_config_path", ""), ("xhttp_download_path", "none")):
    value = config.get(key, default)
    if not isinstance(value, str) or any(ord(char) < 32 for char in value):
        sys.exit("Invalid saved deployment settings")
    print(value)
PYTHON
    )
    mapfile -t settings <<< "$saved_settings"
    saved_mask=${settings[0]}
    previous_xhttp_config=${settings[1]}
    previous_xhttp_download=${settings[2]}
fi
MASK_UPSTREAM=${MASK_UPSTREAM:-$saved_mask}
if [[ -z "$MASK_UPSTREAM" && -n "$MASK_PORT" ]]; then MASK_UPSTREAM=http://127.0.0.1; fi
if [[ -z "$MASK_UPSTREAM" ]]; then
    deployment_error "Set -mask_port or -mask_upstream for the HTTP(S) cover service"
    exit 1
fi
XHTTP_CONFIG_PATH=${XHTTP_CONFIG_PATH:-${previous_xhttp_config:-$STATE_DIR/xhttp.json}}
XHTTP_DOWNLOAD_PATH=${XHTTP_DOWNLOAD_PATH:-$previous_xhttp_download}
check_xhttp_config_path "$XHTTP_CONFIG_PATH"
if [[ -n "$previous_xhttp_config" && "$previous_xhttp_config" != "$XHTTP_CONFIG_PATH" ]]; then
    check_xhttp_config_path "$previous_xhttp_config"
fi
if [[ "$XHTTP_DOWNLOAD_PATH" != none &&
    ! "$XHTTP_DOWNLOAD_PATH" =~ ^(/[A-Za-z0-9_-]+)*/[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?$ ]]; then
    deployment_error "Invalid -xhttp_download_path; use an absolute URL path such as /downloads/xhttp.json"
    exit 1
fi
dns_preflight_check() {
    python3 - "$domain" "$MASK_UPSTREAM" "$MASK_PORT" "$SSH_PORT" "$ANTILOOP_PORT" "$PUBLIC_IP4" "$PUBLIC_IP6" <<'PYTHON'
import ipaddress
import json
import re
import socket
import subprocess
import sys
from urllib.parse import urlsplit

domain, upstream, override, ssh, antiloop, ipv4, ipv6 = sys.argv[1:]
try:
    local = {
        ipaddress.ip_address(addr["local"].split("%", 1)[0])
        for iface in json.loads(subprocess.check_output(["ip", "-j", "addr", "show"]))
        for addr in iface.get("addr_info", [])
        if "local" in addr
    }
    for version, value in ((4, ipv4), (6, ipv6)):
        if value:
            addr = ipaddress.ip_address(value)
            if addr.version != version or addr.is_unspecified or addr.is_loopback:
                raise ValueError("invalid public IP override")
            local.add(addr)
    resolved = {ipaddress.ip_address(info[4][0]) for info in socket.getaddrinfo(domain, None)}
    if not any(addr.version == 4 for addr in resolved) or not resolved <= local:
        raise ValueError("DNS A/AAAA records must point to this node")
    if not re.fullmatch(r"https?://(?:[a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\])(?::[0-9]{1,5})?", upstream):
        raise ValueError("mask upstream must be an HTTP(S) origin without credentials")
    parsed = urlsplit(upstream)
    port = parsed.port
    if override:
        if not re.fullmatch(r"[1-9][0-9]{0,4}", override):
            raise ValueError("invalid -mask_port")
        port = int(override)
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("mask upstream port must be between 1 and 65535")
    hostname = parsed.hostname
    addresses = {ipaddress.ip_address(info[4][0].split("%", 1)[0]) for info in socket.getaddrinfo(hostname, port)}
    addresses = {getattr(addr, "ipv4_mapped", None) or addr for addr in addresses}
    is_local = bool(addresses & local) or any(addr.is_loopback or addr.is_unspecified for addr in addresses)
    effective_port = port or (443 if parsed.scheme == "https" else 80)
    if is_local and effective_port in {80, 443, int(ssh), int(antiloop)}:
        raise ValueError("mask upstream would route back to this VPN")
    host = f"[{hostname}]" if ":" in hostname else hostname
    print(f"{parsed.scheme}://{host}" + (f":{port}" if port is not None else ""))
    print(effective_port if is_local else "")
except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    sys.exit(f"Preflight: {error}")
PYTHON
}
mask_settings=$(dns_preflight_check)
MASK_UPSTREAM=${mask_settings%%$'\n'*}
mask_local_port=""
if [[ "$mask_settings" == *$'\n'* ]]; then mask_local_port=${mask_settings##*$'\n'}; fi
if [[ -z "$REALITY_TARGET" && -f "$STATE_DIR/config.json" ]]; then
    REALITY_TARGET=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reality_target", "www.microsoft.com"))' "$STATE_DIR/config.json")
fi
REALITY_TARGET=${REALITY_TARGET:-www.microsoft.com}
while true; do
    if [[ "$REALITY_TARGET_EXPLICIT" == n && -t 0 ]]; then
        read -rp "REALITY Classic site [$REALITY_TARGET]: " reality_answer
        REALITY_TARGET=${reality_answer:-$REALITY_TARGET}
    fi
    REALITY_TARGET=${REALITY_TARGET,,}
    if [[ "$DRY_RUN" == y ]]; then
        python3 "$LIB_DIR/reality.py" target "$REALITY_TARGET" "$domain" --syntax-only
        printf 'SKIP Classic target connectivity in dry-run; mandatory before deployment\n'
        break
    fi
    if python3 "$LIB_DIR/reality.py" target "$REALITY_TARGET" "$domain" "$PUBLIC_IP4" "$PUBLIC_IP6"; then break; fi
    if [[ "$REALITY_TARGET_EXPLICIT" == y || ! -t 0 ]]; then exit 1; fi
    msg_err 'Site failed the public-address, certificate, TLS 1.3 or HTTP/2 check; choose another site.'
done
check_listener 80 t available nginx || { deployment_error "Foreign TCP listener on port 80"; exit 1; }
check_listener 443 t available nginx || { deployment_error "Foreign TCP listener on port 443"; exit 1; }
check_listener "$ANTILOOP_PORT" t available nginx || { deployment_error "Foreign TCP listener on fallback port"; exit 1; }
check_listener 443 u available xray || { deployment_error "Foreign UDP listener on port 443"; exit 1; }
ssh_proc="sshd"
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    ssh_proc="sshd|systemd"
fi
check_listener "$SSH_PORT" t available "$ssh_proc" || { deployment_error "Requested SSH port belongs to another service"; exit 1; }

managed_files=(
    /etc/nginx/stream-enabled/stream.conf
    /etc/nginx/conf.d/probe_security.conf
    /etc/nginx/conf.d/00-vpn-script-http.conf
    /etc/nginx/sites-available/80.conf
    "/etc/nginx/sites-available/$domain"
    /etc/nginx/sites-enabled/80.conf
    "/etc/nginx/sites-enabled/$domain"
    /etc/nginx/snippets/includes.conf
    /etc/nginx/snippets/vpn-script-panel.conf
    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    /etc/fail2ban/jail.d/99-sshd.local
    /etc/systemd/system/nginx.service.d/vpn-script.conf
    /etc/systemd/system/x-ui.service.d/vpn-script.conf
    /etc/systemd/system/x-ui.service
    /usr/local/sbin/vpn-script
    /usr/local/lib/vpn-script/deployment.sh
    /usr/local/lib/vpn-script/download.sh
    /usr/local/lib/vpn-script/versions.conf
    /usr/local/lib/vpn-script/ssh.sh
    /usr/local/lib/vpn-script/xray_config.py
    /usr/local/lib/vpn-script/reality.py
    /usr/local/lib/vpn-script/release.sh
    /usr/local/lib/vpn-script/certificate_probe.py
    /usr/local/lib/vpn-script/probe-requirements.txt
    "$XHTTP_CONFIG_PATH"
)
if [[ "$XHTTP_DOWNLOAD_PATH" != none ]]; then
    managed_files+=("$XHTTP_WEB_CONFIG" "$XHTTP_WEB_AUTH")
fi
for apt_file in /usr/share/keyrings/nginx-archive-keyring.gpg +    /etc/apt/sources.list.d/nginx-mainline.list /etc/apt/preferences.d/99-nginx-mainline; do
    if [[ "$INSTALL" == y ]] ||
        [[ -f "$STATE_DIR/owned" && -n "$(awk -v path="$apt_file" '$2 == path {print $1}' "$STATE_DIR/owned")" ]]; then
        managed_files+=("$apt_file")
    fi
done
if [[ -f "$STATE_DIR/config.json" ]] && ! python3 - "$STATE_DIR/config.json" "$domain" <<'PYTHON'
import json
import sys
with open(sys.argv[1]) as config:
    sys.exit(json.load(config)["domain"] != sys.argv[2])
PYTHON
then
    deployment_error "Changing the managed domain requires uninstalling the previous configuration"
    exit 1
fi
retired_files=()
if [[ -n "$previous_xhttp_config" && "$previous_xhttp_config" != "$XHTTP_CONFIG_PATH" ]]; then
    retired_files+=("$previous_xhttp_config")
fi
if [[ "$previous_xhttp_download" != none && "$XHTTP_DOWNLOAD_PATH" == none ]]; then
    retired_files+=("$XHTTP_WEB_CONFIG" "$XHTTP_WEB_AUTH")
fi
deployment_preflight_ownership "${managed_files[@]}" "${retired_files[@]}"
if [[ -z "$DNS_PROVIDER" ]]; then
    DNS_PROVIDER=none
    if [[ -f "$STATE_DIR/config.json" ]]; then
        DNS_PROVIDER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dns_provider"])' "$STATE_DIR/config.json")
    elif [[ "$ADOPT_LEGACY" == y && -f "$XUIDB" ]]; then
        if sqlite3 -batch -bail -readonly "$XUIDB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" | grep -F 'https+local://eu.geohide.ru/dns-query' > /dev/null; then
            DNS_PROVIDER=geohide
        fi
    fi
fi
if [[ -f "$XUIDB" ]]; then
    preview_adopt=$ADOPT_LEGACY
    if [[ "$DRY_RUN" == y ]]; then preview_adopt=y; fi
    python3 "$LIB_DIR/xray_config.py" preflight "$XUIDB" "$BLOCK_RU" "$DNS_PROVIDER" "$preview_adopt"
fi
check_installed_panel_version
if [[ "$DRY_RUN" == y ]]; then
    printf 'Preflight passed for %s\n' "$domain"
    exit 0
fi
deployment_begin "${managed_files[@]}" "${retired_files[@]}" /etc/nginx/nginx.conf /usr/local/x-ui /usr/bin/x-ui \
    /usr/local/lib/vpn-script/probe-packages \
    /etc/ufw/user.rules /etc/ufw/user6.rules /usr/sbin/policy-rc.d \
    "$STATE_DIR/owned" "$STATE_DIR/config.json" "$STATE_DIR/credentials"
trap 'deployment_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$INSTALL" == y ]]; then
    install_dependencies
fi
install_probe_dependencies
for required in sqlite3 nginx openssl certbot ufw curl; do
    command -v "$required" >/dev/null || { deployment_error "Missing dependency: $required"; exit 1; }
done
if ! curl -q --noproxy '*' -sS --max-time 5 -o /dev/null "$MASK_UPSTREAM/"; then
    deployment_error "Cannot reach the HTTP(S) cover service at $MASK_UPSTREAM"
    exit 1
fi
for unit in nginx x-ui; do
    install -d -m 755 "/etc/systemd/system/$unit.service.d"
    printf '[Service]\nLimitNOFILE=65535\n' > "/etc/systemd/system/$unit.service.d/vpn-script.conf"
done
systemctl daemon-reload
nginx_actual=$(nginx -v 2>&1)
[[ "$nginx_actual" == "nginx version: nginx/$NGINX_VERSION" ]] || { deployment_error "Unexpected Nginx version"; exit 1; }
prepare_panel_release
install_geodata /usr/local/x-ui/bin prepare
allow_web_ports
if systemctl is-active --quiet x-ui.service; then systemctl stop x-ui.service; fi

##################################generate ports and paths#############################################################
declare -A USED_PORTS=()
USED_PORTS["${ANTILOOP_PORT}"]=1
USED_PORTS["$SSH_PORT"]=1
if [[ -n "$mask_local_port" ]]; then USED_PORTS["$mask_local_port"]=1; fi

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

gen_header_name() {
    local prefixes=("X-Track-Session" "X-Download-Id" "X-Queue-Token" "X-Chunk-Seq" "X-Library-Sync" "X-Stream-Ctx")
    echo "${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
}

make_port() {
    local port rows
    while true; do
        port=$(get_port)
        [[ -z ${USED_PORTS[$port]+x} ]] || continue
        rows=$(ss -H -ltn "sport = :$port") || return 1
        if [[ -z "$rows" ]]; then
            USED_PORTS["$port"]=1
            printf -v "$1" '%s' "$port"
            return 0
        fi
    done
}

# Reuse existing ports and paths if x-ui.db already exists
panel_port=""
panel_path=""
xhttp_port=""
xhttp_path=""
x_padding_key="" ; x_padding_header="" ; session_id_key="" ; seq_key=""
existing_xhttp=n
nginx_guard_enabled=y

if [[ -f "$XUIDB" ]]; then
    _db_val() { sqlite3 -batch -bail -readonly "$XUIDB" "SELECT DISTINCT value FROM settings WHERE key='$1';"; }
    xhttp_filter="protocol='vless' AND enable=1 AND json_extract(stream_settings,'$.network')='xhttp' AND coalesce(json_extract(stream_settings,'$.security'),'none')='none'"
    xhttp_count=$(sqlite3 -batch -bail -readonly "$XUIDB" "SELECT count(*) FROM inbounds WHERE $xhttp_filter;")
    hy2_count=$(sqlite3 -batch -bail -readonly "$XUIDB" "SELECT count(*) FROM inbounds WHERE protocol IN ('hysteria','hysteria2') AND port=443 AND enable=1 AND json_extract(settings,'$.version')=2;")
    inbound_count=$(sqlite3 -batch -bail -readonly "$XUIDB" 'SELECT count(*) FROM inbounds;')
    if (( inbound_count > 0 )) && (( xhttp_count != 1 || hy2_count != 1 )); then
        deployment_error "Expected one enabled xHTTP inbound and one enabled Hysteria 2 inbound on UDP/443"
        exit 1
    fi
    panel_port=$(_db_val webPort)
    panel_path=$(_db_val webBasePath)
    panel_path=${panel_path#/}
    panel_path=${panel_path%/}
    if (( xhttp_count == 1 )); then
        existing_xhttp=y
        padding_mode=$(sqlite3 -batch -bail -readonly "$XUIDB" "SELECT coalesce(json_extract(stream_settings,'$.xhttpSettings.xPaddingObfsMode'),0) || ':' || coalesce(json_extract(stream_settings,'$.xhttpSettings.xPaddingPlacement'),'') FROM inbounds WHERE $xhttp_filter;")
        if [[ "$padding_mode" != 1:header ]]; then nginx_guard_enabled=n; fi
        xhttp_port=$(sqlite3 -batch -bail -readonly "$XUIDB" "SELECT port FROM inbounds WHERE $xhttp_filter;")
        xhttp_settings=$(sqlite3 -batch -bail -readonly "$XUIDB" "
            SELECT coalesce(json_extract(stream_settings,'$.xhttpSettings.path'),'') || char(10) ||
                   coalesce(json_extract(stream_settings,'$.xhttpSettings.xPaddingKey'),'') || char(10) ||
                   coalesce(json_extract(stream_settings,'$.xhttpSettings.xPaddingHeader'),'') || char(10) ||
                   coalesce(json_extract(stream_settings,'$.xhttpSettings.sessionIDKey'),'') || char(10) ||
                   coalesce(json_extract(stream_settings,'$.xhttpSettings.seqKey'),'') || char(10) || 'end'
            FROM inbounds WHERE $xhttp_filter;")
        mapfile -t xhttp_meta <<< "$xhttp_settings"
        (( ${#xhttp_meta[@]} == 6 )) || { deployment_error "Could not read existing xHTTP settings"; exit 1; }
        xhttp_path=${xhttp_meta[0]}
        x_padding_key=${xhttp_meta[1]}
        x_padding_header=${xhttp_meta[2]}
        session_id_key=${xhttp_meta[3]}
        seq_key=${xhttp_meta[4]}
    fi
fi

[[ -z "$panel_port" ]] && make_port panel_port
[[ -z "$panel_path" ]] && panel_path=$(gen_random_string 24)
if [[ -z "$xhttp_port" ]]; then
    USED_PORTS["$panel_port"]=1
    make_port xhttp_port
fi
[[ -z "$xhttp_path" ]] && xhttp_path="/api/library/stream/$(gen_random_string 8)/chunks/"
if ! [[ "$panel_port" =~ ^[1-9][0-9]{3,4}$ && "$xhttp_port" =~ ^[1-9][0-9]{3,4}$ &&
    "$panel_path" =~ ^[A-Za-z0-9_-]+$ && "$xhttp_path" =~ ^(/[A-Za-z0-9_-]+)+/$ ]]; then
    deployment_error "Existing panel or xHTTP settings cannot be safely rendered"
    exit 1
fi
if (( panel_port > 65535 || xhttp_port > 65535 || panel_port == xhttp_port ||
    panel_port == ANTILOOP_PORT || xhttp_port == ANTILOOP_PORT ||
    panel_port == SSH_PORT || xhttp_port == SSH_PORT ||
    panel_port == ${mask_local_port:-0} || xhttp_port == ${mask_local_port:-0} )); then
    deployment_error "Existing panel or xHTTP port conflicts"
    exit 1
fi
if [[ "$XHTTP_DOWNLOAD_PATH" == "/$panel_path" || "$XHTTP_DOWNLOAD_PATH" == "/$panel_path/"* ||
    "$XHTTP_DOWNLOAD_PATH" == "${xhttp_path%/}" || "$XHTTP_DOWNLOAD_PATH" == "$xhttp_path"* ]]; then
    deployment_error "xHTTP download path overlaps the panel or xHTTP transport"
    exit 1
fi
for header in "$x_padding_key" "$x_padding_header" "$session_id_key" "$seq_key"; do
    [[ -z "$header" || "$header" =~ ^[A-Za-z0-9-]+$ ]] || { deployment_error "Unsafe xHTTP header"; exit 1; }
done
check_listener "$panel_port" t available x-ui
check_listener "$xhttp_port" t available xray

generate_unique_headers() {
    local -a used=()
    local val
    for varname in x_padding_key x_padding_header session_id_key seq_key; do
        local cur="${!varname}"
        if [[ -z "$cur" || "$cur" == "null" ]]; then
            while true; do
                val=$(gen_header_name)
                # shellcheck disable=SC2076
                [[ ! " ${used[*]} " =~ " ${val} " ]] && break
            done
            printf -v "$varname" '%s' "$val"
        fi
        used+=("${!varname}")
    done
}
if [[ "$existing_xhttp" == n ]]; then generate_unique_headers; fi
python3 "$LIB_DIR/reality.py" ports "$XUIDB" "$panel_port" "$xhttp_port" "$ANTILOOP_PORT" "$SSH_PORT" "${mask_local_port:-0}" > "$DEPLOYMENT/reality-ports.json"
readarray -t reality_ports < <(python3 - "$DEPLOYMENT/reality-ports.json" <<'PY'
import json, sys
ports = json.load(open(sys.argv[1]))
for role in ('self_raw', 'self_xhttp', 'classic_raw', 'classic_xhttp'):
    print(ports[role])
PY
)
(( ${#reality_ports[@]} == 4 )) || { deployment_error 'Invalid REALITY port allocation'; exit 1; }
for reality_port in "${reality_ports[@]}"; do
    check_listener "$reality_port" t available xray
done
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 32)

##################################Managed ACME HTTP configuration########################################
ACME_WEBROOT=/var/www/vpn-script-acme
install -d -m 755 "$ACME_WEBROOT" /etc/nginx/stream-enabled /etc/nginx/sites-available \
    /etc/nginx/sites-enabled /etc/nginx/snippets /etc/nginx/conf.d
[[ -d /dev/shm ]]
if ! grep -Eq "^[[:space:]]*include[[:space:]]+[\"']?/etc/nginx/sites-enabled/\*[\"']?[[:space:]]*;" /etc/nginx/nginx.conf; then
    sed -i '/^[[:space:]]*http[[:space:]]*{/a\# BEGIN vpn-script sites\n    include /etc/nginx/sites-enabled/*;\n# END vpn-script sites' /etc/nginx/nginx.conf
fi
cat > /etc/nginx/sites-available/80.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }
    location / {
        return 301 https://${domain}\$request_uri;
    }
}
EOF
rm -f "/etc/nginx/sites-enabled/$domain" /etc/nginx/sites-enabled/80.conf
nginx_buckets=$(nginx -T | awk '
    /^# configuration file / { managed=($0 ~ /\/etc\/nginx\/conf\.d\/00-vpn-script-http\.conf:$/) }
    !managed && /^[[:space:]]*(server_names_hash_bucket_size|map_hash_bucket_size)[[:space:]]/ {
        print $1
    }')
rm -f /etc/nginx/conf.d/00-vpn-script-http.conf
for directive in server_names_hash_bucket_size map_hash_bucket_size; do
    if ! grep -Fxq "$directive" <<< "$nginx_buckets"; then
        printf '%s 512;\n' "$directive" >> /etc/nginx/conf.d/00-vpn-script-http.conf
    fi
done
ln -sfn /etc/nginx/sites-available/80.conf /etc/nginx/sites-enabled/80.conf
nginx -t
systemctl reload-or-restart nginx.service

certificate_ok() {
    local dir="$1" cert_pub key_pub
    [[ -r "$dir/fullchain.pem" && -r "$dir/privkey.pem" && -r "$dir/chain.pem" ]] || return 1
    openssl x509 -checkend 0 -noout -in "$dir/fullchain.pem" >/dev/null || return 1
    openssl verify -verify_hostname "$domain" -untrusted "$dir/chain.pem" "$dir/fullchain.pem" >/dev/null || return 1
    cert_pub=$(openssl x509 -pubkey -noout -in "$dir/fullchain.pem") || return 1
    key_pub=$(openssl pkey -pubout -in "$dir/privkey.pem") || return 1
    [[ "$cert_pub" == "$key_pub" ]]
}

CERT_DIR="/etc/letsencrypt/live/$domain"
if [[ ! -e "$CERT_DIR" ]]; then
    shopt -s nullglob
    alternate=(/etc/letsencrypt/live/"$domain"-[0-9]*)
    shopt -u nullglob
    if (( ${#alternate[@]} == 1 )); then
        CERT_DIR=${alternate[0]}
    elif (( ${#alternate[@]} > 1 )); then
        deployment_error "Multiple matching certificate lineages; select the desired lineage before installation"
        exit 1
    else
        certbot certonly --webroot -w "$ACME_WEBROOT" --non-interactive --agree-tos \
            --register-unsafely-without-email --cert-name "$domain" -d "$domain"
    fi
fi
certificate_ok "$CERT_DIR" || { deployment_error "Existing certificate or key is not valid for $domain"; exit 1; }

install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << EOF
#!/bin/bash
set -euo pipefail
[[ "\${RENEWED_LINEAGE:-}" == "$CERT_DIR" ]] || exit 0
nginx -t
systemctl reload nginx.service
systemctl restart x-ui.service
for attempt in {1..5}; do
    /usr/bin/python3 /usr/local/lib/vpn-script/certificate_probe.py "$domain" "$CERT_DIR/fullchain.pem" && exit 0
    sleep 1
done
printf 'Certificate fingerprint mismatch after renewal\\n' >&2
exit 1
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
# Why: Public L4 stream router listens on both IPv4 and IPv6 (if available).
# Internal upstream uses RAM unix socket (/dev/shm/nginx-http.sock), avoiding loopback TCP overhead.
IPV6_STREAM=""
if [[ -f /proc/net/if_inet6 ]]; then
    IPV6_STREAM="listen         [::]:443;"
fi

cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${domain}           reality_failover;
    ${REALITY_TARGET}   reality_classic;
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
    server 127.0.0.1:${reality_ports[0]} fail_timeout=1s;
    server unix:/dev/shm/nginx-http.sock backup;
}

upstream reality_classic {
    server 127.0.0.1:${reality_ports[2]};
}

server {
    proxy_protocol on;
    listen          443;
    ${IPV6_STREAM}
    proxy_pass      \$sni_name;
    ssl_preread     on;
}

EOF

if ! grep -Fq '/etc/nginx/stream-enabled/*.conf' /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf <<'NGINX'
# BEGIN vpn-script stream
stream { include /etc/nginx/stream-enabled/*.conf; }
# END vpn-script stream
NGINX
fi

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

nginx_pad_header_slug=$(echo "${x_padding_header}" | tr '[:upper:]-' '[:lower:]_')
nginx_header_guard=""
if [[ "$nginx_guard_enabled" == y && -n "$nginx_pad_header_slug" ]]; then
    printf -v nginx_header_guard '    if ($http_%s = "") { return 418; }' "$nginx_pad_header_slug"
fi
mask_authority=${MASK_UPSTREAM#*://}
mask_hostname=$(python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname)' "$MASK_UPSTREAM")

cat > "/etc/nginx/sites-available/${domain}" << EOF
# Why: Reject direct IP scans and TLS handshakes with missing/non-matching SNI,
# preventing active probing and certificate disclosure on the unix domain socket.
server {
    listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
    ssl_reject_handshake on;
}

server {
# =====================================================================
# VLESS XHTTP STREAM-ONE (Native HTTP/2 Proxying with Header Guard)
# =====================================================================
location ${xhttp_path} {
    # Why: Header Guard intercepts unauthorized scanners or probing bots
    # lacking the secret xPadding header, transparently routing them to the
    # mask site (HTTP 200) instead of exposing Xray RST_STREAM or GOAWAY.
    error_page 418 = @mask_fallback;
${nginx_header_guard}
    if (\$request_method !~ ^(GET|POST)\$) {
        return 418;
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
    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Why: Enforce raw binary stream and prevent SSE/chunking distortions
    proxy_hide_header Content-Type;
    add_header Content-Type application/octet-stream always;

    # Zero-log policy for active proxy traffic
    access_log off;
    error_log /dev/null crit;
    gzip off;
}

# Why: Fallback handler for Header Guard to serve the legitimate mask application
location @mask_fallback {
    proxy_pass ${MASK_UPSTREAM};
    proxy_ssl_server_name on;
    proxy_ssl_name ${mask_hostname};
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_http_version 1.1;
    proxy_set_header Host ${mask_authority};
    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
}

	server_tokens off;
	server_name ${domain};
	listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
	http2 on;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
	ssl_prefer_server_ciphers off;
	ssl_certificate ${CERT_DIR}/fullchain.pem;
	ssl_certificate_key ${CERT_DIR}/privkey.pem;
	ssl_trusted_certificate ${CERT_DIR}/chain.pem;
	ssl_stapling on;
	ssl_stapling_verify on;
	resolver 1.1.1.1 8.8.8.8 127.0.0.53 valid=300s;
	resolver_timeout 5s;

	# Security & anti-fingerprint headers (Enterprise CDN profile)
	proxy_hide_header X-Powered-By;
	add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
	add_header X-Content-Type-Options "nosniff" always;
	add_header X-Frame-Options "SAMEORIGIN" always;
	add_header Referrer-Policy "strict-origin-when-cross-origin" always;
	add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

	error_log /dev/null crit;

	include /etc/nginx/snippets/vpn-script-panel.conf;
	include /etc/nginx/snippets/includes.conf;
}

# Why: Anti-loop fallback server for Xray REALITY / Steal-Oneself.
# Avoids infinite routing loops by serving mask site directly on an isolated internal port.
server {
	listen 127.0.0.1:${ANTILOOP_PORT} ssl;
	server_name ${domain};
	ssl_certificate ${CERT_DIR}/fullchain.pem;
	ssl_certificate_key ${CERT_DIR}/privkey.pem;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
	ssl_prefer_server_ciphers off;

	location / {
		proxy_pass ${MASK_UPSTREAM};
		proxy_ssl_server_name on;
		proxy_ssl_name ${mask_hostname};
		proxy_ssl_verify on;
		proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
		proxy_http_version 1.1;
		proxy_set_header Host ${mask_authority};
		proxy_set_header Connection "";
	}

	access_log off;
	error_log /dev/null crit;
}
EOF

cat > "/etc/nginx/snippets/includes.conf" << EOF
location / {
    proxy_pass ${MASK_UPSTREAM};
    proxy_ssl_server_name on;
    proxy_ssl_name ${mask_hostname};
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_http_version 1.1;
    proxy_set_header Host ${mask_authority};
    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Connection "";
}
EOF


# Existing workers are reloaded without the panel route before the backend starts.
: > /etc/nginx/snippets/vpn-script-panel.conf
ln -sfn "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"
nginx -t
systemctl reload-or-restart nginx.service

publish_panel_route() {
    cat > /etc/nginx/snippets/vpn-script-panel.conf << EOF

	location = /${panel_path} {
		return 301 /${panel_path}/;
	}

	location /${panel_path}/ {
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$proxy_protocol_addr;
		proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
		proxy_set_header X-Forwarded-Proto https;

		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
		proxy_pass http://127.0.0.1:${panel_port};
	}

EOF
    if [[ "$XHTTP_DOWNLOAD_PATH" != none ]]; then
        render_xhttp_download >> /etc/nginx/snippets/vpn-script-panel.conf
    fi
    nginx -t
    systemctl reload-or-restart nginx.service
}

########################################Update X-UI Port/Path for first INSTALL#########################
UPDATE_XUIDB(){
    [[ -f "$XUIDB" ]] || { deployment_error "Panel database is missing"; return 1; }
    chmod 700 /etc/x-ui
    chmod 600 "$XUIDB"
    XRAY_BIN=$(xray_bin)
    [[ -x "$XRAY_BIN" ]] || { deployment_error "Xray binary is missing"; return 1; }
    client_id=$("$XRAY_BIN" uuid)
    hy2_auth=$(gen_random_string 32)
    vlessenc_output=$("$XRAY_BIN" vlessenc)
    vless_decryption=$(printf '%s\n' "$vlessenc_output" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p' | tail -1)
    vless_encryption=$(printf '%s\n' "$vlessenc_output" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p' | tail -1)
    if [[ -z "$vless_encryption" || -z "$vless_decryption" ]]; then
        deployment_error "Cannot derive VLESS client and server encryption"
        return 1
    fi
    local status inbound_count
    status=$(/usr/local/x-ui/x-ui setting -show 2>"$DEPLOYMENT/panel-errors")
    if [[ -s "$DEPLOYMENT/panel-errors" ]] || ! grep -Eq '^hasDefaultCredential: (true|false)$' <<< "$status"; then
        deployment_error "Cannot verify existing panel credentials"
        return 1
    fi
    if [[ ! -f "$DEPLOYMENT/x-ui.db" ]] || grep -Fxq 'hasDefaultCredential: true' <<< "$status"; then
        /usr/local/x-ui/x-ui setting -username "$config_username" -password "$config_password" >"$DEPLOYMENT/panel-settings" 2>&1
        [[ "$(sqlite3 -batch -bail -readonly "$XUIDB" 'SELECT username FROM users ORDER BY id LIMIT 1;')" == "$config_username" ]] ||
            { deployment_error "Panel credential update did not take effect"; return 1; }
    else
        config_username=""
        config_password=""
    fi
    status=$(/usr/local/x-ui/x-ui setting -show 2>"$DEPLOYMENT/panel-errors")
    if [[ -s "$DEPLOYMENT/panel-errors" ]] || ! grep -Fxq 'hasDefaultCredential: false' <<< "$status"; then
        deployment_error "Panel still has standard credentials"
        return 1
    fi
    sqlite3 -batch -bail "$XUIDB" <<EOF
BEGIN IMMEDIATE;
DELETE FROM settings WHERE key IN ('subClashEnable','subEnableRouting','subEnable','webListen','webPort','webBasePath','webDomain','webCertFile','webKeyFile');
INSERT INTO settings (key,value) VALUES
    ('subClashEnable','false'), ('subEnableRouting','false'), ('subEnable','false'),
    ('webListen','127.0.0.1'), ('webPort','$panel_port'), ('webBasePath','/$panel_path/'),
    ('webDomain',''), ('webCertFile',''), ('webKeyFile','');
COMMIT;
EOF
    inbound_count=$(sqlite3 -batch -bail -readonly "$XUIDB" 'SELECT count(*) FROM inbounds;')
        if [[ "$inbound_count" -eq 0 ]]; then
            sqlite3 -batch -bail "$XUIDB" <<EOF
BEGIN IMMEDIATE;
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             'xhttp',
	     '1',
             '0',
	     '127.0.0.1',
             '${xhttp_port}',
	     'vless',
             '{
  "clients": [
    {
      "id": "${client_id}",
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
    "path": "${xhttp_path}",
    "host": "${domain}",
    "mode": "stream-one",
    "xPaddingBytes": "128-1120",
    "xPaddingObfsMode": true,
    "xPaddingKey": "${x_padding_key}",
    "xPaddingHeader": "${x_padding_header}",
    "xPaddingPlacement": "header",
    "xPaddingMethod": "tokenish",
    "sessionIDPlacement": "header",
    "sessionIDKey": "${session_id_key}",
    "sessionIDTable": "Base62",
    "sessionIDLength": "16-32",
    "seqPlacement": "header",
    "seqKey": "${seq_key}",
    "scMaxBufferedPosts": 30,
    "scStreamUpServerSecs": "20-80",
    "uplinkHTTPMethod": "POST",
    "xmux": {
      "maxConcurrency": 16,
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
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             'hysteria2',
	     '1',
             '0',
	     '0.0.0.0',
             '443',
	     'hysteria',
             '{
  "version": 2,
  "auth": "${hy2_auth}",
  "users": [
    {
      "auth": "${hy2_auth}",
      "email": "firstHy2",
      "enable": true
    }
  ],
  "clients": [
    {
      "id": "${client_id}",
      "auth": "${hy2_auth}",
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
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "tlsSettings": {
    "serverName": "${domain}",
    "alpn": [
      "h3"
    ],
    "minVersion": "1.3",
    "certificates": [
      {
        "certificateFile": "${CERT_DIR}/fullchain.pem",
        "keyFile": "${CERT_DIR}/privkey.pem"
      }
    ]
  },
  "hysteriaSettings": {
    "version": 2,
    "auth": "${hy2_auth}",
    "udpIdleTimeout": 60,
    "masquerade": {
      "type": "proxy",
      "url": "${MASK_UPSTREAM}",
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
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	     );
INSERT INTO clients (email,uuid,sub_id,enable,created_at,updated_at) VALUES
    ('firstX','$client_id','$(gen_random_string 24)',1,strftime('%s','now')*1000,strftime('%s','now')*1000);
INSERT INTO clients (email,uuid,auth,sub_id,enable,created_at,updated_at) VALUES
    ('firstHy2','$client_id','$hy2_auth','$(gen_random_string 24)',1,strftime('%s','now')*1000,strftime('%s','now')*1000);
INSERT INTO client_inbounds (client_id,inbound_id,created_at)
    SELECT c.id,i.id,strftime('%s','now')*1000 FROM clients c JOIN inbounds i
        ON (c.email='firstX' AND i.tag='in-${xhttp_port}-tcp') OR (c.email='firstHy2' AND i.tag='in-443-udp');
INSERT INTO client_traffics (inbound_id,enable,email,up,down,expiry_time,total,reset)
    SELECT ci.inbound_id,1,c.email,0,0,0,0,0 FROM client_inbounds ci JOIN clients c ON c.id=ci.client_id
    WHERE c.email IN ('firstX','firstHy2');
COMMIT;
EOF
    fi
    python3 - "$XUIDB" "$xhttp_port" "$xhttp_path" "$x_padding_key" "$x_padding_header" \
        "$session_id_key" "$seq_key" "$domain" "$CERT_DIR" "$MASK_UPSTREAM" <<'PYTHON'
import json
import sqlite3
import sys

db, port, path, pad_key, pad_header, session_key, seq_key, domain, cert_dir, mask = sys.argv[1:]
with sqlite3.connect(db) as conn:
    conn.execute("BEGIN IMMEDIATE")
    vless, = conn.execute(
        "SELECT id, stream_settings FROM inbounds WHERE protocol='vless' AND enable=1 "
        "AND port=? AND json_extract(stream_settings,'$.network')='xhttp'", (port,)
    ).fetchall()
    hysteria, = conn.execute(
        "SELECT id, stream_settings FROM inbounds WHERE protocol IN ('hysteria','hysteria2') "
        "AND enable=1 AND port=443 AND json_extract(settings,'$.version')=2"
    ).fetchall()
    vless_stream = json.loads(vless[1])
    xhttp = vless_stream["xhttpSettings"]
    xhttp["path"] = path
    for name, value in (
        ("xPaddingKey", pad_key), ("xPaddingHeader", pad_header),
        ("sessionIDKey", session_key), ("seqKey", seq_key)
    ):
        if value:
            xhttp[name] = value
        elif name in xhttp and not xhttp[name]:
            xhttp.pop(name, None)
    if isinstance(xhttp.get("xmux"), dict) and xhttp["xmux"].get("maxConcurrency"):
        xhttp["xmux"].pop("maxConnections", None)
    conn.execute("UPDATE inbounds SET listen='127.0.0.1', stream_settings=? WHERE id=?",
                 (json.dumps(vless_stream), vless[0]))
    stream = json.loads(hysteria[1])
    stream["externalProxy"] = [{"forceTls": "tls", "dest": domain, "port": 443, "remark": ""}]
    stream["tlsSettings"]["serverName"] = domain
    stream["tlsSettings"]["certificates"] = [
        {"certificateFile": f"{cert_dir}/fullchain.pem", "keyFile": f"{cert_dir}/privkey.pem"}
    ]
    stream["hysteriaSettings"]["masquerade"] = {"type": "proxy", "url": mask, "rewriteHost": True}
    conn.execute("UPDATE inbounds SET listen='0.0.0.0', stream_settings=? WHERE id=?",
                 (json.dumps(stream), hysteria[0]))
PYTHON
    chmod 600 "$XUIDB"
}

#######################################Install and check panel###############################
install_panel
install_geodata /usr/local/x-ui/bin
install -d -m 700 /etc/x-ui
deployment_prepare_database
/usr/local/x-ui/x-ui migrate >"$DEPLOYMENT/panel-migrate.log" 2>&1
UPDATE_XUIDB
python3 "$LIB_DIR/reality.py" apply "$XUIDB" "$domain" "$REALITY_TARGET" \
    "$DEPLOYMENT/reality-ports.json" "$(xray_bin)" "$xhttp_port" > "$DEPLOYMENT/inbounds.json"
python3 "$LIB_DIR/xray_config.py" routing "$XUIDB" "$xhttp_port" "$BLOCK_RU" "$DNS_PROVIDER" "$ADOPT_LEGACY"
python3 "$LIB_DIR/xray_config.py" validate "$XUIDB" "$xhttp_port" "$(xray_bin)" "$DEPLOYMENT/xray-check.json"
systemctl enable x-ui.service
systemctl start x-ui.service
ready=n
for ((attempt=0; attempt<20; attempt++)); do
    if check_listener "$panel_port" t loopback x-ui &&
        check_listener "$xhttp_port" t loopback xray &&
        check_listener 443 u present xray; then
        ready=y
        break
    fi
    sleep 1
done
if [[ "$ready" != y ]]; then
    deployment_error "Panel or VPN listener did not pass readiness checks"
    exit 1
fi
for reality_port in "${reality_ports[@]}"; do
    check_listener "$reality_port" t loopback xray || { deployment_error 'REALITY listener is not ready or isolated'; exit 1; }
done
if [[ "$(sqlite3 -batch -bail -readonly "$XUIDB" "SELECT value FROM settings WHERE key='subEnable';")" != false ]]; then
    deployment_error "Subscription server is enabled"
    exit 1
fi
download_password=""
install -m 600 /dev/null "$DEPLOYMENT/xhttp.json"
python3 "$LIB_DIR/xray_config.py" xhttp-config "$XUIDB" "$domain" "$xhttp_port" > "$DEPLOYMENT/xhttp.json"
"$(xray_bin)" run -test -c "$DEPLOYMENT/xhttp.json" >/dev/null 2>&1 ||
    { deployment_error "Xray rejected the exported xHTTP client configuration"; exit 1; }
publish_xhttp_file "$DEPLOYMENT/xhttp.json" "$XHTTP_CONFIG_PATH" root 0600
if [[ "$XHTTP_DOWNLOAD_PATH" != none ]]; then prepare_xhttp_download; fi
publish_panel_route
panel_ready=n
for attempt in {1..25}; do
    if curl --noproxy '*' -fsS --max-time 3 --resolve "$domain:443:127.0.0.1" "https://$domain/$panel_path/" -o /dev/null 2>/dev/null; then
        panel_ready=y
        break
    fi
    sleep 0.2
done
[[ "$panel_ready" == y ]] || { deployment_error "Public panel route failed its readiness check"; exit 1; }
if [[ "$XHTTP_DOWNLOAD_PATH" != none ]] && ! check_xhttp_download; then
    deployment_error "xHTTP download did not enforce authentication or serve the expected file"
    exit 1
fi
for retired_file in "${retired_files[@]}"; do rm -f -- "$retired_file"; done
systemctl enable nginx.service

setup_fail2ban() {
    msg_inf "Configuring Fail2ban SSH protection..."
    mkdir -p /etc/fail2ban/jail.d

    local ssh_jail_port=all
    install -d -m 755 /etc/fail2ban/jail.d
    local f2b_backend=systemd
    cat > /etc/fail2ban/jail.d/99-sshd.local << EOF
[sshd]
enabled   = true
port      = ${ssh_jail_port}
filter    = sshd
backend   = ${f2b_backend}
maxretry  = 3
findtime  = 600
bantime   = 86400
banaction = iptables-allports
EOF

    fail2ban-client -t
    systemctl enable fail2ban.service
    systemctl restart fail2ban.service
}
setup_fail2ban

install -d -m 755 /usr/local/lib/vpn-script
for helper in deployment.sh download.sh versions.conf ssh.sh xray_config.py reality.py release.sh certificate_probe.py probe-requirements.txt; do
    if [[ "$LIB_DIR/$helper" != "/usr/local/lib/vpn-script/$helper" ]]; then
        install -m 644 "$LIB_DIR/$helper" "/usr/local/lib/vpn-script/$helper"
    fi
done
/usr/bin/python3 "$LIB_DIR/certificate_probe.py" "$domain" "$CERT_DIR/fullchain.pem"
if [[ "$SCRIPT_DIR" != /usr/local/sbin ]]; then
    install -m 755 "${BASH_SOURCE[0]}" /usr/local/sbin/vpn-script
fi
links=$(python3 "$LIB_DIR/xray_config.py" links "$XUIDB" "$domain" "$xhttp_port")
ssh_current=$(ssh_migration_current_port)

##################################Publish the operation result###########################
if [[ -z "$config_password" ]]; then
    creds_source=""
    if [[ -f "$STATE_DIR/credentials" ]]; then
        creds_source="$STATE_DIR/credentials"
    elif [[ -d "$DEPLOYMENT/files" && -f "$DEPLOYMENT/paths" ]]; then
        creds_idx=$(awk -v target="$STATE_DIR/credentials" '$0 == target { print NR - 1 }' "$DEPLOYMENT/paths")
        if [[ -n "$creds_idx" && -f "$DEPLOYMENT/files/$creds_idx" ]]; then
            creds_source="$DEPLOYMENT/files/$creds_idx"
        fi
    fi
    if [[ -n "$creds_source" ]]; then
        saved_user=$(sed -n -E 's/^Username:[[:space:]]*(.*)$/\1/p' "$creds_source" | head -n1 || true)
        saved_pass=$(sed -n -E 's/^Password:[[:space:]]*(.*)$/\1/p' "$creds_source" | head -n1 || true)
        db_user=$(sqlite3 -batch -bail -readonly "$XUIDB" 'SELECT username FROM users ORDER BY id LIMIT 1;' 2>/dev/null || true)
        if [[ -n "$saved_user" && -n "$saved_pass" && -n "$db_user" && "$saved_user" == "$db_user" ]]; then
            config_username="$saved_user"
            config_password="$saved_pass"
        fi
    fi
fi
install -m 600 /dev/null "$STATE_DIR/credentials.new"
{
    printf 'Panel URL: https://%s/%s/\n' "$domain" "$panel_path"
    if [[ -n "$config_password" ]]; then
        printf 'Username: %s\nPassword: %s\n' "$config_username" "$config_password"
    fi
    if [[ -n "$download_password" ]]; then
        printf 'xHTTP Download URL: https://%s%s\nxHTTP Download Username: xhttp\nxHTTP Download Password: %s\n' \
            "$domain" "$XHTTP_DOWNLOAD_PATH" "$download_password"
    fi
    printf '%s\n' "$links"
} > "$STATE_DIR/credentials.new"
mv -f -- "$STATE_DIR/credentials.new" "$STATE_DIR/credentials"
install -m 600 /dev/null "$STATE_DIR/config.json.new"
python3 - "$domain" "$panel_port" "$panel_path" "$xhttp_port" "$ssh_current" "$BLOCK_RU" "${DNS_PROVIDER:-none}" "$REALITY_TARGET" "$MASK_UPSTREAM" "$XHTTP_CONFIG_PATH" "$XHTTP_DOWNLOAD_PATH" "$DEPLOYMENT/inbounds.json" <<'PYTHON' > "$STATE_DIR/config.json.new"
import json
import sys
domain, panel_port, panel_path, xhttp_port, ssh_port, block_ru, dns_provider, reality_target, mask_upstream, export, download, inbounds_file = sys.argv[1:]
print(json.dumps({
    "domain": domain, "panel_port": int(panel_port), "panel_path": panel_path, "xhttp_port": int(xhttp_port),
    "ssh_port": int(ssh_port), "block_ru": block_ru, "dns_provider": dns_provider, "hy2_port": 443,
    "reality_target": reality_target, "mask_upstream": mask_upstream,
    "xhttp_config_path": export, "xhttp_download_path": download, "inbounds": json.load(open(inbounds_file))
}, indent=2))
PYTHON
mv -f -- "$STATE_DIR/config.json.new" "$STATE_DIR/config.json"
python3 "$LIB_DIR/reality.py" audit "$XUIDB" "$STATE_DIR/config.json"
deployment_write_owned "${managed_files[@]}"
deployment_commit
msg_ok "Deployment complete. Credentials and client links: $STATE_DIR/credentials"
printf 'xHTTP client configuration: %s\n' "$XHTTP_CONFIG_PATH"
if [[ "$SSH_PORT_EXPLICIT" == y ]]; then ssh_migration_setup "$SSH_PORT"; fi
