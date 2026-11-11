#!/usr/bin/env bash
# Read-only verification of the deployment committed by vpn-script.
set -u -o pipefail

readonly STATE_DIR=/var/lib/vpn-script
readonly DB=/etc/x-ui/x-ui.db
failed=0
warnings=0

pass() { printf 'PASS %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; ((warnings+=1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; ((failed+=1)); }

if (( EUID != 0 )); then
    fail "Run as root to inspect listening process owners"
    exit 1
fi

if ! config=$(jq -er '
    def port: type == "number" and floor == . and . >= 1 and . <= 65535;
    if (.panel_port | port) and (.xhttp_port | port) and (.hy2_port | port)
        and (.ssh_port | port)
        and (.domain | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]+$"))
        and (.dns_provider | IN("none", "geohide", "xboxdns", "comss"))
        and (.block_ru | IN("y", "n"))
    then [.domain,.panel_port,.xhttp_port,.hy2_port,.ssh_port,.dns_provider,.block_ru] | @tsv
    else error("invalid deployment configuration")
    end' "$STATE_DIR/config.json" 2>/dev/null); then
    fail "Committed deployment configuration is missing or invalid"
    exit 1
fi
IFS=$'\t' read -r domain panel_port xhttp_port hy2_port ssh_port dns_provider block_ru <<< "$config"

check_socket() {
    local label="$1" port="$2" scope="$3" owners="$4" rows="$5"
    if awk -v port="$port" -v scope="$scope" -v owners="$owners" '
        $4 ~ (":" port "$") {
            address = substr($4, 1, length($4) - length(port) - 1)
            if ($0 !~ ("\\(\"(" owners ")\",")) wrong=1
            if (scope == "loopback" && address != "127.0.0.1") wrong=1
            if (scope != "public" || address !~ /^(127\.|\[::1\]$)/) found=1
        }
        END { exit (!found || wrong) }
    ' <<< "$rows"; then
        pass "$label on port $port"
    else
        fail "$label on port $port has a missing, incorrectly bound, or unexpected listener"
    fi
}

if tcp=$(ss -H -ltnp 2>/dev/null) && udp=$(ss -H -lunp 2>/dev/null); then
    check_socket "ACME / HTTP" 80 public nginx "$tcp"
    check_socket "Nginx TLS" 443 public nginx "$tcp"
    check_socket "Hysteria 2" "$hy2_port" public 'xray(-linux-[[:alnum:]]+)?' "$udp"
    check_socket "3X-UI" "$panel_port" loopback x-ui "$tcp"
    check_socket "VLESS xHTTP" "$xhttp_port" loopback 'xray(-linux-[[:alnum:]]+)?' "$tcp"
    if reality_ports=$(jq -er '.inbounds | [.self_raw.port,.self_xhttp.port,.classic_raw.port,.classic_xhttp.port] | if all(.[]; type == "number" and . >= 1024 and . <= 65535 and floor == .) then .[] else error("invalid ports") end' "$STATE_DIR/config.json"); then
        while IFS= read -r port; do
            check_socket "REALITY" "$port" loopback 'xray(-linux-[[:alnum:]]+)?' "$tcp"
        done <<< "$reality_ports"
    else
        fail "Missing or invalid REALITY listener registry"
    fi
    check_socket "SSH" "$ssh_port" any 'sshd|systemd' "$tcp"
    if [[ -f "$STATE_DIR/ssh-pending" ]]; then
        warn "SSH port change is awaiting confirmation"
    fi
else
    fail "Cannot inspect TCP and UDP sockets"
fi

if [[ $(stat -c '%a %u' "$STATE_DIR" 2>/dev/null) == '700 0' &&
      $(stat -c '%a %u' "$STATE_DIR/config.json" 2>/dev/null) == '600 0' &&
      $(stat -c '%a %u' /etc/x-ui 2>/dev/null) == '700 0' &&
      $(stat -c '%a %u' "$DB" 2>/dev/null) == '600 0' ]]; then
    pass "Deployment state and database permissions"
else
    fail "Deployment state or database permissions"
fi

if settings=$(sqlite3 -batch -bail -readonly "$DB" "
    SELECT count(*) = 1 AND min(value) = '127.0.0.1'
      FROM settings WHERE key = 'webListen';
    SELECT count(*) = 1 AND min(value) = 'false'
      FROM settings WHERE key = 'subEnable';
    SELECT count(*) = 1 AND min(listen) = '127.0.0.1'
      FROM inbounds WHERE enable = 1 AND protocol = 'vless' AND port = $xhttp_port;
" 2>/dev/null) && [[ "$settings" == $'1\n1\n1' ]]; then
    pass "Panel and xHTTP bindings, disabled subscriptions"
else
    fail "Cannot verify unique loopback settings and disabled subscriptions"
fi

check_credentials() (
    umask 077
    local_db=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$local_db"' EXIT
    # The panel CLI migrates the database even when showing settings.
    sqlite3 -batch -bail -readonly "$DB" ".backup '$local_db/x-ui.db'" || exit 1
    cd -- "$local_db" || exit 1
    panel=$(XUI_DB_FOLDER="$local_db" XUI_DB_TYPE=sqlite /usr/local/x-ui/x-ui setting -show) || exit 1
    grep -Eiq '^hasDefaultCredential:[[:space:]]*false[[:space:]]*$' <<< "$panel"
)
if check_credentials 2>/dev/null; then
    pass "Panel has no standard administrator credentials"
else
    fail "Standard panel credentials are present or could not be checked"
fi

if python3 - "$DB" "$xhttp_port" "$block_ru" "$dns_provider" <<'PY' >/dev/null 2>&1
import copy
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, "/usr/local/lib/vpn-script")
from xray_config import configure_routes, all_managed_inbounds
from reality import audit, audit_runtime

database, port, block_ru, provider = sys.argv[1:]
with sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True) as db:
    rows = db.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchall()
    assert len(rows) == 1
    actual = json.loads(rows[0][0])
    expected = copy.deepcopy(actual)
    audit(db, json.loads(Path('/var/lib/vpn-script/config.json').read_text()))
    audit_runtime(db)
    tags = [row[1] for row in all_managed_inbounds(db, int(port))]
    configure_routes(expected, tags, block_ru == "y", provider, False)
    assert actual == expected
PY
then
    pass "Managed routing and DNS match the committed configuration"
else
    fail "Managed routing or DNS differs from the committed configuration"
fi

for unit in nginx x-ui fail2ban; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        pass "$unit is active"
    else
        fail "$unit is inactive or its status is unavailable"
    fi
done

if nginx -t >/dev/null 2>&1; then
    pass "Nginx configuration"
else
    fail "Nginx configuration check failed"
fi

if curl --noproxy '*' --max-time 5 --silent --output /dev/null \
    --resolve "$domain:443:127.0.0.1" "https://$domain/" 2>/dev/null; then
    pass "HTTPS with trusted certificate"
else
    fail "HTTPS certificate or connection check failed"
fi
if certificate=$(sqlite3 -batch -bail -readonly "$DB" \
    "SELECT json_extract(stream_settings,'\$.tlsSettings.certificates[0].certificateFile') FROM inbounds WHERE enable=1 AND protocol IN ('hysteria','hysteria2') AND port=$hy2_port;" 2>/dev/null) &&
   [[ -n "$certificate" ]] &&
   /usr/bin/python3 /usr/local/lib/vpn-script/certificate_probe.py "$domain" "$certificate" >/dev/null 2>&1; then
    pass "TCP and QUIC serve the configured certificate"
else
    fail "TCP or QUIC certificate does not match the configured certificate"
fi

if [[ "$dns_provider" == none ]]; then
    pass "Standard Xray DNS (DNS profile disabled)"
else
    case "$dns_provider" in
        xboxdns) doh=https://xbox-dns.ru/dns-query ;;
        geohide) doh=https://eu.geohide.ru/dns-query ;;
        comss) doh=https://dns.comss.one/dns-query ;;
    esac
    # A fixed example.com DNS wire query avoids logging or forwarding client domains.
    if curl --noproxy '*' --max-time 5 --fail --silent --output /dev/null \
        -H 'Accept: application/dns-message' \
        "$doh?dns=AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE" 2>/dev/null; then
        pass "DNS profile $dns_provider is reachable"
    else
        warn "DNS profile $dns_provider is unavailable; ordinary DNS fallback is configured"
    fi
fi
printf 'RU-Block configured mode: %s\n' "$block_ru"
printf 'Audit summary: %d failure(s), %d warning(s)\n' "$failed" "$warnings"
(( failed == 0 ))
