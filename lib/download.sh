#!/usr/bin/env bash

XHTTP_WEB_CONFIG=/etc/nginx/vpn-script-xhttp.json
XHTTP_WEB_AUTH=/etc/nginx/vpn-script-xhttp.htpasswd

check_xhttp_config_path() {
    python3 - "$1" "$STATE_DIR" <<'PYTHON'
import re
import sys
from pathlib import Path

value, state = sys.argv[1:]
path, state = Path(value), Path(state)
if (
    not re.fullmatch(r"(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.json", value)
    or (state in path.parents and path != state / "xhttp.json")
    or any(Path(root) in path.parents for root in (
        "/etc/x-ui", "/etc/nginx", "/usr/local/x-ui", "/var/www/vpn-script-acme",
    ))
    or path.is_symlink()
    or (path.exists() and not path.is_file())
):
    sys.exit("Use an absolute xHTTP .json file path outside managed service directories")
for parent in path.parents:
    if parent == state and not parent.exists() and not parent.is_symlink():
        continue
    if parent.is_symlink() or not parent.is_dir():
        sys.exit("xHTTP file parent directories must exist and cannot be symbolic links")
    info = parent.stat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        sys.exit("xHTTP file parent directories must be writable only by root")
PYTHON
}

publish_xhttp_file() (
    local source="$1" destination="$2" group="$3" mode="$4" temporary
    temporary=$(mktemp -- "$(dirname -- "$destination")/.vpn-script-xhttp.XXXXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    install -o root -g "$group" -m "$mode" -- "$source" "$temporary" &&
        mv -fT -- "$temporary" "$destination"
)

nginx_worker_group() {
    local directive options
    directive=$(nginx -T | awk '
        !found && /^[[:space:]]*user[[:space:]]/ {
            sub(/;.*/, ""); print (NF > 2 ? $3 : $2); found=1
        }') || return 1
    if [[ -n "$directive" ]]; then
        printf '%s\n' "$directive"
    else
        options=$(nginx -V 2>&1) || return 1
        [[ "$options" =~ --group=([a-zA-Z0-9_-]+) ]] || return 1
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

prepare_xhttp_download() {
    local group password_hash
    group=$(nginx_worker_group) || { deployment_error "Cannot determine the Nginx worker group"; return 1; }
    if [[ "$XHTTP_DOWNLOAD_PATH" == "$previous_xhttp_download" && -f "$STATE_DIR/credentials" ]]; then
        download_password=$(sed -n 's/^xHTTP Download Password: //p' "$STATE_DIR/credentials")
    fi
    if [[ ! "$download_password" =~ ^[a-f0-9]{48}$ ]]; then
        download_password=$(openssl rand -hex 24)
    fi
    password_hash=$(printf '%s\n' "$download_password" | openssl passwd -6 -stdin)
    install -m 600 /dev/null "$DEPLOYMENT/xhttp.htpasswd"
    printf 'xhttp:%s\n' "$password_hash" > "$DEPLOYMENT/xhttp.htpasswd"
    publish_xhttp_file "$DEPLOYMENT/xhttp.htpasswd" "$XHTTP_WEB_AUTH" "$group" 0640
    publish_xhttp_file "$XHTTP_CONFIG_PATH" "$XHTTP_WEB_CONFIG" "$group" 0640
}

render_xhttp_download() {
    cat <<EOF
    location = ${XHTTP_DOWNLOAD_PATH} {
        satisfy all;
        auth_basic "xHTTP configuration";
        auth_basic_user_file ${XHTTP_WEB_AUTH};
        limit_except GET { deny all; }
        alias ${XHTTP_WEB_CONFIG};
        disable_symlinks on;
        types {}
        default_type application/json;
        add_header Content-Disposition 'attachment; filename="xhttp.json"';
        add_header Cache-Control "private, no-store" always;
        add_header X-Content-Type-Options nosniff always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        access_log off;
    }
EOF
}

check_xhttp_download() {
    local status
    local -a request=(--noproxy '*' -sS --max-time 5 --resolve "$domain:443:127.0.0.1"
        "https://$domain$XHTTP_DOWNLOAD_PATH")
    status=$(curl -q "${request[@]}" -o /dev/null -w '%{http_code}') || return 1
    [[ "$status" == 401 ]] || return 1
    printf 'user = "xhttp:%s"\n' "$download_password" |
        curl -q --config - -f "${request[@]}" |
        cmp -s -- "$XHTTP_CONFIG_PATH" -
}
