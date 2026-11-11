#!/usr/bin/env bash
# Real systemd server, independent client, and controlled public-IP HTTP target.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=${QA_OUTPUT_DIR:-$(mktemp -d /tmp/vpn-external.XXXXXXXX)}
mkdir -p "$output"
fixture=$(mktemp -d /tmp/vpn-external-client.XXXXXXXX)
network="vpn-external-$$"
server="$network-server"
target="$network-target"
running=n
target_running=n
cleanup() {
    rm -f -- "$fixture/credentials" "$fixture/config.json" "$fixture/ca.crt"
    rmdir -- "$fixture"
    if [[ "$running" == y ]]; then docker stop "$server" >/dev/null; fi
    if [[ "$target_running" == y ]]; then docker stop "$target" >/dev/null; fi
    docker network rm "$network" >/dev/null
}
trap cleanup EXIT
docker network create --internal --ipv6 "$network" >/dev/null
for os in ${QA_IMAGES:-jammy noble bookworm}; do
    image="vpn-script-qa:$os-amd64"
    docker run -d --rm --name "$target" --network "$network" --cap-add NET_ADMIN \
        --mount "type=bind,source=$repo,target=/source,readonly" "$image" bash -euc \
        'ip addr add 1.1.1.1/32 dev lo; ip addr add 77.88.8.8/32 dev lo; exec python3 /source/tests/target.py' >/dev/null
    target_running=y
    docker run -d --rm -t --name "$server" --network "$network" --cgroupns private \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined \
        --tmpfs /run --tmpfs /run/lock -e container=docker \
        --mount "type=bind,source=$repo,target=/source,readonly" "$image" bash -euc \
        'mount -o remount,rw /sys/fs/cgroup; exec /sbin/init --log-target=console' >/dev/null
    running=y
    gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$target")
    address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server")
    address6=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' "$server")
    [[ -n "$address6" ]] || { printf 'Native IPv6 is required for backend isolation acceptance\n' >&2; exit 1; }
    for attempt in {1..100}; do
        if docker exec "$server" systemctl is-active --quiet multi-user.target; then break; fi
        sleep 0.2
    done
    docker exec -e "QA_GATEWAY=$gateway" "$server" bash -euc '
        install -d -m 700 /tmp/qa-source
        cp -a /source/script.sh /source/audit.sh /source/lib /tmp/qa-source/
        printf "127.0.0.1 test.example.com\n" >> /etc/hosts
        cp /etc/letsencrypt/live/test.example.com/fullchain.pem /usr/local/share/ca-certificates/qa.crt
        cp /etc/vpn-qa-doh/cert.pem /usr/local/share/ca-certificates/qa-classic.crt
        update-ca-certificates >/dev/null 2>&1
        ip route add 1.1.1.1/32 via "$QA_GATEWAY"
        printf "1.1.1.1 classic.qa.test classic-alt.qa.test\n" >> /etc/hosts
        systemd-run --unit=qa-mask python3 -m http.server 18082 --bind 127.0.0.1 --directory /var/www/html
        for attempt in {1..30}; do
            if curl -fsS http://127.0.0.1:18082/ -o /dev/null 2>/dev/null; then break; fi
            sleep 0.1
        done
        mv /usr/local/x-ui/x-ui /tmp/qa-original-panel
    ' > "$output/$os.log" 2>&1
    for phase in fresh repeat; do
        options=()
        if [[ "$phase" == fresh ]]; then
            options=(-mask_upstream http://127.0.0.1:8000 -mask_port 18082 -xhttp_download_path /downloads/xhttp.json)
        fi
        docker exec "$server" bash /tmp/qa-source/script.sh -install n -subdomain test.example.com \
            -block_ru n -dns_provider none -reality_target classic.qa.test "${options[@]}" >> "$output/$os.log" 2>&1
        docker exec "$server" bash /tmp/qa-source/audit.sh >> "$output/$os.log" 2>&1
        docker cp "$server:/var/lib/vpn-script/credentials" "$fixture/credentials"
        docker cp "$server:/var/lib/vpn-script/config.json" "$fixture/config.json"
        docker cp "$server:/etc/letsencrypt/live/test.example.com/fullchain.pem" "$fixture/ca.crt"
        docker run --rm --network "$network" --add-host "test.example.com:$address" -e "QA_SERVER_IP6=$address6" \
            --mount "type=bind,source=$repo,target=/source,readonly" \
            --mount "type=bind,source=$fixture,target=/fixture,readonly" "$image" bash -euc '
            cp /fixture/ca.crt /usr/local/share/ca-certificates/qa.crt
            update-ca-certificates >/dev/null 2>&1
            python3 /source/tests/external-client.py
            python3 /source/tests/reality-negative.py /fixture/credentials' >> "$output/$os.log" 2>&1
        printf 'PASS external clients %s/%s\n' "$os" "$phase"
    done
    docker stop "$server" "$target" >/dev/null
    running=n
    target_running=n
done
printf 'External client logs: %s\n' "$output"
