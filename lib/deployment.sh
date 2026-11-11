#!/usr/bin/env bash

STATE_DIR=${STATE_DIR:-/var/lib/vpn-script}
DEPLOYMENT=""

deployment_error() {
    printf 'vpn-script: %s\n' "$*" >&2
    return 1
}

deployment_lock() {
    if [[ -L "$STATE_DIR" ]]; then
        deployment_error "State directory is a symbolic link"
        return 1
    fi
    install -d -m 700 "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || deployment_error "Another VPN operation is active"
}

deployment_active() {
    local id
    [[ -f "$STATE_DIR/active" && ! -L "$STATE_DIR/active" ]] || return 1
    read -r id < "$STATE_DIR/active" || return 1
    [[ "$id" =~ ^transaction\.[a-zA-Z0-9]+$ ]] || return 2
    [[ -d "$STATE_DIR/$id" && ! -L "$STATE_DIR/$id" ]] || return 2
    printf '%s/%s\n' "$STATE_DIR" "$id"
}

deployment_record() {
    local path="$1" index
    index=$(wc -l < "$DEPLOYMENT/paths")
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a -- "$path" "$DEPLOYMENT/files/$index"
    fi
    printf '%s\n' "$path" >> "$DEPLOYMENT/paths"
}

deployment_begin() {
    local path unit status
    DEPLOYMENT=$(mktemp -d "$STATE_DIR/transaction.XXXXXXXX")
    mkdir "$DEPLOYMENT/files"
    : > "$DEPLOYMENT/paths"
    : > "$DEPLOYMENT/services"
    : > "$DEPLOYMENT/listeners"
    local transport xray_ports=""
    if [[ -f /usr/local/x-ui/bin/config.json ]]; then
        xray_ports=$(python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path('/usr/local/x-ui/bin/config.json').read_text())
print(' '.join(str(item['port']) for item in config.get('inbounds', [])
               if isinstance(item.get('port'), int)))
PY
        ) || return 1
    fi
    for transport in t u; do
        ss -H "-l${transport}np" | awk -v transport="$transport" -v xray_ports="$xray_ports" '
            { for (i=1; i<=3; i++) {
                owner=(i==1 ? "nginx" : (i==2 ? "x-ui" : "xray"))
                if (index($0,"\"" owner)) {
                    address=$4; sub(/^.*:/,"",address)
                    # Unconnected outbound UDP sockets also appear in ss -lu.
                    # Only declared inbound ports must survive a core restart.
                    if (transport=="u" && owner=="xray" &&
                        !index(" " xray_ports " ", " " address " ")) continue
                    print transport, address, owner
                }
            }}' >> "$DEPLOYMENT/listeners"
    done
    dpkg-query -W -f='${Version}' nginx > "$DEPLOYMENT/nginx-version" 2>/dev/null || :
    for path in "$@"; do
        deployment_record "$path"
    done
    for unit in nginx.service x-ui.service fail2ban.service; do
        status=$(systemctl show --property=LoadState --value "$unit")
        if [[ "$status" == loaded ]]; then
            printf '%s %s %s\n' "$unit" "$(systemctl is-active "$unit" || :)" \
                "$(systemctl is-enabled "$unit" || :)" >> "$DEPLOYMENT/services"
        else
            printf '%s missing missing\n' "$unit" >> "$DEPLOYMENT/services"
        fi
    done
    if [[ -f "$XUIDB" ]]; then
        install -m 600 /dev/null "$DEPLOYMENT/x-ui.db"
        sqlite3 -batch -bail -readonly "$XUIDB" ".timeout 5000" ".backup '$DEPLOYMENT/x-ui.db'"
        [[ -s "$DEPLOYMENT/x-ui.db" && "$(sqlite3 -batch -bail -readonly "$DEPLOYMENT/x-ui.db" 'PRAGMA integrity_check;')" == ok ]] ||
            { deployment_error "Database snapshot failed its integrity check"; return 1; }
        stat -c '%a %u %g' -- "$(dirname "$XUIDB")" > "$DEPLOYMENT/db-directory"
    fi
    sync -f "$DEPLOYMENT"
    printf '%s\n' "${DEPLOYMENT##*/}" > "$STATE_DIR/active.new"
    mv -f -- "$STATE_DIR/active.new" "$STATE_DIR/active"
    sync -f "$STATE_DIR"
}

deployment_restore_path() {
    local path="$1" copy="$2"
    if [[ -d "$path" && ! -L "$path" ]]; then
        rm -rf -- "$path" || return 1
    else
        rm -f -- "$path" || return 1
    fi
    if [[ -e "$copy" || -L "$copy" ]]; then
        mkdir -p -- "$(dirname "$path")" && cp -a -- "$copy" "$path"
    fi
}

deployment_restore_db() {
    local state="$1" mode owner group temp
    if [[ ! -f "$state/x-ui.db" ]]; then
        rm -f -- "$XUIDB-wal" "$XUIDB-shm" "$XUIDB-journal" "$XUIDB"
        return
    fi
    read -r mode owner group < "$state/db-directory" || return 1
    mkdir -p -- "$(dirname "$XUIDB")" || return 1
    temp=$(mktemp "${XUIDB}.restore.XXXXXXXX") || return 1
    if ! cp -- "$state/x-ui.db" "$temp" ||
       ! rm -f -- "$XUIDB-wal" "$XUIDB-shm" "$XUIDB-journal" ||
       ! mv -fT -- "$temp" "$XUIDB"; then
        rm -f -- "$temp"
        return 1
    fi
    chmod "$mode" -- "$(dirname "$XUIDB")" && chown "$owner:$group" -- "$(dirname "$XUIDB")" || return 1
    [[ "$(sqlite3 -batch -bail -readonly "$XUIDB" 'PRAGMA integrity_check;')" == ok ]]
}

deployment_prepare_database() {
    # The panel is stopped now. Refresh the snapshot to retain writes made while
    # packages and certificates were being prepared, then journal the first write.
    if [[ -f "$XUIDB" ]]; then
        install -m 600 /dev/null "$DEPLOYMENT/database.new"
        sqlite3 -batch -bail -readonly "$XUIDB" ".timeout 5000" ".backup '$DEPLOYMENT/database.new'" || return 1
        [[ "$(sqlite3 -batch -bail -readonly "$DEPLOYMENT/database.new" 'PRAGMA integrity_check;')" == ok ]] || return 1
        mv -f -- "$DEPLOYMENT/database.new" "$DEPLOYMENT/x-ui.db" || return 1
        if [[ ! -f "$DEPLOYMENT/db-directory" ]]; then
            stat -c '%a %u %g' -- "$(dirname "$XUIDB")" > "$DEPLOYMENT/db-directory" || return 1
        fi
    fi
    touch "$DEPLOYMENT/database-write" && sync -f "$DEPLOYMENT"
}

deployment_rollback() {
    local state="$1" unit active enabled index path version current failed=0
    local -a paths packages
    printf 'Restoring deployment %s\n' "${state##*/}" >&2
    if [[ ! -d "$state/files" || ! -r "$state/services" ]] ||
       ! mapfile -t paths < "$state/paths" ||
       ! version=$(cat -- "$state/nginx-version"); then
        deployment_error "Cannot read the deployment recovery journal"
        return 1
    fi
    if [[ -f "$state/database-write" ]]; then
        if [[ -e "$state/x-ui.db" || -e "$state/db-directory" ]]; then
            if [[ ! -s "$state/x-ui.db" || ! -s "$state/db-directory" ]] ||
               [[ "$(sqlite3 -batch -bail -readonly "$state/x-ui.db" 'PRAGMA integrity_check;')" != ok ]]; then
                deployment_error "Database snapshot failed its integrity check; database was preserved"
                return 1
            fi
        fi
    fi
    if systemctl is-active --quiet x-ui.service && ! systemctl stop x-ui.service; then
        deployment_error "Cannot stop x-ui.service to restore SQLite"
        return 1
    fi
    if [[ -f "$state/database-write" ]]; then
        deployment_restore_db "$state" || { deployment_error "Database restore failed"; return 1; }
    fi
    for ((index=${#paths[@]}-1; index>=0; index--)); do
        path=${paths[index]}
        deployment_restore_path "$path" "$state/files/$index" ||
            { printf 'Restore failed for %s\n' "$path" >&2; failed=1; }
    done
    current=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || :)
    if [[ -n "$version" && "$version" != "$current" ]]; then
        shopt -s nullglob
        packages=("$state"/nginx_*.deb)
        shopt -u nullglob
        if (( ${#packages[@]} != 1 )) || ! dpkg --force-confold -i "${packages[0]}"; then
            printf 'Restore failed for Nginx package %s\n' "$version" >&2
            failed=1
        fi
    fi
    systemctl daemon-reload || failed=1
    while read -r unit active enabled; do
        case "$enabled" in
            enabled) systemctl enable "$unit" || failed=1 ;;
            disabled|missing)
                if systemctl is-enabled --quiet "$unit"; then
                    systemctl disable "$unit" || failed=1
                fi ;;
        esac
        if [[ "$active" == active ]]; then
            systemctl reload-or-restart "$unit" && systemctl is-active --quiet "$unit" ||
                { printf 'Restore failed for service %s\n' "$unit" >&2; failed=1; }
        elif systemctl is-active --quiet "$unit"; then
            systemctl stop "$unit" || failed=1
        fi
    done < "$state/services"
    if [[ -f "$state/firewall" ]] && ! ufw reload; then
        printf 'Firewall reload failed during rollback\n' >&2
        failed=1
    fi
    # A service may be active while its application is still starting.
    # Require every pre-existing listener before reporting successful recovery.
    if [[ -f "$state/listeners" ]]; then
        local transport port owner attempt ready
        while read -r transport port owner; do
            ready=n
            for attempt in {1..100}; do
                if check_listener "$port" "$transport" present "$owner"; then ready=y; break; fi
                sleep 0.2
            done
            if [[ "$ready" != y ]]; then
                printf 'Restore failed for listener %s/%s (%s)\n' "$port" "$transport" "$owner" >&2
                failed=1
            fi
        done < "$state/listeners"
    fi
    (( failed == 0 )) || return 1
    rm -f -- "$STATE_DIR/active"
}

deployment_exit() {
    local rc=$1 state
    trap - EXIT
    if [[ -n "$DEPLOYMENT" && -f "$STATE_DIR/active" ]]; then
        if state=$(deployment_active); then
            if ! deployment_rollback "$state"; then
                printf 'Rollback incomplete. Recovery data: %s\n' "$state" >&2
            fi
        else
            printf 'Cannot read the deployment recovery journal\n' >&2
        fi
        (( rc != 0 )) || rc=1
    fi
    exit "$rc"
}

deployment_commit() {
    sync -f "$STATE_DIR"
    rm -f -- "$STATE_DIR/active"
    sync -f "$STATE_DIR"
    DEPLOYMENT=""
}

resource_digest() {
    local path="$1"
    if [[ -L "$path" ]]; then
        { printf 'symlink\n'; readlink -- "$path"; } | sha256sum | cut -d' ' -f1
    elif [[ -f "$path" ]]; then
        sha256sum -- "$path" | cut -d' ' -f1
    elif [[ ! -e "$path" ]]; then
        printf 'absent\n'
    else
        deployment_error "Unsupported resource type: $path"
    fi
}

# Only rules added with the project's comment are removed by uninstall.
allow_web_ports() {
    local port proto rules
    rules=$(LC_ALL=C ufw show added)
    if LC_ALL=C ufw status | grep -q '^Status: active'; then
        touch "$DEPLOYMENT/firewall"
    fi
    for port in 80/tcp 443/tcp 443/udp; do
        proto=${port%/*}
        if ! grep -Eq "^ufw allow ${port}([[:space:]]|$)" <<< "$rules"; then
            ufw allow "$port" comment "vpn-script-${proto}-${port#*/}"
        fi
    done
}

check_listener() {
    local port="$1" transport="$2" mode="$3" process="$4" rows
    rows=$(ss -H "-l${transport}np" "sport = :$port") || return 1
    if [[ -z "$rows" ]]; then
        [[ "$mode" == available ]]
        return
    fi
    if [[ "$process" == xray ]]; then process='xray(-linux-[[:alnum:]]+)?'; fi
    awk -v port="$port" -v mode="$mode" -v proc="$process" '
        {
            if (mode=="loopback" && $4 != "127.0.0.1:" port) exit 1
            owners=$0
            if (!match(owners, /\("[^"]+",pid=/)) exit 1
            do {
                if (substr(owners, RSTART+2, RLENGTH-8) !~ ("^(" proc ")$")) exit 1
                owners=substr(owners, RSTART+RLENGTH)
            } while (match(owners, /\("[^"]+",pid=/))
        }' <<< "$rows"
}

legacy_resource() {
    local path="$1"
    case "$path" in
        /etc/nginx/sites-enabled/*)
            [[ -L "$path" && "$(readlink -- "$path")" == "/etc/nginx/sites-available/${path##*/}" ]] ;;
        /etc/nginx/sites-available/80.conf)
            grep -Fq '/.well-known/acme-challenge/' "$path" &&
                grep -Fq 'root /var/www/html;' "$path" &&
                grep -Fq "server_name ${domain};" "$path" ;;
        "/etc/nginx/sites-available/$domain")
            grep -Fq '/dev/shm/nginx-http.sock' "$path" && grep -Fq '#X-UI Admin Panel' "$path" ;;
        /etc/nginx/stream-enabled/stream.conf)
            grep -Fq '/dev/shm/nginx-http.sock' "$path" && (grep -Fq 'upstream reality_failover' "$path" || grep -Fq 'upstream www' "$path") ;;
        /etc/nginx/snippets/includes.conf)
            grep -Fxq '    proxy_set_header X-Forwarded-Proto $scheme;' "$path" &&
                grep -Fxq '    proxy_http_version 1.1;' "$path" ;;
        /etc/nginx/conf.d/probe_security.conf)
            grep -Fq 'zone=probe_limit:10m' "$path" && grep -Fq 'log_format probe_combined' "$path" ;;
        /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh)
            grep -Fq 'systemctl restart x-ui' "$path" && grep -Fq 'systemctl reload nginx' "$path" ;;
        /etc/systemd/system/x-ui.service)
            grep -Fq 'ExecStart=/usr/local/x-ui/x-ui' "$path" ;;
        /etc/systemd/system/nginx.service.d/override.conf|/etc/systemd/system/x-ui.service.d/override.conf|/etc/systemd/system/nginx.service.d/vpn-script.conf|/etc/systemd/system/x-ui.service.d/vpn-script.conf)
            [[ "$(cat -- "$path")" == $'[Service]\nLimitNOFILE=65535' ]] ;;
        /etc/fail2ban/jail.d/99-sshd.local)
            (grep -Fq 'banaction = ufw' "$path" || grep -Fq 'banaction = iptables-allports' "$path") && grep -Fq 'findtime  = 600' "$path" ;;
        /usr/share/keyrings/nginx-archive-keyring.gpg|/etc/apt/sources.list.d/nginx-mainline.list|/etc/apt/preferences.d/99-nginx-mainline)
            [[ -f /etc/apt/sources.list.d/nginx-mainline.list ]] &&
                grep -Fq 'nginx.org/packages/mainline/' /etc/apt/sources.list.d/nginx-mainline.list ;;
        *) return 1 ;;
    esac
}

deployment_preflight_ownership() {
    local path digest previous conflicts=0
    local -a legacy=()
    for path in "$@"; do
        digest=$(resource_digest "$path")
        [[ "$digest" != absent ]] || continue
        previous=""
        if [[ -f "$STATE_DIR/owned" ]]; then
            previous=$(awk -v path="$path" '$2 == path {print $1}' "$STATE_DIR/owned")
        fi
        if [[ "$digest" == "$previous" ]]; then
            continue
        elif [[ -z "$previous" ]] && legacy_resource "$path"; then
            printf 'Legacy candidate: %s\n' "$path"
            legacy+=("$digest $path")
        else
            printf 'Resource conflict: %s\n' "$path" >&2
            conflicts=1
        fi
    done
    if [[ -f "$XUIDB" && ! -f "$STATE_DIR/config.json" ]]; then
        digest=$(sqlite3 -batch -bail -readonly "$XUIDB" \
            "SELECT key,value FROM settings WHERE key IN ('webPort','webBasePath','webListen','xrayTemplateConfig') ORDER BY id;" \
            "SELECT id,protocol,tag,enable,listen,port,stream_settings FROM inbounds ORDER BY id;" |
            sha256sum | cut -d' ' -f1)
        legacy+=("$digest $XUIDB")
        printf 'Legacy candidate: existing 3X-UI database (preserved)\n'
    fi
    if (( ${#legacy[@]} > 0 )); then
        digest=$(printf '%s\n' "${legacy[@]}" | sha256sum | cut -d' ' -f1)
        printf 'Legacy adoption token: %s\n' "$digest"
        if [[ "$DRY_RUN" != y && ( "$ADOPT_LEGACY" != y || "$ADOPT_TOKEN" != "$digest" ) ]]; then
            deployment_error "Run -dry_run y, then repeat with -adopt_legacy y -adopt_token TOKEN"
            return 1
        fi
    fi
    (( conflicts == 0 ))
}

deployment_write_owned() {
    local path digest
    : > "$STATE_DIR/owned.new"
    for path in "$@"; do
        digest=$(resource_digest "$path")
        if [[ "$digest" != absent ]]; then
            printf '%s %s\n' "$digest" "$path" >> "$STATE_DIR/owned.new"
        fi
    done
    mv -f -- "$STATE_DIR/owned.new" "$STATE_DIR/owned"
}

deployment_uninstall() {
    local digest path port rule
    local -a paths=()
    if [[ ! -f "$STATE_DIR/owned" ]]; then
        printf 'No managed resources are recorded\n'
        return
    fi
    while read -r digest path; do
        if [[ "$(resource_digest "$path")" == "$digest" ]]; then
            paths+=("$path")
        elif [[ -e "$path" || -L "$path" ]]; then
            deployment_error "Refusing to remove changed resource: $path"
            return 1
        fi
    done < "$STATE_DIR/owned"
    printf '%s\n' "${paths[@]}"
    if [[ "$DRY_RUN" == y ]]; then
        return
    fi
    deployment_begin "${paths[@]}" "$STATE_DIR/owned" "$STATE_DIR/config.json" \
        "$STATE_DIR/credentials" /etc/ufw/user.rules /etc/ufw/user6.rules /etc/nginx/nginx.conf
    trap 'deployment_exit "$?"' EXIT
    for path in "${paths[@]}"; do
        if [[ "$path" == /etc/systemd/system/x-ui.service ]]; then
            if systemctl is-active --quiet x-ui.service; then systemctl stop x-ui.service; fi
            if systemctl is-enabled --quiet x-ui.service; then systemctl disable x-ui.service; fi
        fi
        rm -f -- "$path"
    done
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i '/^# BEGIN vpn-script stream$/,/^# END vpn-script stream$/d;
            /^# BEGIN vpn-script sites$/,/^# END vpn-script sites$/d' /etc/nginx/nginx.conf
        nginx -t
        if systemctl is-active --quiet nginx.service; then systemctl reload nginx.service; fi
    fi
    systemctl daemon-reload
    if systemctl is-active --quiet fail2ban.service; then systemctl reload fail2ban.service; fi
    if command -v ufw >/dev/null; then
        if LC_ALL=C ufw status | grep -q '^Status: active'; then touch "$DEPLOYMENT/firewall"; fi
        for port in 80/tcp 443/tcp 443/udp; do
            rule="ufw allow $port comment 'vpn-script-${port%/*}-${port#*/}'"
            if LC_ALL=C ufw show added | grep -Fxq "$rule"; then
                ufw --force delete allow "$port" comment "vpn-script-${port%/*}-${port#*/}"
            fi
        done
    fi
    rm -f -- "$STATE_DIR/owned" "$STATE_DIR/config.json" "$STATE_DIR/credentials"
    deployment_commit
    printf 'Managed VPN resources removed\n'
}
