#!/bin/bash

if [[ ! -f /.dockerenv ]]; then
    printf 'Run this suite inside Docker. It writes to container system paths.\n' >&2
    exit 1
fi

PASS=0
FAIL=0

pass() { printf 'PASS %s\n' "$1"; ((PASS+=1)); }
fail() { printf 'FAIL %s\n' "$1"; ((FAIL+=1)); }

# Exercise the installer and helpers with real service binaries. Tests with
# simulated service management are labeled separately from runtime checks.
# --- Deployment behavior ---
QA_ROOT=$(mktemp -d) || exit 1
QA_INSTALLER="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/script.sh"
QA_DEPLOYMENT="$(dirname "$QA_INSTALLER")/lib/deployment.sh"
trap 'rm -rf -- "$QA_ROOT"' EXIT

run_behavior_test() {
    local label="$1" check="$2" status
    (
        set -Eeuo pipefail
        trap 'printf "Failed assertion at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR
        "$check"
    ) > "$QA_ROOT/$check.log" 2>&1
    status=$?
    if (( status == 0 )); then
        pass "$label"
    else
        cat "$QA_ROOT/$check.log"
        fail "$label"
    fi
}

expect_failure() {
    if "$@"; then
        printf 'Expected a failure from %s\n' "$1" >&2
        return 1
    fi
}

test_deployment_lock() {
    source "$QA_DEPLOYMENT"
    STATE_DIR="$QA_ROOT/lock"
    deployment_lock
    expect_failure bash -eu -c 'source "$1"; STATE_DIR="$2"; deployment_lock' \
        _ "$QA_DEPLOYMENT" "$STATE_DIR" 9>&-
    exec 9>&-
    bash -eu -c 'source "$1"; STATE_DIR="$2"; deployment_lock' \
        _ "$QA_DEPLOYMENT" "$STATE_DIR"
}

test_deployment_rollback() {
    source "$QA_DEPLOYMENT"
    local fixture="$QA_ROOT/rollback" writer_pid
    STATE_DIR="$fixture/state"
    XUIDB="$fixture/db/x-ui.db"
    mkdir -p "$fixture/db"

    # Keep the SQLite writer open so the committed row stays in the WAL.
    python3 - "$XUIDB" "$fixture" <<'PY' &
from pathlib import Path
import sqlite3
import sys
import time

database, fixture = sys.argv[1:]
connection = sqlite3.connect(database)
connection.execute("PRAGMA journal_mode=WAL")
connection.execute("PRAGMA wal_autocheckpoint=0")
connection.execute("CREATE TABLE clients (name TEXT)")
connection.execute("INSERT INTO clients VALUES ('existing-client')")
connection.commit()
Path(fixture, "ready").touch()
for _ in range(200):
    if Path(fixture, "release").exists():
        break
    time.sleep(0.05)
connection.close()
PY
    writer_pid=$!
    trap 'kill "$writer_pid" 2>/dev/null || true' EXIT
    for _ in {1..100}; do
        [[ -f "$fixture/ready" ]] && break
        sleep 0.05
    done
    [[ -f "$fixture/ready" && -s "$XUIDB-wal" ]]

    # Exercise real backups/restoration. The container has no systemd PID 1.
    systemctl() {
        case "$1" in
            show) printf 'not-found\n' ;;
            is-active|is-enabled) return 1 ;;
            daemon-reload)
                if [[ -f "$fixture/fail-rollback" ]]; then rm "$fixture/fail-rollback"; return 1; fi
                return 0 ;;
            *) return 2 ;;
        esac
    }
    printf 'existing nginx\n' > "$fixture/nginx.conf"
    ln -s nginx.conf "$fixture/linked.conf"
    printf 'foreign nginx\n' > "$fixture/foreign.conf"
    deployment_lock
    deployment_begin "$fixture/nginx.conf" "$fixture/linked.conf" "$fixture/new.conf"
    [[ "$(deployment_active)" == "$DEPLOYMENT" ]]
    [[ "$(stat -c %a "$DEPLOYMENT/x-ui.db")" == 600 ]]
    [[ "$(sqlite3 "$DEPLOYMENT/x-ui.db" 'SELECT name FROM clients')" == existing-client ]]
    touch "$fixture/release"
    wait "$writer_pid"
    trap - EXIT

    deployment_prepare_database
    sqlite3 -bail "$XUIDB" "UPDATE clients SET name = 'broken'"
    printf 'new nginx\n' > "$fixture/nginx.conf"
    rm "$fixture/linked.conf"
    printf 'new file\n' > "$fixture/new.conf"
    deployment_rollback "$DEPLOYMENT"
    [[ ! -e "$STATE_DIR/active" && ! -e "$fixture/new.conf" ]]
    [[ "$(cat "$fixture/nginx.conf")" == 'existing nginx' ]]
    [[ "$(readlink "$fixture/linked.conf")" == nginx.conf ]]
    [[ "$(cat "$fixture/foreign.conf")" == 'foreign nginx' ]]
    [[ "$(sqlite3 "$XUIDB" 'SELECT name FROM clients')" == existing-client ]]
    [[ "$(sqlite3 "$XUIDB" 'PRAGMA integrity_check')" == ok ]]
    deployment_begin "$fixture/nginx.conf"
    deployment_prepare_database
    sqlite3 -bail "$XUIDB" "UPDATE clients SET name = 'interrupted'"
    touch "$fixture/fail-rollback"
    expect_failure deployment_rollback "$DEPLOYMENT"
    [[ -f "$STATE_DIR/active" && -f "$DEPLOYMENT/x-ui.db" ]]
    [[ "$(sqlite3 "$DEPLOYMENT/x-ui.db" 'PRAGMA integrity_check')" == ok ]]
    cp -- "$DEPLOYMENT/x-ui.db" "$fixture/good-snapshot"
    printf 'corrupt snapshot\n' > "$DEPLOYMENT/x-ui.db"
    expect_failure deployment_rollback "$DEPLOYMENT"
    [[ -f "$STATE_DIR/active" ]]
    [[ "$(sqlite3 "$XUIDB" 'SELECT name FROM clients')" == existing-client ]]
    mv -- "$fixture/good-snapshot" "$DEPLOYMENT/x-ui.db"
    deployment_rollback "$DEPLOYMENT"
    [[ ! -f "$STATE_DIR/active" && "$(sqlite3 "$XUIDB" 'SELECT name FROM clients')" == existing-client ]]

    # Model an inbound and a temporary outbound UDP socket of the same core.
    # Requiring the outbound source port after restart makes recovery impossible.
    local runtime=/usr/local/x-ui/bin/config.json
    if [[ -f "$runtime" ]]; then cp -a "$runtime" "$fixture/runtime.original"; fi
    trap 'if [[ -f "$QA_ROOT/rollback/runtime.original" ]]; then cp -a "$QA_ROOT/rollback/runtime.original" /usr/local/x-ui/bin/config.json; else rm -f /usr/local/x-ui/bin/config.json; fi' EXIT
    printf '{"inbounds":[{"port":443}]}' > "$runtime"
    ss() {
        if [[ "$*" == *-lunp* ]]; then
            printf '%s\n' \
                'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=1,fd=1))' \
                'UNCONN 0 0 0.0.0.0:54121 0.0.0.0:* users:(("xray",pid=1,fd=2))'
        fi
    }
    deployment_begin "$fixture/nginx.conf"
    [[ "$(cat "$DEPLOYMENT/listeners")" == 'u 443 xray' ]]
}

test_preflight() {
    local output before after state="$QA_ROOT/preflight"
    local -a args=(-dry_run y -install n -subdomain vpn.qa.test \
        -public_ip4 192.0.2.10 -ssh_port 22 -mask_upstream http://127.0.0.1:8000)
    mkdir -p "$state"
    cp /etc/hosts "$state/hosts.original"
    trap 'cat "$QA_ROOT/preflight/hosts.original" > /etc/hosts; rm -f /etc/x-ui/x-ui.db /etc/nginx/conf.d/qa-foreign.conf' EXIT
    printf '192.0.2.10 vpn.qa.test\n' >> /etc/hosts
    printf '# foreign nginx configuration\n' > /etc/nginx/conf.d/qa-foreign.conf
    rm -f /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
    XUI_DB_FOLDER=/etc/x-ui /usr/local/x-ui/x-ui migrate
    before=$(sha256sum /etc/nginx/nginx.conf /etc/nginx/conf.d/qa-foreign.conf /etc/x-ui/x-ui.db)

    output=$(bash "$QA_INSTALLER" "${args[@]}")
    grep -Fq 'Preflight passed for vpn.qa.test' <<< "$output"
    grep -Eq 'Legacy adoption token: [0-9a-f]{64}$' <<< "$output"
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -not-an-option y
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -mask_upstream 'http://127.0.0.1:8000; include /tmp/bad'
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -mask_upstream http://127.0.0.1:80
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -mask_upstream 'http://[::ffff:7f00:1]:80'
    bash "$QA_INSTALLER" "${args[@]}" -mask_upstream http://127.0.0.1 -mask_port 8123 \
        -xhttp_config_path /root/test-xhttp.json -xhttp_download_path /downloads/xhttp.json
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -mask_port 65536
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -mask_port 9443
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -xhttp_download_path '/x;bad'
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -xhttp_config_path /root/../etc/xhttp.json
    expect_failure bash "$QA_INSTALLER" "${args[@]}" -xhttp_config_path /tmp/xhttp.json
    after=$(sha256sum /etc/nginx/nginx.conf /etc/nginx/conf.d/qa-foreign.conf /etc/x-ui/x-ui.db)
    [[ "$before" == "$after" && ! -e /var/lib/vpn-script ]]
    mv /etc/x-ui/x-ui.db "$state/original.db"
    ln -s "$state/original.db" /etc/x-ui/x-ui.db
    expect_failure bash "$QA_INSTALLER" "${args[@]}"
    [[ -L /etc/x-ui/x-ui.db ]]
    rm -f /etc/x-ui/x-ui.db
    cp "$state/original.db" /etc/x-ui/x-ui.db

    # Preflight verifies installed panel version even in dry-run
    cp /usr/local/x-ui/x-ui "$state/x-ui.orig"
    cat > /usr/local/x-ui/x-ui <<'MOCK'
#!/bin/sh
echo "3x-ui 99.0.0"
MOCK
    chmod +x /usr/local/x-ui/x-ui
    output=$(bash "$QA_INSTALLER" "${args[@]}" 2>&1 || true)
    cp "$state/x-ui.orig" /usr/local/x-ui/x-ui
    grep -Fq 'Installed panel is newer than the supported release' <<< "$output"
}

test_syntax_and_openssh() {
    bash -n "$QA_INSTALLER" "$QA_DEPLOYMENT" "$(dirname "$QA_INSTALLER")/lib/ssh.sh"
    install -d /run/sshd
    printf 'Port 60022\n' > "$QA_ROOT/sshd.conf"
    /usr/sbin/sshd -t -f "$QA_ROOT/sshd.conf"
    printf 'Port 65536\n' > "$QA_ROOT/sshd.conf"
    expect_failure /usr/sbin/sshd -t -f "$QA_ROOT/sshd.conf"
}

test_xray_routing_and_links() {
    local fixture="$QA_ROOT/xray" xray_dir=/usr/local/x-ui/bin
    mkdir -p "$fixture"
    XUI_DB_FOLDER="$fixture" /usr/local/x-ui/x-ui migrate
    XRAY_LOCATION_ASSET="$xray_dir" python3 - "$fixture" \
        "$(dirname "$QA_INSTALLER")/lib/xray_config.py" "$xray_dir/xray-linux-$(dpkg --print-architecture)" <<'PY'
import json
import sqlite3
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

fixture, helper, xray = sys.argv[1:]
database = str(Path(fixture) / "x-ui.db")
config_file = Path(fixture) / "config.json"
with sqlite3.connect(database) as db:
    for protocol, port, tag, settings, stream in (
        ("vless", 24680, "test-vless", {"encryption": "none"}, {"network": "xhttp", "xhttpSettings": {
            "path": "/qa/xhttp/", "mode": "stream-one", "xPaddingHeader": "X-Demo-Guard",
            "xPaddingPlacement": "header",
        }}),
        ("hysteria", 443, "test-hy2", {"version": 2}, {"network": "hysteria", "tlsSettings": {
            "serverName": "vpn.qa.test",
        }}),
    ):
        db.execute("INSERT INTO inbounds (enable,protocol,port,tag,settings,stream_settings) VALUES (1,?,?,?,?,?)",
                   (protocol, port, tag, json.dumps(settings), json.dumps(stream)))
    db.execute("INSERT INTO clients (email,uuid,auth,enable,expiry_time) VALUES (?,?,?,?,?)",
               ("vless-test", "11111111-1111-4111-8111-111111111111", "", 1, 0))
    db.execute("INSERT INTO clients (email,uuid,auth,enable,expiry_time) VALUES (?,?,?,?,?)",
               ("hy2-test", "", "qa:#%@ secret", 1, 0))
    db.execute("INSERT INTO client_inbounds (client_id,inbound_id) VALUES (1,1),(2,2)")
    db.commit()

    def template():
        [row] = db.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchall()
        return json.loads(row[0])

    def routing(ru, provider, expected=0):
        proc = subprocess.run([sys.executable, helper, "routing", database, "24680", ru, provider, "n"],
                              text=True, capture_output=True)
        assert proc.returncode == expected, proc.stderr
        return proc.stderr

    for provider in ("none", "xboxdns", "geohide", "comss", "none"):
        for ru in ("y", "n"):
            routing(ru, provider)
            config = template()
            tags = {rule["ruleTag"] for rule in config["routing"]["rules"] if "ruleTag" in rule}
            assert {"vpn-script:private", "vpn-script:direct"} <= tags
            assert ("vpn-script:ru-domains" in tags) == (ru == "y")
            assert ("vpn-script:ru-ip" in tags) == (ru == "y")
            for rule in config["routing"]["rules"]:
                if rule.get("ruleTag", "").startswith("vpn-script:ru-"):
                    assert not ("domain" in rule and "ip" in rule)
            servers = config.get("dns", {}).get("servers", [])
            managed = [s for s in servers if isinstance(s, dict) and s.get("tag") == "vpn-script-doh"]
            assert len(managed) == (provider != "none")
            if managed:
                assert managed[0]["domains"] and managed[0]["skipFallback"]
                assert any(isinstance(server, str) for server in servers)
            config_file.write_text(json.dumps(config))
            subprocess.run([xray, "run", "-test", "-c", str(config_file)], check=True)
            routing(ru, provider)
            assert config == template()

    config = template()
    config["routing"]["rules"].append({"type": "field", "network": "tcp", "outboundTag": "direct"})
    db.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
    db.commit()
    assert "custom Xray route" in routing("y", "none", expected=1)
    assert config == template()

links = subprocess.check_output([sys.executable, helper, "links", database, "vpn.qa.test", "24680"], text=True)
vless, hy2 = map(urlsplit, links.splitlines())
assert unquote(vless.username) == "11111111-1111-4111-8111-111111111111"
vless_query = parse_qs(vless.query)
assert vless_query["path"] == ["/qa/xhttp/"] and vless_query["mode"] == ["stream-one"]
assert json.loads(vless_query["extra"][0])["xPaddingHeader"] == "X-Demo-Guard"
assert unquote(hy2.username) == "qa:#%@ secret" and parse_qs(hy2.query)["sni"] == ["vpn.qa.test"]
PY
}

test_audit_listener_failure() {
    local audit="$(dirname "$QA_INSTALLER")/audit.sh" output
    install -d -m 700 /var/lib/vpn-script "$QA_ROOT/mock-bin"
    install -m 600 /dev/null /var/lib/vpn-script/config.json
    printf '%s\n' '{"domain":"vpn.qa.test","panel_port":2096,"xhttp_port":31337,"hy2_port":443,"ssh_port":22,"dns_provider":"none","block_ru":"n"}' \
        > /var/lib/vpn-script/config.json
    cat > "$QA_ROOT/mock-bin/ss" <<'SH'
#!/bin/sh
if [ "${QA_SS_UNAVAILABLE:-0}" = 1 ]; then exit 2; fi
if [ "$2" = '-ltnp' ]; then
    printf '%s\n' 'LISTEN 0 128 0.0.0.0:2096 0.0.0.0:* users:(("x-ui",pid=42,fd=9))'
fi
SH
    chmod 755 "$QA_ROOT/mock-bin/ss"
    export PATH="$QA_ROOT/mock-bin:$PATH"
    if output=$(bash "$audit" 2>&1); then
        printf 'Audit succeeded despite an exposed panel and missing sockets\n' >&2
        return 1
    fi
    grep -Fq 'FAIL 3X-UI on port 2096' <<< "$output"
    grep -Fq 'FAIL VLESS xHTTP on port 31337' <<< "$output"
    if output=$(QA_SS_UNAVAILABLE=1 bash "$audit" 2>&1); then
        printf 'Audit succeeded despite unavailable socket status\n' >&2
        return 1
    fi
    grep -Fq 'FAIL Cannot inspect TCP and UDP sockets' <<< "$output"
}

test_reality_contract() {
    python3 "$(dirname "$QA_INSTALLER")/tests/reality-contract.py"
}

test_legacy_resource_recognition() {
    source "$QA_DEPLOYMENT"
    local fixture="$QA_ROOT/legacy-test"
    domain="vpn.qa.test"
    mkdir -p "$fixture/jail.d" "$fixture/nginx.service.d" "$fixture/stream-enabled"

    # 1. fail2ban with iptables-allports
    local f2b="/etc/fail2ban/jail.d/99-sshd.local"
    install -d -m 755 /etc/fail2ban/jail.d
    trap 'rm -f /etc/fail2ban/jail.d/99-sshd.local /etc/systemd/system/nginx.service.d/vpn-script.conf /etc/nginx/stream-enabled/stream.conf' EXIT
    printf 'banaction = iptables-allports\nfindtime  = 600\n' > "$f2b"
    legacy_resource "$f2b"
    printf 'banaction = ufw\nfindtime  = 600\n' > "$f2b"
    legacy_resource "$f2b"

    # 2. systemd drop-in with vpn-script.conf
    local dropin="/etc/systemd/system/nginx.service.d/vpn-script.conf"
    install -d -m 755 /etc/systemd/system/nginx.service.d
    printf '[Service]\nLimitNOFILE=65535' > "$dropin"
    legacy_resource "$dropin"

    # 3. stream.conf with upstream www
    local stream_conf="/etc/nginx/stream-enabled/stream.conf"
    install -d -m 755 /etc/nginx/stream-enabled
    printf 'upstream www { server 127.0.0.1:80; }\nproxy_pass /dev/shm/nginx-http.sock;\n' > "$stream_conf"
    legacy_resource "$stream_conf"
}

test_ssh_socket_listener_check() {
    source "$QA_DEPLOYMENT"
    ss() {
        printf '%s\n' 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=42))'
    }
    expect_failure check_listener 22 t available sshd
    check_listener 22 t available "sshd|systemd"
    ss() { return 1; }
    expect_failure check_listener 22 t available sshd
    ss() {
        printf '%s\n' 'LISTEN 0 128 127.0.0.1:12345 0.0.0.0:* users:(("xray-foreign",pid=1,fd=42))'
    }
    expect_failure check_listener 12345 t loopback xray
    ss() {
        printf '%s\n' 'LISTEN 0 128 127.0.0.1:12345 0.0.0.0:* users:(("xray-linux-amd6",pid=1,fd=42))'
    }
    check_listener 12345 t loopback xray
}

test_startup_interrupted_rollback_reporting() {
    local fixture="$QA_ROOT/startup-rollback" output
    mkdir -p "$fixture/state/transaction.qa12345/files"
    printf 'transaction.qa12345\n' > "$fixture/state/active"
    printf 'corrupt-sqlite' > "$fixture/state/transaction.qa12345/x-ui.db"
    touch "$fixture/state/transaction.qa12345/database-write"
    touch "$fixture/state/transaction.qa12345/paths"
    touch "$fixture/state/transaction.qa12345/services"
    output=$(STATE_DIR="$fixture/state" bash "$QA_INSTALLER" -install n -mask_upstream http://127.0.0.1:8000 -subdomain vpn.qa.test 2>&1 || true)
    grep -Fq "Rollback incomplete. Recovery data: $fixture/state/transaction.qa12345" <<< "$output"
}

test_xhttp_migration_no_empty_headers() {
    local fixture="$QA_ROOT/xhttp-headers"
    local db="$fixture/x-ui.db"
    mkdir -p "$fixture"
    python3 - "$db" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, protocol TEXT, enable INTEGER, port INTEGER, stream_settings TEXT, settings TEXT, listen TEXT)")
conn.execute("CREATE TABLE settings (key TEXT, value TEXT)")
conn.execute("INSERT INTO inbounds VALUES (1, 'vless', 1, 12345, ?, '{}', '0.0.0.0')",
             (json.dumps({"network": "xhttp", "xhttpSettings": {"path": "/old/path/"}}),))
conn.execute("INSERT INTO inbounds VALUES (2, 'hysteria', 1, 443, ?, ?, '0.0.0.0')",
             (json.dumps({"network": "hysteria", "tlsSettings": {}, "hysteriaSettings": {}}),
              json.dumps({"version": 2})))
conn.commit()
PY

    python3 - "$db" "12345" "/new/path/" "" "" "" "" "vpn.qa.test" "/tmp" "http://127.0.0.1:8000" <<'PYTHON'
import json, sqlite3, sys
db, port, path, pad_key, pad_header, session_key, seq_key, domain, cert_dir, mask = sys.argv[1:]
with sqlite3.connect(db) as conn:
    conn.execute("BEGIN IMMEDIATE")
    vless, = conn.execute(
        "SELECT id, stream_settings FROM inbounds WHERE protocol='vless' AND enable=1 "
        "AND port=? AND json_extract(stream_settings,'$.network')='xhttp'", (port,)
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
    conn.execute("UPDATE inbounds SET listen='127.0.0.1', stream_settings=? WHERE id=?",
                 (json.dumps(vless_stream), vless[0]))
PYTHON

    python3 - "$db" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
stream = json.loads(conn.execute("SELECT stream_settings FROM inbounds WHERE id=1").fetchone()[0])
xhttp = stream["xhttpSettings"]
assert xhttp["path"] == "/new/path/"
for key in ("xPaddingKey", "xPaddingHeader", "sessionIDKey", "seqKey"):
    assert key not in xhttp or xhttp[key] != "", f"Empty key {key} present in xhttpSettings"
PY
}

test_credentials_preservation_on_repeat() {
    local fixture="$QA_ROOT/creds-test"
    mkdir -p "$fixture/state" "$fixture/deployment/files"
    local state_dir="$fixture/state"
    local deployment="$fixture/deployment"
    local xuidb="$fixture/x-ui.db"
    python3 - "$xuidb" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
conn.execute("INSERT INTO users VALUES (1, 'myuser', 'hash')")
conn.commit()
PY
    printf 'Panel URL: https://vpn.test/secret/\nUsername: myuser\nPassword: mysecretpassword\nvless://...\n' \
        > "$state_dir/credentials"
    chmod 600 "$state_dir/credentials"

    local config_username="" config_password="" domain="vpn.test" panel_path="secret" links="vless://mock"
    (
        STATE_DIR="$state_dir"
        DEPLOYMENT="$deployment"
        XUIDB="$xuidb"
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
            printf '%s\n' "$links"
        } > "$STATE_DIR/credentials.new"
        mv -f -- "$STATE_DIR/credentials.new" "$STATE_DIR/credentials"
    )

    grep -Fxq 'Username: myuser' "$state_dir/credentials"
    grep -Fxq 'Password: mysecretpassword' "$state_dir/credentials"
    [[ "$(stat -c %a "$state_dir/credentials")" == 600 ]]
}

run_behavior_test "Deployment lock rejects concurrent writes and releases cleanly" test_deployment_lock
run_behavior_test "Rollback restores WAL-backed SQLite, original files and symlinks" test_deployment_rollback
run_behavior_test "Installer and helper syntax, real sshd config validation" test_syntax_and_openssh
run_behavior_test "Preflight detects adoption and rejects invalid upstream without writing" test_preflight
run_behavior_test "Xray validates provider transitions, independent RU rules, and actual client exports" test_xray_routing_and_links
run_behavior_test "Audit fails for exposed or missing sockets and unavailable ss" test_audit_listener_failure
run_behavior_test "REALITY additive migration preserves identities, counters and keys" test_reality_contract
run_behavior_test "Legacy resource recognizes iptables-allports, vpn-script drop-ins, and legacy stream" test_legacy_resource_recognition
run_behavior_test "SSH listener check accepts ssh.socket systemd listeners" test_ssh_socket_listener_check
run_behavior_test "Interrupted rollback failure reports incomplete recovery data on startup" test_startup_interrupted_rollback_reporting
run_behavior_test "xHTTP inbound migration prevents writing empty header keys" test_xhttp_migration_no_empty_headers
run_behavior_test "Credentials file preserves existing Username and Password on repeat deploy" test_credentials_preservation_on_repeat

# --- Summary ---
echo ""
echo "=============================================="
echo "  TEST RESULTS: ${PASS} passed, ${FAIL} failed, $((PASS + FAIL)) total"
echo "=============================================="

if [ $FAIL -gt 0 ]; then
    exit 1
else
    exit 0
fi
