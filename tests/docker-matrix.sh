#!/usr/bin/env bash
# Host orchestration only. All project code and checks execute inside Docker.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
architecture=${TARGET_ARCH:-$(docker info --format '{{.Architecture}}')}
case "$architecture" in x86_64) architecture=amd64 ;; aarch64) architecture=arm64 ;; esac
case "$architecture" in amd64|arm64) ;; *) echo 'TARGET_ARCH must be amd64 or arm64' >&2; exit 1 ;; esac
output=${QA_OUTPUT_DIR:-$(mktemp -d /tmp/vpn-script-qa.XXXXXXXX)}
mkdir -p "$output"
printf 'Docker QA logs: %s\n' "$output"
network=""
target=""
cleanup() {
    if [[ -n "$target" ]]; then docker stop "$target" >/dev/null; fi
    if [[ -n "$network" ]]; then docker network rm "$network" >/dev/null; fi
}
trap cleanup EXIT
for entry in ${QA_IMAGES:-ubuntu:22.04:jammy ubuntu:24.04:noble debian:12:bookworm}; do
    base=${entry%:*}
    codename=${entry##*:}
    image="vpn-script-qa:$codename-$architecture"
    printf 'Building and testing %s on %s\n' "$base" "$architecture"
    if [[ "${QA_SKIP_BUILD:-n}" != y ]]; then
        docker build --platform "linux/$architecture" --build-arg "BASE_IMAGE=$base" \
            -f "$repo/Dockerfile.test" -t "$image" "$repo" > "$output/build-$codename.log" 2>&1
    fi
    for check in test_script.sh tests/ssh-smoke.sh; do
        label=${check##*/}
        docker run --rm --platform "linux/$architecture" --network none \
            --mount "type=bind,source=$repo,target=/source,readonly" "$image" \
            bash -euc 'cp -a /source /tmp/source; bash "/tmp/source/$1"' _ "$check" \
            > "$output/$label-$codename.log" 2>&1
    done
    network="vpn-script-qa-$$-$codename"
    target="$network-target"
    docker network create --internal "$network" >/dev/null
    docker run -d --rm --platform "linux/$architecture" --network "$network" \
        --network-alias vpn-test-target --name "$target" --cap-add NET_ADMIN \
        --mount "type=bind,source=$repo,target=/source,readonly" "$image" bash -euc \
        'cp -a /source /tmp/source; ip addr add 1.1.1.1/32 dev lo; ip addr add 77.88.8.8/32 dev lo; exec python3 /tmp/source/tests/target.py' >/dev/null
    for profile in ${QA_PROFILES:-fresh legacy legacy-default}; do
        legacy=""
        default_credentials=n
        case "$profile" in
            fresh) ;;
            legacy) legacy=/tmp/source/tests/fixtures/legacy-2.9.4.sql ;;
            legacy-default) legacy=/tmp/source/tests/fixtures/legacy-default-2.9.4.sql; default_credentials=y ;;
            *) printf 'Unknown QA profile: %s\n' "$profile" >&2; exit 1 ;;
        esac
        printf 'Testing %s/%s: %s\n' "$codename" "$architecture" "$profile"
        if ! docker run --rm --platform "linux/$architecture" --network "$network" --cap-add NET_ADMIN \
            -e QA_CLIENT_TESTS=y -e QA_COLD_INSTALL=y -e QA_TARGET_GATEWAY=vpn-test-target \
            -e "QA_LEGACY_DB=$legacy" -e "QA_TRACE=${QA_TRACE:-n}" \
            -e "QA_LEGACY_DEFAULT=$default_credentials" \
            --mount "type=bind,source=$repo,target=/source,readonly" "$image" \
            bash -euc 'cp -a /source /tmp/source; bash /tmp/source/tests/install-smoke.sh' \
            > "$output/install-$codename-$profile.log" 2>&1; then
            docker logs "$target" > "$output/target-$codename-$profile.log" 2>&1
            printf 'FAIL %s/%s: %s; see %s\n' "$codename" "$architecture" "$profile" "$output" >&2
            exit 1
        fi
    done
    cleanup
    target=""
    network=""
    printf 'PASS %s/%s\n' "$codename" "$architecture"
done
printf 'Docker QA logs: %s\n' "$output"
