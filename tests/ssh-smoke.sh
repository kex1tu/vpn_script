#!/usr/bin/env bash
# Real sshd and authenticated sessions with a simulated systemd/UFW adapter.
set -Eeuo pipefail
[[ -f /.dockerenv ]]
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'jobs -pr | xargs -r kill; rm -rf -- "$fixture"' EXIT
trap 'printf "SSH smoke failed at line %s\n" "$LINENO" >&2' ERR
mkdir "$fixture/bin"
export QA_SSH_FIXTURE="$fixture"
cat > "$fixture/bin/systemctl" <<'MOCK'
#!/bin/bash
set -eu
exec 9>&-
unit=${!#}; unit=${unit%.service}
if [[ ( "$1" == reload || "$1" == start ) && -f "$QA_SSH_FIXTURE/fail-service" ]]; then
    rm "$QA_SSH_FIXTURE/fail-service"
    exit 1
fi
case "$1" in
    daemon-reload|enable|disable) exit 0 ;;
    show)
        case "$*" in
            *KillMode*) echo process ;;
            *Listen*) sshd -T | awk '$1=="port" {print "[::]:" $2 " (Stream)"}' ;;
            *) echo loaded ;;
        esac ;;
    is-active)
        case "$unit" in
            ssh.socket) [[ "${QA_SSH_MODE:-service}" == socket ]] ;;
            ssh) [[ -s /run/sshd.pid ]] && kill -0 "$(cat /run/sshd.pid)" ;;
            vpn-script-ssh-rollback.timer) exit 0 ;;
            *) exit 1 ;;
        esac ;;
    stop) if [[ "$unit" == ssh && -s /run/sshd.pid ]]; then kill "$(cat /run/sshd.pid)"; sleep 0.2; fi ;;
    reload) kill -HUP "$(cat /run/sshd.pid)" ;;
    start) /usr/sbin/sshd ;;
    *) exit 2 ;;
esac
MOCK
cat > "$fixture/bin/ufw" <<'MOCK'
#!/bin/bash
set -eu
case "$1" in
    show) cat "$QA_SSH_FIXTURE/rules" ;;
    allow)
        if [[ -f "$QA_SSH_FIXTURE/fail-ufw" ]]; then rm "$QA_SSH_FIXTURE/fail-ufw"; exit 1; fi
        printf "ufw allow %s comment '%s'\n" "$2" "$4" >> "$QA_SSH_FIXTURE/rules" ;;
    --force)
        grep -Fvx "ufw allow $4 comment '$6'" "$QA_SSH_FIXTURE/rules" > "$QA_SSH_FIXTURE/rules.new" || :
        mv "$QA_SSH_FIXTURE/rules.new" "$QA_SSH_FIXTURE/rules" ;;
    *) exit 2 ;;
esac
MOCK
chmod 755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
install -d -m 700 /var/lib/vpn-script /root/.ssh
install -d -m 755 /run/sshd /usr/local/lib/vpn-script
cp "$repo/script.sh" /usr/local/sbin/vpn-script
chmod 755 /usr/local/sbin/vpn-script
cp "$repo/lib/"* /usr/local/lib/vpn-script/
ssh-keygen -A >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$fixture/key"
cp "$fixture/key.pub" /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
source "$repo/lib/deployment.sh"
source "$repo/lib/ssh.sh"
export QA_SSH_MODE
for QA_SSH_MODE in service socket; do
    printf "ufw allow 22/tcp comment 'vpn-script-ssh'\n" > "$fixture/rules"
    rm -f "$SSH_MANAGED_CONFIG"
    /usr/sbin/sshd
    printf '{"ssh_port":22}\n' > "$STATE_DIR/config.json"
    chmod 600 "$STATE_DIR/config.json"
    deployment_lock
    for fault in ufw service; do
        touch "$fixture/fail-$fault"
        if ssh_migration_setup 60022; then
            printf 'SSH accepted injected %s failure\n' "$fault" >&2
            exit 1
        fi
        [[ ! -f "$STATE_DIR/ssh-pending" && -z $(ssh_listeners 60022) ]]
        ssh_port_is_listening 22
        printf 'PASS SSH %s failure preserves the old listener\n' "$fault"
    done
    ssh_migration_setup 60022
    [[ -f "$STATE_DIR/ssh-pending" ]]
    ssh_check_ports 22 60022
    if SSH_CONNECTION='127.0.0.1 1234 127.0.0.1 60022' ssh_migration_confirm; then
        printf 'Unauthenticated confirmation succeeded\n' >&2
        exit 1
    fi
    exec 9>&-
    ssh -i "$fixture/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 60022 root@127.0.0.1 \
        "PATH='$fixture/bin':\$PATH QA_SSH_FIXTURE='$fixture' QA_SSH_MODE='$QA_SSH_MODE' /usr/local/sbin/vpn-script -ssh_confirm y"
    [[ ! -f "$STATE_DIR/ssh-pending" ]]
    [[ $(jq .ssh_port "$STATE_DIR/config.json") == 60022 ]]
    ssh_port_is_listening 60022
    [[ -z $(ssh_listeners 22) ]]
    deployment_lock
    ssh_migration_setup 60023
    awk '{$5=1; print}' "$STATE_DIR/ssh-pending" > "$fixture/expired"
    mv "$fixture/expired" "$STATE_DIR/ssh-pending"
    ssh_migration_rollback_expired
    [[ ! -f "$STATE_DIR/ssh-pending" && -z $(ssh_listeners 60023) ]]
    ssh_port_is_listening 60022
    exec 9>&-
    kill "$(cat /run/sshd.pid)"
    sleep 0.2
    printf 'PASS SSH %s adapter confirms a real new login, rejects forged confirmation and restores expired changes\n' "$QA_SSH_MODE"
done
