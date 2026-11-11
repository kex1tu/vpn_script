#!/usr/bin/env bash
# Runs only in a disposable Docker container with genuine systemd PID 1.
set -Eeuo pipefail
[[ -f /.dockerenv && $(cat /proc/1/comm) == systemd ]]
source /usr/local/lib/vpn-script/deployment.sh
source /usr/local/lib/vpn-script/ssh.sh
case "$1" in
    prepare)
        install -d -m 700 /var/lib/vpn-script /root/.ssh
        install -d -m 755 /run/sshd
        ssh-keygen -A
        systemctl stop ssh.socket ssh.service
        systemctl disable ssh.socket ssh.service
        rm -f "$SSH_MANAGED_CONFIG" /tmp/qa-key /tmp/qa-key.pub
        ssh-keygen -q -t ed25519 -N '' -f /tmp/qa-key
        cp /tmp/qa-key.pub /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        printf '{"ssh_port":22}\n' > "$STATE_DIR/config.json"
        chmod 600 "$STATE_DIR/config.json"
        ufw allow 22/tcp comment vpn-script-ssh
        if [[ "$2" == socket ]]; then
            systemctl enable --now ssh.socket
        else
            systemctl enable --now ssh.service
        fi
        ;;
    stage)
        deployment_lock
        ssh_migration_setup "$2"
        ssh_check_ports "$(jq .ssh_port "$STATE_DIR/config.json")" "$2"
        ;;
    expire-on-boot)
        deployment_lock
        ssh_migration_read_state
        ssh_deadline=$(( $(date +%s) + 5 ))
        ssh_migration_write_state pending
        systemctl stop vpn-script-ssh-rollback.timer
        when=$(date -u -d "@$ssh_deadline" '+%Y-%m-%d %H:%M:%S UTC')
        sed -i "s/^OnCalendar=.*/OnCalendar=$when/" /etc/systemd/system/vpn-script-ssh-rollback.timer
        systemctl daemon-reload
        ;;
    recovered)
        for attempt in {1..100}; do
            if [[ ! -f "$STATE_DIR/ssh-pending" ]] && ssh_port_is_listening 60022; then break; fi
            sleep 0.2
        done
        [[ ! -f "$STATE_DIR/ssh-pending" && -z $(ssh_listeners 60023) ]]
        ssh_port_is_listening 60022
        printf 'PASS Real systemd restored SSH after boot with an expired persistent timer\n'
        ;;
    *) exit 2 ;;
esac
