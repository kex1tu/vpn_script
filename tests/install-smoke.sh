#!/usr/bin/env bash
# Exercise the real installer and daemons, substituting only systemd and UFW.
set -Eeuo pipefail
smoke_failure() {
    local result=$? line=$1
    printf 'Smoke test failed at line %s (exit %s)\n' "$line" "$result" >&2
    if [[ -n "${QA_SERVICES:-}" && -f "$QA_SERVICES/x-ui.log" ]]; then
        tail -100 "$QA_SERVICES/x-ui.log" >&2
    fi
    return "$result"
}
trap 'smoke_failure "$LINENO"' ERR
[[ -f /.dockerenv ]]
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
smoke_cleanup() {
    jobs -pr | xargs -r kill
    rm -rf -- "$fixture"
}
trap smoke_cleanup EXIT
mkdir "$fixture/bin"
export QA_SERVICES="$fixture/services"
mkdir "$QA_SERVICES"
cat > "$fixture/bin/systemctl" <<'MOCK'
#!/bin/bash
set -eu
exec 9>&-
command=$1; shift
case "$command" in
    show)
        unit=${!#}
        if [[ -f "/etc/systemd/system/$unit" || -f "/lib/systemd/system/$unit" || -f "/usr/lib/systemd/system/$unit" ]]; then
            printf 'loaded\n'
        else
            printf 'not-found\n'
        fi
        exit 0 ;;
    daemon-reload) exit 0 ;;
    is-enabled) [[ " $* " == *' --quiet '* ]] || printf 'disabled\n'; exit 1 ;;
    enable|disable) exit 0 ;;
esac
unit=${!#}; unit=${unit%.service}
active() {
    case "$unit" in
        nginx) [[ -s /var/run/nginx.pid ]] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null ;;
        x-ui) [[ -s "$QA_SERVICES/x-ui.pid" ]] && kill -0 "$(cat "$QA_SERVICES/x-ui.pid")" 2>/dev/null ;;
        ssh) pgrep -x sshd >/dev/null ;;
        *) [[ -f "$QA_SERVICES/$unit.active" ]] ;;
    esac
}
stop() {
    case "$unit" in
        nginx) if active; then nginx -s stop; fi ;;
        x-ui) if active; then kill "$(cat "$QA_SERVICES/x-ui.pid")"; for i in {1..30}; do active || break; sleep 0.1; done; fi ;;
    esac
    rm -f "$QA_SERVICES/$unit.active" "$QA_SERVICES/$unit.pid"
}
start() {
    case "$unit" in
        nginx) nginx ;;
        x-ui)
            if [[ -f "$QA_SERVICES/fail-once" ]]; then rm "$QA_SERVICES/fail-once"; return 1; fi
            if [[ "${QA_TRACE:-n}" == y ]]; then
                python3 - <<'PY'
import json
import sqlite3
with sqlite3.connect('/etc/x-ui/x-ui.db') as db:
    value, = db.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    config = json.loads(value)
    config['log'] = {'loglevel': 'debug', 'access': ''}
    db.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
PY
            fi
            (cd /usr/local/x-ui; exec ./x-ui run) > "$QA_SERVICES/x-ui.log" 2>&1 & echo "$!" > "$QA_SERVICES/x-ui.pid" ;;
        *) touch "$QA_SERVICES/$unit.active" ;;
    esac
}
case "$command" in
    is-active)
        if active; then
            [[ " $* " == *' --quiet '* ]] || printf 'active\n'
        else
            [[ " $* " == *' --quiet '* ]] || printf 'inactive\n'
            exit 3
        fi ;;
    stop) stop ;;
    start) active || start ;;
    restart) stop; start ;;
    reload|reload-or-restart)
        if [[ "$unit" == nginx ]] && active; then nginx -s reload; else active || start; fi ;;
    *) printf 'Unsupported service shim command\n' >&2; exit 2 ;;
esac
MOCK
cat > "$fixture/bin/ufw" <<'MOCK'
#!/bin/bash
set -eu
case "$1" in
    show) [[ ! -f "$QA_SERVICES/ufw.rules" ]] || cat "$QA_SERVICES/ufw.rules" ;;
    status) printf 'Status: inactive\n' ;;
    allow) printf "ufw allow %s comment '%s'\n" "$2" "$4" >> "$QA_SERVICES/ufw.rules" ;;
    reload) exit 0 ;;
    --force) exit 0 ;;
    *) exit 2 ;;
esac
MOCK
chmod 755 "$fixture/bin/"*
cat > "$fixture/bin/sqlite3" <<'MOCK'
#!/bin/bash
set -eu
if [[ "${!#}" == /etc/x-ui/x-ui.db && -f "$QA_SERVICES/sqlite-fault" ]]; then
    input=$(mktemp)
    cat > "$input"
    if grep -q '^BEGIN IMMEDIATE;' "$input"; then
        mode=$(cat "$QA_SERVICES/sqlite-fault")
        rm "$QA_SERVICES/sqlite-fault"
        case "$mode" in
            readonly) /usr/bin/sqlite3 -batch -bail -readonly /etc/x-ui/x-ui.db < "$input"; result=$? ;;
            kill) kill -KILL "$PPID"; result=137 ;;
            *) exit 2 ;;
        esac
        rm "$input"
        exit "$result"
    fi
    /usr/bin/sqlite3 "$@" < "$input"
    rm "$input"
else
    exec /usr/bin/sqlite3 "$@"
fi
MOCK
chmod 755 "$fixture/bin/sqlite3"
export PATH="$fixture/bin:$PATH"
rm -f /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
if [[ "${QA_COLD_INSTALL:-n}" == y ]]; then
    mv /usr/local/x-ui "$fixture/preinstalled-panel"
else
    # The image only extracts the release. Model a complete preinstalled service;
    # otherwise the shim can start it but snapshots correctly record it missing.
    install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
fi
if [[ -n "${QA_LEGACY_DB:-}" ]]; then
    if [[ "$QA_LEGACY_DB" == *.sql ]]; then
        sqlite3 -batch -bail /etc/x-ui/x-ui.db < "$QA_LEGACY_DB"
    else
        sqlite3 -batch -bail -readonly "$QA_LEGACY_DB" '.backup /etc/x-ui/x-ui.db'
    fi
fi
printf '127.0.0.1 test.example.com\n' >> /etc/hosts
cp /etc/letsencrypt/live/test.example.com/fullchain.pem /usr/local/share/ca-certificates/vpn-test.crt
cp /etc/vpn-qa-doh/cert.pem /usr/local/share/ca-certificates/vpn-doh-test.crt
update-ca-certificates >/dev/null 2>&1
install -d /run/sshd
ssh-keygen -A >/dev/null
/usr/sbin/sshd
printf 'cover from configured port\n' > /var/www/html/qa-cover.txt
python3 -m http.server 18081 --bind 127.0.0.1 --directory /var/www/html > "$fixture/http.log" 2>&1 &
for attempt in {1..30}; do
    if curl -fsS http://127.0.0.1:18081/qa-cover.txt -o /dev/null 2>/dev/null; then break; fi
    sleep 0.1
done
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then
    # A controlled provider domain must not already match a real RU domain list:
    # this isolates the final IP check after the DoH response.
    sed -i '/^AI_DOMAINS = \[/a\    "full:qa-doh.test",' "$repo/lib/xray_config.py"
    gateway=$(getent ahostsv4 "${QA_TARGET_GATEWAY:?A separate target container is required}" | awk 'NR==1 {print $1}')
    ip route add 1.1.1.1/32 via "$gateway"
    ip route add 77.88.8.8/32 via "$gateway"
    printf '1.1.1.1 rutracker.org\n' >> /etc/hosts
    printf '1.1.1.1 classic.qa.test classic-alt.qa.test wrong-cert.qa.test\n' >> /etc/hosts
    printf '1.1.1.1 qa-doh.test qa-ordinary.test\n%s xbox-dns.ru eu.geohide.ru dns.comss.one\n' "$gateway" >> /etc/hosts
    mkdir "$fixture/private-target"
    printf 'vpn-through-real-client\n' > "$fixture/private-target/vpn-test.txt"
    python3 -m http.server 18080 --bind 127.0.0.1 --directory "$fixture/private-target" > "$fixture/private.log" 2>&1 &
    python3 -m http.server 18080 --bind ::1 --directory "$fixture/private-target" > "$fixture/private6.log" 2>&1 &
fi
args=(-install n -subdomain test.example.com -ssh_port 22 -block_ru n -dns_provider none -reality_target classic.qa.test)
first_install=(-mask_port 18081 -xhttp_config_path /root/qa-xhttp.json -xhttp_download_path /download/qa-xhttp.json)
if [[ -n "${QA_LEGACY_DB:-}" || "${QA_COLD_INSTALL:-n}" != y ]]; then
    preview=$(bash "$repo/script.sh" "${args[@]}" "${first_install[@]}" -dry_run y)
    token=$(awk '/^Legacy adoption token:/ {print $4}' <<< "$preview")
    [[ "$token" =~ ^[a-f0-9]{64}$ ]]
    args+=(-adopt_legacy y -adopt_token "$token")
fi
printf '# Operator-owned configuration\n' > /etc/nginx/conf.d/operator.conf
if ! bash "$repo/script.sh" "${args[@]}" "${first_install[@]}" > "$fixture/install.log" 2>&1; then
    cat "$fixture/install.log"
    [[ ! -f "$QA_SERVICES/x-ui.log" ]] || tail -30 "$QA_SERVICES/x-ui.log"
    exit 1
fi
[[ -f /var/lib/vpn-script/config.json && -f /var/lib/vpn-script/credentials ]]
[[ $(stat -c %a /var/lib/vpn-script/credentials) == 600 ]]
[[ $(stat -c %a /root/qa-xhttp.json) == 600 ]]
public_curl=(curl -q --noproxy '*' --resolve test.example.com:443:127.0.0.1 -sS --max-time 5)
download_url=https://test.example.com/download/qa-xhttp.json
[[ $("${public_curl[@]}" -f https://test.example.com/qa-cover.txt) == 'cover from configured port' ]]
[[ $(jq -r .mask_upstream /var/lib/vpn-script/config.json) == http://127.0.0.1:18081 ]]
[[ $(sqlite3 /etc/x-ui/x-ui.db "SELECT json_extract(stream_settings, '$.hysteriaSettings.masquerade.url') FROM inbounds WHERE port=443;") == http://127.0.0.1:18081 ]]
[[ $("${public_curl[@]}" -o /dev/null -w '%{http_code}' "$download_url") == 401 ]]
[[ $("${public_curl[@]}" -u xhttp:invalid -o /dev/null -w '%{http_code}' "$download_url") == 401 ]]
download_credentials=$(sed -n 's/^xHTTP Download Password: //p' /var/lib/vpn-script/credentials)
printf 'user = "xhttp:%s"\n' "$download_credentials" |
    "${public_curl[@]}" --config - -D "$fixture/download.headers" -f "$download_url" | cmp -s /root/qa-xhttp.json -
grep -Eiq '^Cache-Control: private, no-store' "$fixture/download.headers"
printf 'PASS Custom cover port and authenticated xHTTP JSON download\n'
bash "$repo/audit.sh" > "$fixture/audit.log" 2>&1 || {
    cat "$fixture/audit.log"; exit 1;
}
printf 'PASS Audit accepts the actual healthy deployment\n'
if grep -Eq 'Password:|vless://|hysteria2://' "$fixture/install.log" ||
   grep -Fq -- "$download_credentials" "$fixture/install.log"; then
    printf 'Secrets leaked to ordinary output\n' >&2
    exit 1
fi
if [[ -n "${QA_LEGACY_DB:-}" && "${QA_LEGACY_DEFAULT:-n}" != y ]]; then
    cp /var/lib/vpn-script/credentials "$fixture/login-credentials"
    printf 'Username: legacy-admin\nPassword: legacy-test-only-password\n' >> "$fixture/login-credentials"
    python3 "$repo/tests/login-smoke.py" "$fixture/login-credentials"
    [[ $(sqlite3 /etc/x-ui/x-ui.db 'SELECT count(*) FROM client_traffics WHERE up>=42 AND down>=77') == 2 ]]
else
    python3 "$repo/tests/login-smoke.py" /var/lib/vpn-script/credentials
fi
if [[ "${QA_LEGACY_DEFAULT:-n}" == y ]]; then
    [[ $(sqlite3 /etc/x-ui/x-ui.db 'SELECT count(*) FROM client_traffics WHERE up>=42 AND down>=77') == 2 ]]
    printf 'PASS Upgrade from 2.9.4 replaces admin/admin and preserves clients and counters\n'
    exit 0
fi
first=$(sqlite3 /etc/x-ui/x-ui.db 'SELECT id,email,uuid,auth FROM clients ORDER BY id')
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then
    if ! python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials; then
        tail -60 "$QA_SERVICES/x-ui.log"
        exit 1
    fi
fi
if ! bash "$repo/script.sh" "${args[@]}" > "$fixture/reinstall.log" 2>&1; then
    cat "$fixture/reinstall.log"
    exit 1
fi
[[ $(sed -n 's/^xHTTP Download Password: //p' /var/lib/vpn-script/credentials) == "$download_credentials" ]]
printf 'user = "xhttp:%s"\n' "$download_credentials" |
    "${public_curl[@]}" --config - -f "$download_url" | cmp -s /root/qa-xhttp.json -
[[ "$first" == "$(sqlite3 /etc/x-ui/x-ui.db 'SELECT id,email,uuid,auth FROM clients ORDER BY id')" ]]
[[ $(sqlite3 /etc/x-ui/x-ui.db 'SELECT count(*) FROM settings WHERE key="webListen"') == 1 ]]
if [[ -z "${QA_LEGACY_DB:-}" ]]; then
    grep -Eq '^Username: [A-Za-z0-9_-]+' /var/lib/vpn-script/credentials
    grep -Eq '^Password: [A-Za-z0-9_-]+' /var/lib/vpn-script/credentials
    python3 "$repo/tests/login-smoke.py" /var/lib/vpn-script/credentials
fi
printf 'PASS Real installer clean deployment and repeat preserve normalized clients and credentials\n'
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials; fi
reality_identity=$(sqlite3 /etc/x-ui/x-ui.db "SELECT id,tag,port,json_extract(stream_settings,'\$.realitySettings.privateKey'),json_extract(stream_settings,'\$.realitySettings.shortIds'),json_extract(stream_settings,'\$.xhttpSettings.path') FROM inbounds WHERE json_extract(stream_settings,'\$.security')='reality' ORDER BY id;" | sha256sum)
without_target=()
for ((index=0; index<${#args[@]}; index+=2)); do
    if [[ "${args[index]}" != -reality_target ]]; then without_target+=("${args[index]}" "${args[index+1]}"); fi
done
bash "$repo/script.sh" "${without_target[@]}" -reality_target classic-alt.qa.test \
    -xhttp_config_path /root/qa-xhttp-moved.json -xhttp_download_path none > "$fixture/classic-change.log" 2>&1 ||
    { cat "$fixture/classic-change.log"; exit 1; }
[[ ! -e /root/qa-xhttp.json && -f /root/qa-xhttp-moved.json &&
   ! -e /etc/nginx/vpn-script-xhttp.json && ! -e /etc/nginx/vpn-script-xhttp.htpasswd ]]
[[ $("${public_curl[@]}" -o /dev/null -w '%{http_code}' "$download_url") == 404 ]]
bash "$repo/script.sh" "${without_target[@]}" > "$fixture/classic-preserve.log" 2>&1 || { cat "$fixture/classic-preserve.log"; exit 1; }
[[ $(jq -r .reality_target /var/lib/vpn-script/config.json) == classic-alt.qa.test ]]
[[ "$reality_identity" == "$(sqlite3 /etc/x-ui/x-ui.db "SELECT id,tag,port,json_extract(stream_settings,'\$.realitySettings.privateKey'),json_extract(stream_settings,'\$.realitySettings.shortIds'),json_extract(stream_settings,'\$.xhttpSettings.path') FROM inbounds WHERE json_extract(stream_settings,'\$.security')='reality' ORDER BY id;" | sha256sum)" ]]
args=("${without_target[@]}")
printf 'PASS Classic target changes and unattended repeat preserve REALITY keys, short IDs, paths and identities\n'
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then
    baseline=$(sha256sum /var/lib/vpn-script/config.json /var/lib/vpn-script/owned)
    for target in test.example.com 127.0.0.1 wrong-cert.qa.test; do
        if bash "$repo/script.sh" "${args[@]}" -reality_target "$target" > "$fixture/reality-target-invalid.log" 2>&1; then exit 1; fi
        [[ "$baseline" == "$(sha256sum /var/lib/vpn-script/config.json /var/lib/vpn-script/owned)" && ! -f /var/lib/vpn-script/active ]]
    done
    for mode in tls12 no-h2; do
        curl -fsS "http://$QA_TARGET_GATEWAY:18080/classic-mode/$mode" >/dev/null
        if bash "$repo/script.sh" "${args[@]}" > "$fixture/reality-target-$mode.log" 2>&1; then exit 1; fi
        [[ "$baseline" == "$(sha256sum /var/lib/vpn-script/config.json /var/lib/vpn-script/owned)" && ! -f /var/lib/vpn-script/active ]]
    done
    curl -fsS "http://$QA_TARGET_GATEWAY:18080/classic-mode/normal" >/dev/null
    python3 "$repo/tests/reality-negative.py" /var/lib/vpn-script/credentials
    systemctl stop x-ui.service
    curl --noproxy '*' -fsS --max-time 5 --resolve 'test.example.com:443:127.0.0.1' https://test.example.com/ >/dev/null
    systemctl start x-ui.service
    sleep 2 # Nginx's declared fail_timeout=1s must expire before REALITY traffic resumes.
    printf 'PASS Invalid Classic targets fail before writes; HTTPS survives an Xray outage\n'
fi
openssl req -x509 -nodes -days 365 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/letsencrypt/live/test.example.com/privkey.pem \
    -out /etc/letsencrypt/live/test.example.com/fullchain.pem \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,DNS:test.example.com' >/dev/null 2>&1
cp /etc/letsencrypt/live/test.example.com/fullchain.pem /etc/letsencrypt/live/test.example.com/chain.pem
cp /etc/letsencrypt/live/test.example.com/fullchain.pem /usr/local/share/ca-certificates/vpn-test.crt
update-ca-certificates >/dev/null 2>&1
RENEWED_LINEAGE=/etc/letsencrypt/live/test.example.com bash /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
printf 'PASS Renewal hook verifies the new TCP and QUIC certificates\n'
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then
    for mode in y n; do
        bash "$repo/script.sh" "${args[@]}" -block_ru "$mode" > "$fixture/routing-$mode.log" 2>&1 || {
            cat "$fixture/routing-$mode.log"; exit 1;
        }
        if [[ "$mode" == y ]]; then
            python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials blocked
        else
            python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials
        fi
    done
    for provider in xboxdns geohide comss; do
        curl -fsS "http://$QA_TARGET_GATEWAY:18080/doh-mode/success" >/dev/null
        bash "$repo/script.sh" "${args[@]}" -dns_provider "$provider" > "$fixture/dns-$provider-success.log" 2>&1 || {
            cat "$fixture/dns-$provider-success.log"; exit 1;
        }
        python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials dns-success
        curl -fsS "http://$QA_TARGET_GATEWAY:18080/doh-mode/tlsfail" >/dev/null
        bash "$repo/script.sh" "${args[@]}" -dns_provider "$provider" > "$fixture/dns-$provider.log" 2>&1 || {
            cat "$fixture/dns-$provider.log"; exit 1;
        }
        python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials dns
    done
    for dns_fault in timeout private ru; do
        curl -fsS "http://$QA_TARGET_GATEWAY:18080/doh-mode/$dns_fault" >/dev/null
        ru_mode=n
        if [[ "$dns_fault" == ru ]]; then ru_mode=y; fi
        bash "$repo/script.sh" "${args[@]}" -dns_provider xboxdns -block_ru "$ru_mode" > "$fixture/dns-$dns_fault.log" 2>&1 || {
            cat "$fixture/dns-$dns_fault.log"; exit 1;
        }
        python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials "dns-$dns_fault"
    done
    bash "$repo/script.sh" "${args[@]}" > "$fixture/dns-none.log" 2>&1 || {
        cat "$fixture/dns-none.log"; exit 1;
    }
fi
mkdir "$fixture/artifact-source"
baseline=$(sha256sum /var/lib/vpn-script/config.json /var/lib/vpn-script/owned)
printf '203.0.113.5 qa-bad-dns.test\n' >> /etc/hosts
if bash "$repo/script.sh" "${args[@]}" -subdomain qa-bad-dns.test > "$fixture/bad-dns.log" 2>&1; then exit 1; fi
python3 -m http.server 23333 --bind 0.0.0.0 > "$fixture/foreign-port.log" 2>&1 &
foreign_pid=$!
for attempt in {1..30}; do if ss -Hltn 'sport = :23333' | grep -q .; then break; fi; sleep 0.1; done
if bash "$repo/script.sh" "${args[@]}" -ssh_port 23333 > "$fixture/foreign-listener.log" 2>&1; then exit 1; fi
kill "$foreign_pid"
[[ "$baseline" == "$(sha256sum /var/lib/vpn-script/config.json /var/lib/vpn-script/owned)" && ! -f /var/lib/vpn-script/active ]]
printf 'PASS Wrong DNS and a foreign listener fail before changing deployment\n'
cp -a "$repo/script.sh" "$repo/lib" "$fixture/artifact-source/"
sed -i 's/^LOYAL_GEOIP_SHA256=.*/LOYAL_GEOIP_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' "$fixture/artifact-source/lib/versions.conf"
cat > "$fixture/bin/curl" <<'MOCK'
#!/bin/bash
set -eu
if [[ -f "$QA_SERVICES/bad-artifact" && "$*" == *'/geoip.dat'* ]]; then
    output=""
    while (( $# )); do
        if [[ "$1" == --output || "$1" == -o ]]; then output=$2; shift; fi
        shift
    done
    [[ -n "$output" ]]
    printf 'corrupted QA artifact' > "$output"
    rm "$QA_SERVICES/bad-artifact"
else
    exec /usr/bin/curl "$@"
fi
MOCK
chmod 755 "$fixture/bin/curl"
geo_before=$(sha256sum /usr/local/x-ui/bin/geoip.dat)
touch "$QA_SERVICES/bad-artifact"
if bash "$fixture/artifact-source/script.sh" "${args[@]}" > "$fixture/artifact.log" 2>&1; then exit 1; fi
if [[ -f "$QA_SERVICES/bad-artifact" || -f /var/lib/vpn-script/active ]]; then
    cat "$fixture/artifact.log"
    exit 1
fi
[[ "$geo_before" == "$(sha256sum /usr/local/x-ui/bin/geoip.dat)" ]]
[[ "$first" == "$(sqlite3 /etc/x-ui/x-ui.db 'SELECT id,email,uuid,auth FROM clients ORDER BY id')" ]]
[[ $(sqlite3 /etc/x-ui/x-ui.db 'PRAGMA integrity_check') == ok ]]
bash "$repo/audit.sh" > "$fixture/artifact-audit.log" 2>&1 || { cat "$fixture/artifact.log" "$fixture/artifact-audit.log"; exit 1; }
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials; fi
printf 'PASS Corrupted artifact is rejected before replacing installed assets\n'
for fault in readonly kill; do
    printf '%s\n' "$fault" > "$QA_SERVICES/sqlite-fault"
    if bash "$repo/script.sh" "${args[@]}" > "$fixture/sqlite-$fault.log" 2>&1; then
        printf 'Installer accepted SQLite fault %s\n' "$fault" >&2
        exit 1
    fi
    [[ ! -f "$QA_SERVICES/sqlite-fault" ]]
    if [[ "$fault" == kill ]]; then
        [[ -f /var/lib/vpn-script/active ]]
        # SIGKILL reaps the installer before its injector finishes cleanup. That
        # child inherits fd 9: wait for its completion, not a racing second run.
        # A leaked lock still fails this bounded check; recovery stays mandatory.
        flock -w 5 /var/lib/vpn-script/lock true
        # Recovery must run before the next operation's domain validation.
        if bash "$repo/script.sh" -install n -subdomain invalid -mask_upstream http://127.0.0.1:8000 > "$fixture/recovery.log" 2>&1; then exit 1; fi
    fi
    if [[ -f /var/lib/vpn-script/active ]]; then
        cat "$fixture/sqlite-$fault.log"
        if [[ "$fault" == kill ]]; then cat "$fixture/recovery.log"; fi
        exit 1
    fi
    [[ "$first" == "$(sqlite3 /etc/x-ui/x-ui.db 'SELECT id,email,uuid,auth FROM clients ORDER BY id')" ]]
    [[ $(sqlite3 /etc/x-ui/x-ui.db 'PRAGMA integrity_check') == ok ]]
    bash "$repo/audit.sh" > "$fixture/audit-$fault.log" 2>&1 || { cat "$fixture/sqlite-$fault.log" "$fixture/audit-$fault.log"; exit 1; }
    printf 'PASS SQLite %s fault restores database integrity and live services\n' "$fault"
done
touch "$QA_SERVICES/fail-once"
if bash "$repo/script.sh" "${args[@]}" > "$fixture/failure.log" 2>&1; then
    printf 'Installer accepted a failed service start\n' >&2
    exit 1
fi
if [[ -e /var/lib/vpn-script/active ]]; then
    cat "$fixture/failure.log"
    exit 1
fi
[[ "$first" == "$(sqlite3 /etc/x-ui/x-ui.db 'SELECT id,email,uuid,auth FROM clients ORDER BY id')" ]]
printf 'PASS Failed service start restores the previous database and deployment\n'
bash "$repo/audit.sh" > "$fixture/restored-audit.log" 2>&1 || {
    cat "$fixture/failure.log" "$fixture/restored-audit.log"; exit 1;
}
if [[ "${QA_CLIENT_TESTS:-n}" == y ]]; then python3 "$repo/tests/client-smoke.py" /var/lib/vpn-script/credentials; fi
printf 'PASS Restored services pass the audit and remain reachable\n'
bash "$repo/script.sh" -uninstall y > "$fixture/uninstall.log" 2>&1 || {
    cat "$fixture/uninstall.log"; exit 1;
}
[[ -f /etc/x-ui/x-ui.db && -f /etc/nginx/conf.d/operator.conf && -f /etc/letsencrypt/live/test.example.com/fullchain.pem ]]
[[ ! -f /var/lib/vpn-script/owned && ! -f /var/lib/vpn-script/config.json ]]
printf 'PASS Uninstall preserves database, certificates and operator configuration\n'
