"""Configure the managed Xray routes and export links for active clients."""

import argparse
import json
import re
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path
from urllib.parse import quote, urlencode
from reality import LABELS, ROLES, managed_reality, registry

AI_DOMAINS = [
    "geosite:google-gemini", "geosite:google-deepmind", "geosite:openai",
    "geosite:anthropic", "domain:gemini.google.com", "domain:aistudio.google.com",
    "domain:generativelanguage.googleapis.com",
    "domain:alkalimakersuite-pa.clients6.google.com",
    "domain:makersuite.google.com", "domain:bard.google.com", "domain:deepmind.google",
    "domain:deepmind.com", "domain:labs.google", "domain:notebooklm.google.com",
    "domain:notebooklm.google", "domain:ai.google.dev",
    "domain:proactivebackend-pa.googleapis.com",
]
PROVIDERS = {
    "xboxdns": "https+local://xbox-dns.ru/dns-query",
    "geohide": "https+local://eu.geohide.ru/dns-query",
    "comss": "https+local://dns.comss.one/dns-query",
}
RULE_PREFIX = "vpn-script:"
DIRECT = "vpn-script-direct"
BLOCKED = "vpn-script-blocked"
DNS_TAG = "vpn-script-doh"
RU_DOMAINS = ["ext:geosite_RU.dat:ru-blocked-all"]
LEGACY_DOH = PROVIDERS["geohide"]

XHTTP_EXTRA = (
    "xPaddingBytes", "xPaddingObfsMode", "xPaddingKey", "xPaddingHeader",
    "xPaddingPlacement", "xPaddingMethod", "sessionIDPlacement", "sessionIDKey",
    "sessionIDTable", "sessionIDLength", "seqPlacement", "seqKey",
    "uplinkHTTPMethod",
)


class ConfigError(Exception):
    pass


def open_db(path, mode):
    return sqlite3.connect(f"{Path(path).resolve().as_uri()}?mode={mode}", uri=True)


def managed_inbounds(db, xhttp_port):
    vless = db.execute(
        "SELECT id, tag, settings, stream_settings FROM inbounds "
        "WHERE enable=1 AND protocol='vless' AND port=?", (xhttp_port,),
    ).fetchall()
    hysteria = db.execute(
        "SELECT id, tag, settings, stream_settings FROM inbounds "
        "WHERE enable=1 AND protocol IN ('hysteria','hysteria2') AND port=443",
    ).fetchall()
    hysteria = [row for row in hysteria if json.loads(row[2]).get("version") == 2]
    if len(vless) != 1 or len(hysteria) != 1:
        raise ConfigError("Expected one enabled managed VLESS xHTTP and Hysteria 2 inbound")
    if json.loads(vless[0][3]).get("network") not in ("xhttp", "splithttp"):
        raise ConfigError("Managed VLESS inbound does not use xHTTP")
    tags = [vless[0][1], hysteria[0][1]]
    if not all(tags) or len(set(tags)) != 2:
        raise ConfigError("Managed inbound tags must be non-empty and distinct")
    saved = registry(db)
    for role, row in zip(("xhttp_tls", "hy2"), (vless[0], hysteria[0])):
        if saved and (saved[role]["id"] != row[0] or saved[role]["tag"] != row[1]):
            raise ConfigError("Original managed inbound identity differs from the registry")
    return vless[0], hysteria[0]


def all_managed_inbounds(db, xhttp_port):
    rows = [*managed_inbounds(db, xhttp_port), *managed_reality(db)]
    if len({row[0] for row in rows}) != len(rows) or len({row[1] for row in rows}) != len(rows):
        raise ConfigError("Managed inbound identities are not unique")
    return rows


def legacy_ru(rule):
    return (
        rule.get("outboundTag") == "blocked"
        and rule.get("domain") == RU_DOMAINS
        and rule.get("ip") == ["geoip:ru", "ext:geoip_IR.dat:ru"]
    )


def legacy_doh(server):
    return (
        isinstance(server, dict) and server.get("tag") != DNS_TAG
        and server.get("address") == LEGACY_DOH
        and server.get("domains") == AI_DOMAINS
    )


def migrate_legacy(rules, outbounds, dns, adopt):
    servers = dns.get("servers", [])
    found = any(legacy_ru(rule) or rule.get("outboundTag") == "geohide_dns" for rule in rules)
    found |= any(legacy_doh(server) for server in servers)
    found |= any(outbound.get("tag") == "geohide_dns" for outbound in outbounds)
    if not found:
        return rules, outbounds
    if not adopt:
        raise ConfigError("Legacy RU-Block or GeoHide configuration requires explicit adoption")
    for rule in rules:
        if rule.get("outboundTag") == "geohide_dns" and rule.get("domain") != AI_DOMAINS:
            raise ConfigError("Custom routing uses the legacy GeoHide outbound")
    for outbound in outbounds:
        if outbound.get("tag") == "geohide_dns" and outbound.get("protocol") != "freedom":
            raise ConfigError("Legacy GeoHide outbound was modified")
    rules = [
        rule for rule in rules
        if not legacy_ru(rule)
        and rule.get("outboundTag") != "geohide_dns"
        and not (
            rule.get("outboundTag") == "blocked" and rule.get("enabled") is True
            and rule.get("network") == "udp" and rule.get("port") == "443"
            and set(rule) == {"type", "enabled", "port", "network", "outboundTag"}
        )
    ]
    dns["servers"] = [server for server in servers if not legacy_doh(server)]
    hosts = dns.get("hosts", {})
    if hosts.get("eu.geohide.ru") == "5.175.161.3":
        del hosts["eu.geohide.ru"]
    return rules, [outbound for outbound in outbounds if outbound.get("tag") != "geohide_dns"]


def configure_dns(dns, provider):
    servers = [
        server for server in dns.get("servers", [])
        if not (isinstance(server, dict) and server.get("tag") == DNS_TAG)
    ]
    if provider != "none":
        if dns.get("disableFallback") or dns.get("disableFallbackIfMatch"):
            raise ConfigError("The current DNS settings disable ordinary DNS fallback")
        if not any(
            isinstance(server, str)
            or (not server.get("domains") and not server.get("skipFallback"))
            for server in servers
        ):
            servers.append("localhost")
        servers.insert(0, {
            "address": PROVIDERS[provider], "domains": AI_DOMAINS,
            "skipFallback": True, "tag": DNS_TAG,
        })
    if servers:
        dns["servers"] = servers
    else:
        dns.pop("servers", None)


def configure_routes(config, tags, block_ru, provider, adopt):
    routing = config.setdefault("routing", {})
    if routing.get("script"):
        raise ConfigError("A custom routing script overrides managed VPN protections")
    rules = [rule for rule in routing.get("rules", []) if not rule.get("ruleTag", "").startswith(RULE_PREFIX)]
    outbounds = config.setdefault("outbounds", [])
    dns = config.get("dns", {})
    rules, outbounds = migrate_legacy(rules, outbounds, dns, adopt)
    configure_dns(dns, provider)
    if dns:
        config["dns"] = dns
    else:
        config.pop("dns", None)

    outbounds = [outbound for outbound in outbounds if outbound.get("tag") not in (DIRECT, BLOCKED)]
    blocking = {outbound.get("tag") for outbound in outbounds if outbound.get("protocol") == "blackhole"}
    for rule in rules:
        inbound_tags = rule.get("inboundTag")
        if inbound_tags and not set(tags).intersection(inbound_tags):
            continue
        if rule.get("outboundTag") not in blocking:
            raise ConfigError("A custom Xray route may bypass managed VPN protections")

    def rule(name, target, **match):
        return {
            "type": "field", "ruleTag": RULE_PREFIX + name, "inboundTag": tags,
            "outboundTag": target, **match,
        }

    protected = [rule("private", BLOCKED, ip=["geoip:private"])]
    final = [{"action": "block", "ip": ["geoip:private"]}]
    if block_ru:
        protected[:0] = [
            rule("ru-domains", BLOCKED, domain=RU_DOMAINS),
            rule("ru-ip", BLOCKED, ip=["geoip:ru"]),
            rule("bittorrent", BLOCKED, protocol=["bittorrent"]),
            rule("quic", BLOCKED, network="udp", port="443"),
        ]
        final.append({"action": "block", "ip": ["geoip:ru"]})
        final.append({"action": "block", "network": "udp", "port": "443"})
    final.append({"action": "allow"})
    if not outbounds:
        raise ConfigError("Xray template is missing its default outbound")
    config["outbounds"] = outbounds + [
        {"tag": BLOCKED, "protocol": "blackhole", "settings": {}},
        {
            "tag": DIRECT, "protocol": "freedom", "settings": {"finalRules": final},
            "streamSettings": {"sockopt": {"domainStrategy": "ForceIP"}},
        },
    ]
    routing["rules"] = protected + rules + [rule("direct", DIRECT)]


def initial_template():
    return {
        "api": {"tag": "api", "services": [
            "HandlerService", "LoggerService", "StatsService", "RoutingService",
        ]},
        "inbounds": [{
            "tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel",
            "settings": {"rewriteAddress": "127.0.0.1"},
        }],
        "log": {"access": "none", "loglevel": "warning"},
        "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {}}],
        "routing": {"rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]},
        "policy": {
            "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
            "system": {"statsInboundDownlink": True, "statsInboundUplink": True},
        },
        "stats": {},
    }


def prepare_routing(db, port, block_ru, provider, adopt):
    tags = [row[1] for row in all_managed_inbounds(db, port)]
    rows = db.execute(
        "SELECT value FROM settings WHERE key='xrayTemplateConfig' ORDER BY id"
    ).fetchall()
    if any(row != rows[0] for row in rows):
        raise ConfigError("Conflicting Xray template settings")
    config = json.loads(rows[0][0]) if rows else initial_template()
    configure_routes(config, tags, block_ru, provider, adopt)
    return config


def preflight_database(db, block_ru, provider, adopt):
    for key in ("webPort", "webBasePath"):
        values = db.execute("SELECT DISTINCT value FROM settings WHERE key=?", (key,)).fetchall()
        if len(values) > 1:
            raise ConfigError("Conflicting panel settings require operator review")
        if values and values[0][0]:
            value = values[0][0]
            if key == "webPort":
                if not str(value).isdigit() or not 1024 < int(value) <= 65535 or int(value) == 9443:
                    raise ConfigError("Invalid existing panel port")
            elif not re.fullmatch(r"[A-Za-z0-9_-]+", value.strip("/")):
                raise ConfigError("Invalid existing panel path")
    if not db.execute("SELECT count(*) FROM inbounds").fetchone()[0]:
        return
    ports = db.execute(
        "SELECT port,stream_settings FROM inbounds WHERE enable=1 AND protocol='vless' "
        "AND json_extract(stream_settings,'$.network')='xhttp' "
        "AND coalesce(json_extract(stream_settings,'$.security'),'none')='none'"
    ).fetchall()
    if len(ports) != 1:
        raise ConfigError("Expected one unambiguous existing xHTTP inbound")
    port, stream = ports[0]
    if not 1024 < int(port) <= 65535 or int(port) == 9443:
        raise ConfigError("Invalid existing xHTTP port")
    xhttp = json.loads(stream)["xhttpSettings"]
    if xhttp.get("path") and not re.fullmatch(r"(/[A-Za-z0-9_-]+)+/", xhttp["path"]):
        raise ConfigError("Unsafe existing xHTTP path")
    for key in ("xPaddingKey", "xPaddingHeader", "sessionIDKey", "seqKey"):
        if xhttp.get(key) and not re.fullmatch(r"[A-Za-z0-9-]+", xhttp[key]):
            raise ConfigError("Unsafe existing xHTTP header")
    prepare_routing(db, int(port), block_ru, provider, adopt)


def apply_routing(db, port, block_ru, provider, adopt):
    db.execute("BEGIN IMMEDIATE")
    config = prepare_routing(db, port, block_ru, provider, adopt)
    db.execute("DELETE FROM settings WHERE key='xrayTemplateConfig'")
    db.execute(
        "INSERT INTO settings(key,value) VALUES('xrayTemplateConfig',?)",
        (json.dumps(config, ensure_ascii=False),),
    )


def client_secret(db, inbound, protocol):
    column = "uuid" if protocol == "vless" else "auth"
    clients_table = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='client_inbounds'"
    ).fetchone()
    if clients_table:
        row = db.execute(
            f"SELECT c.{column} FROM clients c JOIN client_inbounds ci ON c.id=ci.client_id "
            f"WHERE ci.inbound_id=? AND c.enable=1 AND c.{column} <> '' "
            "AND (coalesce(c.expiry_time,0) <= 0 OR c.expiry_time > strftime('%s','now')*1000) ORDER BY c.id LIMIT 1",
            (inbound[0],),
        ).fetchone()
        if row:
            return row[0]
        raise ConfigError(f"No active {protocol} client in the panel database")
    settings = json.loads(inbound[2])
    key = "id" if protocol == "vless" else "auth"
    for client in settings.get("clients", settings.get("users", [])):
        expiry = client.get("expiryTime", 0) or 0
        if client.get("enable", True) and client.get(key) and (expiry <= 0 or expiry > time.time() * 1000):
            return client[key]
    raise ConfigError(f"No active {protocol} client in the panel database")


def xhttp_client(db, vless, domain):
    vless_secret = client_secret(db, vless, "vless")
    transport = json.loads(vless[3]).get("xhttpSettings", {})
    path, mode = transport.get("path"), transport.get("mode") or "auto"
    if not path:
        raise ConfigError("The active xHTTP transport is missing its path")
    query = {
        "type": "xhttp", "security": "tls", "sni": domain,
        "host": transport.get("host") or domain, "path": path, "mode": mode,
        "encryption": json.loads(vless[2]).get("encryption", "none"),
    }
    extra = {name: transport[name] for name in XHTTP_EXTRA if name in transport and transport[name] != ""}
    return vless_secret, query, extra


def export_xhttp_config(db, domain, port):
    vless, _ = managed_inbounds(db, port)
    secret, query, extra = xhttp_client(db, vless, domain)
    return {
        "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}}],
        "outbounds": [{
            "protocol": "vless",
            "settings": {"vnext": [{"address": domain, "port": 443, "users": [
                {"id": secret, "encryption": query["encryption"]},
            ]}]},
            "streamSettings": {
                "network": "xhttp", "security": "tls",
                "tlsSettings": {"serverName": domain, "useSystemCA": True},
                "xhttpSettings": {key: query[key] for key in ("host", "path", "mode")} | extra,
            },
        }],
    }


def export_links(db, domain, port):
    vless, hysteria = managed_inbounds(db, port)
    vless_secret, query, extra = xhttp_client(db, vless, domain)
    hy2_secret = client_secret(db, hysteria, "hysteria2")
    if extra:
        query["extra"] = json.dumps(extra, separators=(",", ":"))
    hy2_query = {"sni": json.loads(hysteria[3]).get("tlsSettings", {}).get("serverName") or domain}
    vless_label = quote(f"{domain} (xHTTP)", safe="")
    hy2_label = quote(f"{domain} (Hysteria 2)", safe="")
    links = [
        f"vless://{quote(vless_secret, safe='')}@{domain}:443?{urlencode(query)}#{vless_label}",
        f"hysteria2://{quote(hy2_secret, safe='')}@{domain}:443/?{urlencode(hy2_query)}#{hy2_label}",
    ]
    for role, row in zip(ROLES, managed_reality(db)):
        stream = json.loads(row[3])
        reality = stream["realitySettings"]
        query = {"type": "tcp" if role.endswith("raw") else "xhttp", "security": "reality",
                 "encryption": json.loads(row[2]).get("encryption", "none"),
                 "sni": reality["serverNames"][0], "fp": "chrome",
                 "pbk": reality["settings"]["publicKey"], "sid": reality["shortIds"][0], "spx": "/"}
        if role.endswith("raw"):
            query["flow"] = "xtls-rprx-vision"
        else:
            query.update(path=stream["xhttpSettings"]["path"], mode="stream-one")
        label = quote(f"{domain} (REALITY {LABELS[role]})", safe="")
        secret = quote(client_secret(db, row, "vless"), safe="")
        links.append(f"vless://{secret}@{domain}:443?{urlencode(query, quote_via=quote)}#{label}")
    return tuple(links)


def validate_runtime(db, port, binary, output):
    """Validate changed inbounds before starting the panel or publishing its route."""
    config = json.loads(db.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
    for row in all_managed_inbounds(db, port):
        listen, inbound_port, protocol, sniffing = db.execute(
            "SELECT listen,port,protocol,sniffing FROM inbounds WHERE id=?", (row[0],),
        ).fetchone()
        settings, stream = json.loads(row[2]), json.loads(row[3])
        if protocol == "vless":
            settings["clients"] = [
                {"id": item[0], "email": item[1], "flow": item[2] or ""}
                for item in db.execute(
                    "SELECT c.uuid,c.email,ci.flow_override FROM clients c "
                    "JOIN client_inbounds ci ON c.id=ci.client_id WHERE ci.inbound_id=? AND c.enable=1", (row[0],),
                )
            ]
        config.setdefault("inbounds", []).append({"tag": row[1], "listen": listen, "port": inbound_port,
            "protocol": protocol, "settings": settings, "streamSettings": stream, "sniffing": json.loads(sniffing)})
    Path(output).touch(mode=0o600)
    Path(output).chmod(0o600)
    Path(output).write_text(json.dumps(config))
    subprocess.run([binary, "run", "-test", "-c", output], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    routing = actions.add_parser("routing")
    routing.add_argument("db")
    routing.add_argument("port", type=int)
    routing.add_argument("block_ru", choices=("y", "n"))
    routing.add_argument("provider", choices=("none", *PROVIDERS))
    routing.add_argument("adopt", choices=("y", "n"))
    for action in ("links", "xhttp-config"):
        export = actions.add_parser(action)
        export.add_argument("db")
        export.add_argument("domain")
        export.add_argument("port", type=int)
    preview = actions.add_parser("preflight")
    preview.add_argument("db")
    preview.add_argument("block_ru", choices=("y", "n"))
    preview.add_argument("provider", choices=("none", *PROVIDERS))
    preview.add_argument("adopt", choices=("y", "n"))
    validate = actions.add_parser("validate")
    validate.add_argument("db"); validate.add_argument("port", type=int)
    validate.add_argument("binary"); validate.add_argument("output")
    args = parser.parse_args()
    try:
        if args.action == "routing":
            with closing(open_db(args.db, "rw")) as db, db:
                apply_routing(db, args.port, args.block_ru == "y", args.provider, args.adopt == "y")
        elif args.action == "preflight":
            with closing(open_db(args.db, "ro")) as db:
                preflight_database(db, args.block_ru == "y", args.provider, args.adopt == "y")
        elif args.action == "validate":
            with closing(open_db(args.db, "ro")) as db:
                validate_runtime(db, args.port, args.binary, args.output)
        elif args.action == "links":
            with closing(open_db(args.db, "ro")) as db:
                print(*export_links(db, args.domain, args.port), sep="\n")
        else:
            with closing(open_db(args.db, "ro")) as db:
                print(json.dumps(export_xhttp_config(db, args.domain, args.port), indent=2))
    except ConfigError as error:
        print(f"vpn-script: {error}", file=sys.stderr)
        return 1
    except (sqlite3.Error, KeyError, TypeError, ValueError, AttributeError, OSError, subprocess.SubprocessError):
        print("vpn-script: cannot read or apply the managed Xray configuration", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
