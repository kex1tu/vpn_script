#!/usr/bin/env bash

SSH_MANAGED_CONFIG=/etc/ssh/sshd_config.d/00-vpn-script-port.conf
SSH_MANAGED_SOCKET_CONFIG=/etc/systemd/system/ssh.socket.d/00-vpn-script-port.conf
SSH_ROLLBACK_UNIT=vpn-script-ssh-rollback
SSH_ROLLBACK_DIR=/etc/systemd/system
SSH_RULE_COMMENT=vpn-script-ssh

ssh_migration_pending() {
    [[ -f "$STATE_DIR/ssh-pending" ]]
}

ssh_listeners() {
    ss -H -ltnp "sport = :$1"
}

ssh_port_is_listening() {
    local rows
    rows=$(ssh_listeners "$1") || return 1
    [[ -n "$rows" ]] || return 1
    awk -v port="$1" '
        $4 !~ (":" port "$") || $0 !~ /"(sshd|systemd)"/ { invalid=1 }
        END { exit invalid }' <<< "$rows"
}

ssh_migration_current_port() {
    local rows
    rows=$(ss -H -ltnp) || return 1
    # The SSH socket can belong to PID 1 before the first client connects.
    local -a candidates
    mapfile -t candidates < <(awk '
        /"sshd"/ { n=split($4, addr, ":"); print addr[n] }
    ' <<< "$rows" | sort -u)
    if systemctl is-active --quiet ssh.socket; then
        local sockets
        sockets=$(systemctl show -p Listen --value ssh.socket) || return 1
        mapfile -t candidates < <(printf '%s\n' "$sockets" |
            grep -oE '[^[:space:]]+ \(Stream\)' |
            sed -E 's/.*:([0-9]+) \(Stream\)$/\1/; s/^([0-9]+) \(Stream\)$/\1/' |
            sort -u)
    fi
    if (( ${#candidates[@]} != 1 )) || ! [[ "${candidates[0]}" =~ ^[0-9]{1,5}$ ]]; then
        deployment_error "Cannot identify an unambiguous current SSH listener"
        return 1
    fi
    ssh_port_is_listening "${candidates[0]}" || return 1
    printf '%s\n' "${candidates[0]}"
}

ssh_migration_write_state() {
    local phase="$1" temporary
    temporary=$(mktemp "$STATE_DIR/.ssh-pending.XXXXXXXX") || return 1
    if ! printf '%s %s %s %s %s %s %s %s\n' "$ssh_id" "$phase" "$ssh_old" "$ssh_new" \
        "$ssh_deadline" "$ssh_mode" "$ssh_new_rule" "$ssh_old_rule" > "$temporary" ||
       ! sync -f "$temporary" ||
       ! mv -f -- "$temporary" "$STATE_DIR/ssh-pending"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "$STATE_DIR"
}

ssh_migration_read_state() {
    local extra
    read -r ssh_id ssh_phase ssh_old ssh_new ssh_deadline ssh_mode ssh_new_rule ssh_old_rule extra \
        < "$STATE_DIR/ssh-pending" || return 1
    [[ -z "$extra" && "$ssh_id" =~ ^ssh\.[a-zA-Z0-9]+$ &&
       "$ssh_phase" =~ ^(preparing|pending|committing|committed|restored)$ &&
       "$ssh_old" =~ ^[1-9][0-9]{0,4}$ && "$ssh_new" =~ ^[1-9][0-9]{0,4}$ &&
       "$ssh_deadline" =~ ^[1-9][0-9]{0,11}$ && "$ssh_mode" =~ ^(socket|service)$ &&
       "$ssh_new_rule" =~ ^(0|1)$ && "$ssh_old_rule" =~ ^(0|1)$ ]] || return 1
    [[ -d "$STATE_DIR/$ssh_id" && ! -L "$STATE_DIR/$ssh_id" ]]
}

ssh_owned_rule() {
    grep -Fxq "ufw allow $1/tcp comment '$SSH_RULE_COMMENT'" <<< "$2"
}

ssh_any_port_rule() {
    grep -Eq "(^|[[:space:]])$1(/(tcp|udp)|[[:space:]]|$)" <<< "$2"
}

ssh_has_port() {
    local config
    config=$(sshd -T) || return 2
    grep -Fxq "port $1" <<< "$config"
}

ssh_apply_ports() {
    # Stopping a socket-activated service removes RuntimeDirectory=sshd.
    # sshd -t also requires this directory before the socket starts sshd again.
    install -d -m 755 /run/sshd || return 1
    sshd -t || return 1
    if [[ "$ssh_mode" == socket ]]; then
        # Release the old socket descriptors before loading the new listeners.
        # Stopping the socket first prevents reactivation while sshd is stopping.
        [[ "$(systemctl show -p KillMode --value ssh.service)" == process ]] ||
            { deployment_error "SSH service KillMode does not preserve sessions"; return 1; }
        systemctl stop ssh.socket && systemctl stop ssh.service &&
            systemctl daemon-reload && systemctl start ssh.socket
    else
        systemctl reload ssh.service
    fi
}

ssh_check_ports() {
    local attempt port ready
    for attempt in {1..30}; do
        ready=yes
        for port in "$@"; do
            if ! ssh_port_is_listening "$port"; then ready=no; fi
        done
        [[ "$ready" == yes ]] && return 0
        sleep 0.2
    done
    deployment_error "SSH listener check failed for port(s): $*"
}

ssh_write_ports() {
    local temporary port
    temporary=$(mktemp "${SSH_MANAGED_CONFIG%/*}/.vpn-script-port.XXXXXXXX") || return 1
    if ! {
        printf '# Managed by vpn-script\n'
        for port in "$@"; do printf 'Port %s\n' "$port"; done
    } > "$temporary" ||
       ! chmod 644 "$temporary" || ! sync -f "$temporary" ||
       ! mv -f -- "$temporary" "$SSH_MANAGED_CONFIG"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "${SSH_MANAGED_CONFIG%/*}"
    if [[ "$ssh_mode" == socket ]]; then
        local effective addresses
        effective=$(sshd -T) || return 1
        addresses=$(awk '$1=="listenaddress" {print $2}' <<< "$effective")
        [[ -n "$addresses" ]] || return 1
        install -d -m 755 "${SSH_MANAGED_SOCKET_CONFIG%/*}" || return 1
        temporary=$(mktemp "${SSH_MANAGED_SOCKET_CONFIG%/*}/.vpn-script-socket.XXXXXXXX") || return 1
        {
            printf '# Managed by vpn-script\n[Socket]\nBindIPv6Only=ipv6-only\nListenStream=\n'
            while read -r address; do printf 'ListenStream=%s\n' "$address"; done <<< "$addresses"
        } > "$temporary" || return 1
        chmod 644 "$temporary" && sync -f "$temporary" &&
            mv -f -- "$temporary" "$SSH_MANAGED_SOCKET_CONFIG" || return 1
    fi
}

ssh_start_timer() {
    local when temporary
    when=$(date -u -d "@$ssh_deadline" '+%Y-%m-%d %H:%M:%S UTC') || return 1
    temporary=$(mktemp "$SSH_ROLLBACK_DIR/.vpn-script-ssh.XXXXXXXX") || return 1
    cat > "$temporary" <<'UNIT' || return 1
# Managed by vpn-script
[Unit]
Description=Roll back an unconfirmed VPN Script SSH port change
After=ssh.service ssh.socket

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-script -ssh_rollback y
Restart=on-failure
RestartSec=15s
UNIT
    chmod 644 "$temporary" && sync -f "$temporary" &&
        mv -f -- "$temporary" "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.service" || return 1
    temporary=$(mktemp "$SSH_ROLLBACK_DIR/.vpn-script-ssh.XXXXXXXX") || return 1
    cat > "$temporary" <<UNIT || return 1
# Managed by vpn-script
[Unit]
Description=Deadline for confirming the VPN Script SSH port change

[Timer]
OnCalendar=$when
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
    chmod 644 "$temporary" && sync -f "$temporary" &&
        mv -f -- "$temporary" "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.timer" &&
        sync -f "$SSH_ROLLBACK_DIR" && systemctl daemon-reload &&
        systemctl enable --now "$SSH_ROLLBACK_UNIT.timer" &&
        systemctl is-active --quiet "$SSH_ROLLBACK_UNIT.timer"
}

ssh_clear_migration() {
    local suffix path
    if [[ -f "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.timer" ]]; then
        systemctl disable --now "$SSH_ROLLBACK_UNIT.timer" || return 1
    fi
    for suffix in service timer; do
        path="$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.$suffix"
        if [[ -f "$path" ]]; then
            grep -Fxq '# Managed by vpn-script' "$path" || return 1
            rm -- "$path" || return 1
        fi
    done
    systemctl daemon-reload &&
        rm -- "$STATE_DIR/ssh-pending" &&
        sync -f "$STATE_DIR"
}

ssh_restore_migration() {
    local saved="$STATE_DIR/$ssh_id" rules temporary failed=0
    if [[ -f "$saved/sshd.conf" ]]; then
        temporary=$(mktemp "${SSH_MANAGED_CONFIG%/*}/.vpn-script-restore.XXXXXXXX") || return 1
        cp --preserve=mode,ownership -- "$saved/sshd.conf" "$temporary" &&
            sync -f "$temporary" && mv -f -- "$temporary" "$SSH_MANAGED_CONFIG" || return 1
    else
        rm -f -- "$SSH_MANAGED_CONFIG" || return 1
    fi
    if [[ "$ssh_mode" == socket ]]; then
        if [[ -f "$saved/socket.conf" ]]; then
            install -d -m 755 "${SSH_MANAGED_SOCKET_CONFIG%/*}" || return 1
            cp -a -- "$saved/socket.conf" "$SSH_MANAGED_SOCKET_CONFIG" || return 1
        else
            rm -f -- "$SSH_MANAGED_SOCKET_CONFIG" || return 1
        fi
    fi
    if rules=$(LC_ALL=C ufw show added); then
        # Restore the old firewall permission before touching the SSH listener.
        if [[ "$ssh_old_rule" == 1 ]] && ! ssh_owned_rule "$ssh_old" "$rules"; then
            ufw allow "$ssh_old/tcp" comment "$SSH_RULE_COMMENT" || failed=1
        fi
    else
        failed=1
    fi
    ssh_apply_ports && ssh_check_ports "$ssh_old" || return 1
    if [[ "$ssh_new_rule" == 1 ]] && ssh_owned_rule "$ssh_new" "$rules"; then
        ufw --force delete allow "$ssh_new/tcp" comment "$SSH_RULE_COMMENT" || failed=1
    fi
    if [[ -f "$saved/config.json" ]]; then
        temporary=$(mktemp "$STATE_DIR/.ssh-config-restore.XXXXXXXX") || return 1
        install -m 600 "$saved/config.json" "$temporary" &&
            sync -f "$temporary" && mv -f -- "$temporary" "$STATE_DIR/config.json" || return 1
    fi
    (( failed == 0 )) || return 1
    ssh_migration_write_state restored && ssh_clear_migration
}

ssh_migration_rollback_expired() {
    ssh_migration_pending || return 0
    local ssh_id ssh_phase ssh_old ssh_new ssh_deadline ssh_mode ssh_new_rule ssh_old_rule now
    ssh_migration_read_state || { deployment_error "Invalid SSH recovery journal"; return 1; }
    now=$(date +%s) || return 1
    case "$ssh_phase" in
        committed|restored) ssh_clear_migration || return 1 ;;
        pending)
            (( now >= ssh_deadline )) || return 0
            ssh_restore_migration || { deployment_error "SSH rollback failed; journal retained"; return 1; }
            printf 'SSH rollback restored port %s\n' "$ssh_old" ;;
        *)
            ssh_restore_migration || { deployment_error "SSH rollback failed; journal retained"; return 1; }
            printf 'SSH rollback restored port %s\n' "$ssh_old" ;;
    esac
}

ssh_stage_ports() {
    ssh_start_timer || return 1
    if [[ "$ssh_new_rule" == 1 ]]; then
        ufw allow "$ssh_new/tcp" comment "$SSH_RULE_COMMENT" || return 1
    fi
    ssh_write_ports "$ssh_old" "$ssh_new" &&
        ssh_has_port "$ssh_old" && ssh_has_port "$ssh_new" &&
        ssh_apply_ports && ssh_check_ports "$ssh_old" "$ssh_new" &&
        ssh_migration_write_state pending
}

ssh_migration_setup() {
    local ssh_new="$1" ssh_id ssh_old ssh_deadline ssh_mode ssh_new_rule=0 ssh_old_rule=0
    local rows rules saved now
    ssh_old=$(ssh_migration_current_port) || return 1
    if [[ "$ssh_new" == "$ssh_old" ]]; then return 0; fi
    if ssh_migration_pending; then
        deployment_error "An SSH port change is awaiting confirmation"
        return 1
    fi
    if [[ ! -x /usr/local/sbin/vpn-script || -L "$SSH_MANAGED_CONFIG" ||
          -e "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.service" || -L "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.service" ||
          -e "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.timer" || -L "$SSH_ROLLBACK_DIR/$SSH_ROLLBACK_UNIT.timer" ]]; then
        deployment_error "SSH migration files are missing or conflict with existing resources"
        return 1
    fi
    if [[ -e "$SSH_MANAGED_CONFIG" ]] && ! grep -Fxq '# Managed by vpn-script' "$SSH_MANAGED_CONFIG"; then
        deployment_error "The SSH drop-in belongs to the operator"
        return 1
    fi
    rows=$(ssh_listeners "$ssh_new") || return 1
    if [[ -n "$rows" ]]; then deployment_error "Requested SSH port already listens"; return 1; fi
    if systemctl is-active --quiet ssh.socket; then
        ssh_mode=socket
        if systemctl is-active --quiet ssh.service &&
           [[ "$(systemctl show -p KillMode --value ssh.service)" != process ]]; then
            deployment_error "SSH service KillMode does not preserve sessions"
            return 1
        fi
    elif systemctl is-active --quiet ssh.service; then
        ssh_mode=service
    else
        deployment_error "Neither ssh.service nor ssh.socket is active"
        return 1
    fi
    if [[ "$ssh_mode" == socket && ( -e "$SSH_MANAGED_SOCKET_CONFIG" || -L "$SSH_MANAGED_SOCKET_CONFIG" ) ]]; then
        if [[ -L "$SSH_MANAGED_SOCKET_CONFIG" ]] || ! grep -Fxq '# Managed by vpn-script' "$SSH_MANAGED_SOCKET_CONFIG"; then
            deployment_error "The SSH socket drop-in belongs to the operator"
            return 1
        fi
    fi
    install -d -m 755 /run/sshd || return 1
    sshd -t || return 1
    rules=$(LC_ALL=C ufw show added) || return 1
    # Leave pre-existing scoped rules intact; the new authenticated session
    # demonstrates whether those permissions actually admit the operator.
    if ! ssh_any_port_rule "$ssh_new" "$rules"; then ssh_new_rule=1; fi
    if ssh_owned_rule "$ssh_old" "$rules"; then ssh_old_rule=1; fi
    saved=$(mktemp -d "$STATE_DIR/ssh.XXXXXXXX") || return 1
    ssh_id=${saved##*/}
    if [[ -f "$SSH_MANAGED_CONFIG" ]]; then
        cp -a -- "$SSH_MANAGED_CONFIG" "$saved/sshd.conf" || return 1
    fi
    if [[ "$ssh_mode" == socket && -f "$SSH_MANAGED_SOCKET_CONFIG" ]]; then
        cp -a -- "$SSH_MANAGED_SOCKET_CONFIG" "$saved/socket.conf" || return 1
    fi
    if [[ -f "$STATE_DIR/config.json" ]]; then
        cp -a -- "$STATE_DIR/config.json" "$saved/config.json" || return 1
    fi
    now=$(date +%s) || return 1
    ssh_deadline=$(( now + 600 ))
    sync -f "$saved" && ssh_migration_write_state preparing || return 1
    if ! ssh_stage_ports; then
        if ! ssh_restore_migration; then
            deployment_error "SSH rollback failed; recovery data: $saved"
        fi
        return 1
    fi
    printf 'SSH pending: port %s remains open. Log in on port %s and confirm within 10 minutes.\n' "$ssh_old" "$ssh_new"
    printf '%s\n' 'sudo --preserve-env=SSH_CONNECTION /usr/local/sbin/vpn-script -ssh_confirm y'
}

ssh_session_matches() {
    python3 - "$1" <<'PY'
import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path

def endpoint(raw):
    host, port = raw.rsplit(":", 1)
    address = ipaddress.ip_address(host.strip("[]").split("%", 1)[0])
    return (getattr(address, "ipv4_mapped", None) or address, int(port))

try:
    peer, peer_port, local, local_port = os.environ.get("SSH_CONNECTION", "").split()
    if int(local_port) != int(sys.argv[1]):
        sys.exit(1)
    peer = endpoint(peer + ":" + peer_port)
    local = endpoint(local + ":" + local_port)
    ssh_ancestors = set()
    pid = os.getppid()
    while pid > 1:
        proc = Path("/proc") / str(pid)
        if proc.joinpath("comm").read_text().strip() in ("sshd", "sshd-session", "sshd-auth"):
            ssh_ancestors.add(pid)
        status = proc.joinpath("status").read_text()
        pid = int(re.search(r"^PPid:\s*(\d+)", status, re.M).group(1))
    if not ssh_ancestors:
        sys.exit(1)
    sockets = subprocess.check_output(
        ["ss", "-H", "-tnp", "state", "established",
         f"( sport = :{local[1]} and dport = :{peer[1]} )"], text=True,
    )
    for row in sockets.splitlines():
        columns = row.split()
        owners = {int(value) for value in re.findall(r"\bpid=(\d+)", row)}
        if not ssh_ancestors.intersection(owners):
            continue
        first, second = columns[-3:-1]
        if (endpoint(first), endpoint(second)) == (local, peer):
            sys.exit(0)
except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
    pass
sys.exit(1)
PY
}

ssh_commit_ports() {
    local rules rows temporary
    ssh_write_ports "$ssh_new" && ssh_has_port "$ssh_new" &&
        ssh_apply_ports && ssh_check_ports "$ssh_new" || return 1
    rows=$(ssh_listeners "$ssh_old") || return 1
    rules=$(LC_ALL=C ufw show added) || return 1
    if [[ -n "$rows" ]]; then
        printf 'SSH: port %s remains active under the existing system configuration.\n' "$ssh_old"
    elif [[ "$ssh_old_rule" == 1 ]] && ssh_owned_rule "$ssh_old" "$rules"; then
        ufw --force delete allow "$ssh_old/tcp" comment "$SSH_RULE_COMMENT" || return 1
    elif ssh_any_port_rule "$ssh_old" "$rules"; then
        printf 'SSH: preserved operator firewall rules for port %s.\n' "$ssh_old"
    fi
    temporary=$(mktemp "$STATE_DIR/.ssh-config.XXXXXXXX") || return 1
    if ! jq -e --argjson port "$ssh_new" '.ssh_port = $port' "$STATE_DIR/config.json" > "$temporary" ||
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$STATE_DIR/config.json"; then
        rm -f -- "$temporary"
        return 1
    fi
    ssh_migration_write_state committed
}

ssh_migration_confirm() {
    local ssh_id ssh_phase ssh_old ssh_new ssh_deadline ssh_mode ssh_new_rule ssh_old_rule now
    ssh_migration_rollback_expired || return 1
    if ! ssh_migration_pending; then
        deployment_error "No SSH migration is awaiting confirmation"
        return 1
    fi
    ssh_migration_read_state || return 1
    if ! ssh_session_matches "$ssh_new"; then
        deployment_error "Confirm from an authenticated SSH session on port $ssh_new"
        return 1
    fi
    now=$(date +%s) || return 1
    if (( now >= ssh_deadline )); then
        ssh_migration_rollback_expired || return 1
        deployment_error "SSH confirmation deadline expired"
        return 1
    fi
    ssh_migration_write_state committing || return 1
    if ! ssh_commit_ports; then
        ssh_restore_migration || deployment_error "SSH rollback failed; journal retained"
        return 1
    fi
    ssh_clear_migration || return 1
    printf 'SSH port %s confirmed\n' "$ssh_new"
}
