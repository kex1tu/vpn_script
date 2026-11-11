#!/usr/bin/env bash

install_probe_dependencies() {
    local requirements="$LIB_DIR/probe-requirements.txt" digest target
    target=/usr/local/lib/vpn-script/probe-packages
    digest=$(sha256sum "$requirements" | cut -d' ' -f1) || return 1
    if [[ -f "$target/.vpn-script-lock" && "$(cat "$target/.vpn-script-lock")" == "$digest" ]]; then
        return 0
    fi
    if [[ "$INSTALL" == n ]]; then
        deployment_error "Pinned QUIC probe dependencies are missing; provision dependencies or use -install y"
        return 1
    fi
    python3 -m pip install --disable-pip-version-check --no-cache-dir --only-binary=:all: \
        --require-hashes --target "$DEPLOYMENT/probe-packages" -r "$requirements" || return 1
    printf '%s\n' "$digest" > "$DEPLOYMENT/probe-packages/.vpn-script-lock" || return 1
    install -d -m 755 /usr/local/lib/vpn-script || return 1
    rm -rf -- "$target" || return 1
    mv -- "$DEPLOYMENT/probe-packages" "$target"
}

# Fetch all replacements before modifying the installed geo assets.
install_geodata() (
    local directory="$1" mode="${2:-apply}" temporary file
    if [[ "$mode" != apply && "$mode" != prepare ]]; then return 1; fi
    if [[ -n "${DEPLOYMENT:-}" ]]; then
        temporary="$DEPLOYMENT/geodata"
        mkdir -p -- "$temporary" || return 1
    else
        temporary=$(mktemp -d) || return 1
        trap 'rm -rf -- "$temporary"' EXIT
    fi

    fetch_geo_asset() {
        local filename="$1" url="$2" sha256="$3"
        if printf '%s  %s\n' "$sha256" "$temporary/$filename" | sha256sum --check --status 2>/dev/null; then
            return 0
        fi
        if printf '%s  %s\n' "$sha256" "$directory/$filename" | sha256sum --check --status 2>/dev/null; then
            cp -- "$directory/$filename" "$temporary/$filename" || return 1
            return 0
        fi
        if printf '%s  %s\n' "$sha256" "/var/cache/vpn-script/$sha256.dat" | sha256sum --check --status 2>/dev/null; then
            cp -- "/var/cache/vpn-script/$sha256.dat" "$temporary/$filename"
            return 0
        fi
        curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
            --proto '=https' --proto-redir '=https' "$url" --output "$temporary/$filename" || return 1
        printf '%s  %s\n' "$sha256" "$temporary/$filename" | sha256sum --check --status ||
            deployment_error "Checksum verification failed for $filename"
    }

    fetch_geo_asset geoip.dat \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$LOYAL_GEO_VERSION/geoip.dat" "$LOYAL_GEOIP_SHA256" || return 1
    fetch_geo_asset geosite.dat \
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/$LOYAL_GEO_VERSION/geosite.dat" "$LOYAL_GEOSITE_SHA256" || return 1
    fetch_geo_asset geosite_RU.dat \
        "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/download/$RUNET_GEO_VERSION/geosite.dat" "$RUNET_GEOSITE_SHA256" || return 1

    if [[ "$mode" == prepare ]]; then return 0; fi
    for file in "$temporary"/*.dat; do
        [[ -f "$file" ]] || continue
        install -m 644 -- "$file" "$directory/.${file##*/}.vpn-script" || return 1
        mv -fT -- "$directory/.${file##*/}.vpn-script" "$directory/${file##*/}" || return 1
    done
)
