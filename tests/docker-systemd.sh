#!/usr/bin/env bash
# Host orchestration; all service logic executes inside disposable Docker guests.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=${QA_OUTPUT_DIR:-$(mktemp -d /tmp/vpn-systemd.XXXXXXXX)}
mkdir -p "$output"
fixture=$(mktemp -d /tmp/vpn-systemd-client.XXXXXXXX)
network="vpn-systemd-qa-$$"
server="$network-server"
pending="vpn-script-qa:systemd-pending-$$"
running=n
snapshot=n
stop_server() {
    local attempt
    docker stop "$server" >/dev/null
    running=n
    # The daemon can return from stop before --rm releases the container name.
    for attempt in {1..50}; do
        if ! docker container inspect "$server" >/dev/null 2>&1; then return; fi
        sleep 0.1
    done
    printf 'Docker did not remove the stopped systemd test container\n' >&2
    return 1
}
cleanup() {
    if [[ -f "$fixture/key" ]]; then unlink "$fixture/key"; fi
    rmdir -- "$fixture"
    if [[ "$running" == y ]]; then stop_server; fi
    if [[ "$snapshot" == y ]]; then docker image rm "$pending" >/dev/null; fi
    docker network rm "$network" >/dev/null
}
trap cleanup EXIT
trap 'if [[ "$running" == y ]]; then docker logs "$server" > "$output/failure-boot.log" 2>&1; docker exec "$server" journalctl -u ssh.socket -u ssh.service -u vpn-script-ssh-rollback.service --no-pager -n 50 > "$output/failure-journal.log"; fi' ERR
docker network create --internal "$network" >/dev/null
boot() {
    docker run -d --rm -t --name "$server" --network "$network" --cgroupns private \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined \
        --tmpfs /run --tmpfs /run/lock -e container=docker \
        --mount "type=bind,source=$repo,target=/source,readonly" "$1" bash -euc '
        mount -o remount,rw /sys/fs/cgroup
        install -d /usr/local/lib/vpn-script
        cp /source/lib/* /usr/local/lib/vpn-script/
        cp /source/script.sh /usr/local/sbin/vpn-script
        chmod 755 /usr/local/sbin/vpn-script
        exec /sbin/init --log-target=console' >/dev/null
    running=y
    for attempt in {1..100}; do
        if docker exec "$server" systemctl is-active --quiet multi-user.target; then return; fi
        sleep 0.2
    done
    docker logs "$server" >&2
    return 1
}
for os in ${QA_IMAGES:-jammy noble bookworm}; do
    for mode in ${QA_MODES:-service socket}; do
        printf 'Testing real systemd %s/%s\n' "$os" "$mode"
        image="vpn-script-qa:$os-amd64"
        boot "$image"
        docker exec "$server" bash /source/tests/ssh-real-systemd.sh prepare "$mode" > "$output/$os-$mode.log" 2>&1
        docker exec "$server" bash /source/tests/ssh-real-systemd.sh stage 60022 >> "$output/$os-$mode.log" 2>&1
        docker cp "$server:/tmp/qa-key" "$fixture/key"
        docker run --rm --network "$network" --mount "type=bind,source=$fixture/key,target=/key,readonly" "$image" \
            ssh -i /key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "root@$server" true >> "$output/$os-$mode.log" 2>&1
        if docker run --rm --network "$network" --mount "type=bind,source=$fixture/key,target=/key,readonly" "$image" \
            ssh -i /key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 "root@$server" \
            /usr/local/sbin/vpn-script -ssh_confirm y >> "$output/$os-$mode.log" 2>&1; then
            printf 'Confirmation from the old SSH port was accepted\n' >&2
            exit 1
        fi
        docker run --rm --network "$network" --mount "type=bind,source=$fixture/key,target=/key,readonly" "$image" \
            ssh -i /key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 60022 "root@$server" \
            /usr/local/sbin/vpn-script -ssh_confirm y >> "$output/$os-$mode.log" 2>&1
        docker exec "$server" bash /source/tests/ssh-real-systemd.sh stage 60023 >> "$output/$os-$mode.log" 2>&1
        docker exec "$server" bash /source/tests/ssh-real-systemd.sh expire-on-boot >> "$output/$os-$mode.log" 2>&1
        docker commit "$server" "$pending" >/dev/null
        snapshot=y
        stop_server
        boot "$pending"
        docker exec "$server" bash /source/tests/ssh-real-systemd.sh recovered >> "$output/$os-$mode.log" 2>&1
        stop_server
        docker image rm "$pending" >/dev/null
        snapshot=n
        printf 'PASS real systemd %s/%s\n' "$os" "$mode"
    done
done
printf 'Real systemd logs: %s\n' "$output"
