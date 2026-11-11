"""Managed REALITY roles, private listeners, and Classic TLS preflight."""

import argparse
import base64
import ipaddress
import json
import re
import secrets
import socket
import sqlite3
import ssl
import subprocess
import sys
import time
import uuid
from contextlib import closing
from pathlib import Path

REGISTRY_KEY = "vpnScriptInbounds"
ROLES = ("self_raw", "self_xhttp", "classic_raw", "classic_xhttp")
LABELS = {
    "self_raw": "Steal-Oneself RAW", "self_xhttp": "Steal-Oneself xHTTP",
    "classic_raw": "Classic RAW", "classic_xhttp": "Classic xHTTP",
}


def registry(db):
    rows = db.execute("SELECT value FROM settings WHERE key=?", (REGISTRY_KEY,)).fetchall()
    if not rows:
        return {}
    if len(rows) != 1:
        raise ValueError("Conflicting managed inbound registries")
    value = json.loads(rows[0][0])
    if set(value) != {"xhttp_tls", "hy2", *ROLES}:
        raise ValueError("Incomplete managed inbound registry")
    return value


def managed_reality(db):
    saved = registry(db)
    result = []
    for role in ROLES if saved else ():
        item = saved[role]
        rows = db.execute(
            "SELECT id,tag,settings,stream_settings,port,listen,protocol,enable FROM inbounds WHERE id=?",
            (item["id"],),
        ).fetchall()
        if len(rows) != 1:
            raise ValueError("A registered REALITY inbound is missing")
        row = rows[0]
        stream = json.loads(row[3])
        network = "raw" if role.endswith("raw") else "xhttp"
        if (row[1] != item["tag"] or row[4] != item["port"] or row[5] != "127.0.0.1"
                or row[6] != "vless" or row[7] != 1 or stream.get("security") != "reality"
                or stream.get("network") not in ({"raw", "tcp"} if network == "raw" else {"xhttp"})):
            raise ValueError("A registered REALITY inbound was disabled or changed incompatibly")
        result.append(row[:4])
    return result


def validate_target(target, domain, public_addresses=(), syntax_only=False):
    """Connect to the validated addresses themselves, avoiding a second DNS lookup."""
    target = target.lower()
    labels = target.split(".")
    if (len(target) > 253 or len(labels) < 2 or target == domain.lower()
            or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)):
        raise ValueError("Classic target must be a distinct fully qualified domain name")
    if syntax_only:
        return
    local = {
        ipaddress.ip_address(addr["local"].split("%", 1)[0])
        for iface in json.loads(subprocess.check_output(["ip", "-j", "addr", "show"]))
        for addr in iface.get("addr_info", [])
    }
    local.update(ipaddress.ip_address(value) for value in public_addresses if value)
    local.update(ipaddress.ip_address(info[4][0]) for info in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM))
    addresses = sorted({info[4][0] for info in socket.getaddrinfo(target, 443, type=socket.SOCK_STREAM)})
    if not addresses or any(not ipaddress.ip_address(value).is_global or ipaddress.ip_address(value).is_multicast
                            or ipaddress.ip_address(value).is_reserved or ipaddress.ip_address(value) in local for value in addresses):
        raise ValueError("Classic target must resolve only to public addresses outside this node")
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    for address in addresses:
        try:
            connection = socket.create_connection((address, 443), timeout=5)
        except OSError:
            continue
        with connection:
            with context.wrap_socket(connection, server_hostname=target) as tls:
                if tls.version() != "TLSv1.3" or tls.selected_alpn_protocol() != "h2":
                    raise ValueError("Classic target must negotiate TLS 1.3 and HTTP/2")
                return
    raise ValueError("Classic target is unreachable")


def audit(db, metadata):
    saved = registry(db)
    if not saved or saved != metadata.get("inbounds"):
        raise ValueError("Committed role registry differs from the database")
    rows = managed_reality(db)
    private_keys, public_keys, short_ids = set(), set(), set()
    for role, row in zip(ROLES, rows):
        stream = json.loads(row[3])
        reality = stream["realitySettings"]
        expected_name = metadata["domain"] if role.startswith("self") else metadata["reality_target"]
        expected_target = (f"127.0.0.1:{saved[role.replace('_raw', '_xhttp')]['port']}" if role.endswith("raw")
                           else "/dev/shm/nginx-http.sock" if role.startswith("self") else f"{expected_name}:443")
        if (reality.get("serverNames") != [expected_name] or reality.get("target") != expected_target
                or reality.get("xver") != (0 if role == "classic_xhttp" else 1)
                or stream.get("sockopt", {}).get("acceptProxyProtocol") is not True):
            raise ValueError("REALITY chain or PROXY protocol differs from the deployment")
        private_keys.add(reality["privateKey"])
        public_keys.add(reality["settings"]["publicKey"])
        raw_private = base64.urlsafe_b64decode(reality["privateKey"] + "=")
        raw_public = base64.urlsafe_b64decode(reality["settings"]["publicKey"] + "=")
        if len(raw_private) != 32 or len(raw_public) != 32:
            raise ValueError("Invalid REALITY key length")
        # Pass private key material via stdin, never argv or diagnostic output.
        derived = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                                 input=bytes.fromhex("302e020100300506032b656e04220420") + raw_private,
                                 capture_output=True, check=True).stdout
        if derived != bytes.fromhex("302a300506032b656e032100") + raw_public:
            raise ValueError("REALITY public and private keys do not match")
        values = reality["shortIds"]
        if not values or any(not re.fullmatch(r"(?:[a-fA-F0-9]{2}){1,8}", value) for value in values):
            raise ValueError("A REALITY short ID is missing or invalid")
        short_ids.add(values[0])
    if len(private_keys) != 4 or len(public_keys) != 4 or len(short_ids) != 4:
        raise ValueError("REALITY keys and short IDs must be independent")


def audit_runtime(db, filename="/usr/local/x-ui/bin/config.json"):
    runtime = json.loads(Path(filename).read_text())
    saved = registry(db)
    for role in ROLES:
        matches = [item for item in runtime["inbounds"] if item.get("tag") == saved[role]["tag"]]
        if len(matches) != 1:
            raise ValueError("A REALITY runtime inbound is missing or ambiguous")
        item = matches[0]
        if item.get("listen") != "127.0.0.1" or item.get("port") != saved[role]["port"]:
            raise ValueError("A REALITY runtime listener is not isolated")
        flow = "xtls-rprx-vision" if role.endswith("raw") else ""
        if any(client.get("flow", "") != flow for client in item["settings"].get("clients", [])):
            raise ValueError("The panel generated an incompatible REALITY client flow")
        actual = item["streamSettings"]
        expected = json.loads(db.execute("SELECT stream_settings FROM inbounds WHERE id=?", (saved[role]["id"],)).fetchone()[0])
        if actual.get("security") != "reality":
            raise ValueError("The panel omitted REALITY protection")
        for key in ("target", "xver", "serverNames", "privateKey", "shortIds"):
            if actual["realitySettings"].get(key) != expected["realitySettings"].get(key):
                raise ValueError("The panel generated an incompatible REALITY chain")


def allocate_ports(db, excluded):
    saved = registry(db) if db else {}
    if saved:
        managed_reality(db)
        ports = {role: saved[role]["port"] for role in ROLES}
        if len(set(ports.values())) != 4 or set(ports.values()) & set(excluded):
            raise ValueError("Managed REALITY ports conflict")
        return ports
    used = set(excluded)
    if db:
        used.update(row[0] for row in db.execute("SELECT port FROM inbounds"))
    ports = {}
    for role in ROLES:
        for _ in range(1000):
            port = 10000 + secrets.randbelow(49000)
            if port in used:
                continue
            with socket.socket() as probe:
                try:
                    probe.bind(("127.0.0.1", port))
                except OSError:
                    continue
            ports[role] = port
            used.add(port)
            break
        else:
            raise ValueError("No free loopback port for REALITY")
    return ports


def apply(db, domain, target, ports, xray, xhttp_port):
    saved = registry(db)
    if saved:
        managed_reality(db)
    entries = dict(saved)
    for role, protocol, port in (("xhttp_tls", "vless", xhttp_port), ("hy2", "hysteria", 443)):
        rows = db.execute(
            "SELECT id,tag,port FROM inbounds WHERE enable=1 AND port=? AND "
            + ("protocol='vless'" if protocol == "vless" else "protocol IN ('hysteria','hysteria2')"), (port,),
        ).fetchall()
        if len(rows) != 1:
            raise ValueError("Ambiguous original managed inbound")
        row = rows[0]
        entry = dict(zip(("id", "tag", "port"), row))
        if saved and saved[role] != entry:
            raise ValueError("Original managed inbound identity changed")
        entries[role] = entry
    db.execute("BEGIN IMMEDIATE")
    for role in ROLES:
        port = ports[role]
        if role in saved:
            row = db.execute("SELECT settings,stream_settings FROM inbounds WHERE id=?", (saved[role]["id"],)).fetchone()
            settings, stream = map(json.loads, row)
        else:
            tag = "vpn-script:" + role
            if db.execute("SELECT 1 FROM inbounds WHERE tag=? OR (port=? AND protocol='vless')", (tag, port)).fetchone():
                raise ValueError("A foreign inbound conflicts with a REALITY role")
            key_output = subprocess.check_output([xray, "x25519"], text=True)
            keys = dict(line.split(": ", 1) for line in key_output.splitlines() if ": " in line)
            public = keys.get("Password (PublicKey)") or keys.get("PublicKey") or keys.get("Password")
            if not keys.get("PrivateKey") or not public:
                raise ValueError("Xray did not produce a REALITY keypair")
            # The pinned panel gates Vision on its canonical "tcp" spelling;
            # Xray also accepts "raw", but direct DB writes bypass panel normalization.
            stream = {"network": "tcp" if role.endswith("raw") else "xhttp", "security": "reality",
                      "realitySettings": {"show": False, "privateKey": keys["PrivateKey"],
                                          "shortIds": [secrets.token_hex(8)], "settings": {"publicKey": public, "fingerprint": "chrome", "spiderX": "/"}}}
            if role.endswith("xhttp"):
                stream["xhttpSettings"] = {"path": "/api/" + secrets.token_hex(12) + "/", "mode": "stream-one"}
            flow = "xtls-rprx-vision" if role.endswith("raw") else ""
            now = int(time.time() * 1000)
            client = {"id": str(uuid.uuid4()), "email": "vpn-script-" + role + "-" + secrets.token_hex(4), "flow": flow, "enable": True}
            settings = {"clients": [client], "decryption": "none", "encryption": "none"}
            inbound_id = db.execute(
                "INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) "
                "VALUES(1,0,0,0,?,1,0,'127.0.0.1',?,'vless',?,?,?,?)",
                ("REALITY " + LABELS[role], port, json.dumps(settings), json.dumps(stream), tag,
                 json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic"], "metadataOnly": False, "routeOnly": False})),
            ).lastrowid
            client_id = db.execute(
                "INSERT INTO clients(email,uuid,flow,sub_id,enable,created_at,updated_at) VALUES(?,?,?,?,1,?,?)",
                (client["email"], client["id"], flow, secrets.token_urlsafe(18), now, now),
            ).lastrowid
            # This panel treats per-inbound flow_override as authoritative,
            # including an empty value; clients.flow alone does not enable Vision.
            db.execute("INSERT INTO client_inbounds(client_id,inbound_id,flow_override,created_at) VALUES(?,?,?,?)", (client_id, inbound_id, flow, now))
            db.execute("INSERT INTO client_traffics(inbound_id,enable,email,up,down,expiry_time,total,reset) VALUES(?,1,?,0,0,0,0,0)", (inbound_id, client["email"]))
            entries[role] = {"id": inbound_id, "tag": tag, "port": port}
        reality = stream["realitySettings"]
        reality["serverNames"] = [domain if role.startswith("self") else target]
        if role.endswith("raw"):
            reality.update(target=f"127.0.0.1:{ports[role.replace('_raw', '_xhttp')]}", xver=1)
        else:
            reality.update(target="/dev/shm/nginx-http.sock" if role.startswith("self") else f"{target}:443",
                           xver=1 if role.startswith("self") else 0)
        reality.pop("dest", None)
        stream.setdefault("sockopt", {})["acceptProxyProtocol"] = True
        stream["externalProxy"] = [{"forceTls": "same", "dest": domain, "port": 443, "remark": ""}]
        db.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (json.dumps(stream), entries[role]["id"]))
    if saved:
        db.execute("UPDATE settings SET value=? WHERE key=?", (json.dumps(entries), REGISTRY_KEY))
    else:
        db.execute("INSERT INTO settings(key,value) VALUES(?,?)", (REGISTRY_KEY, json.dumps(entries)))
    audit(db, {"inbounds": entries, "domain": domain, "reality_target": target})
    return entries


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("target")
    check.add_argument("target"); check.add_argument("domain"); check.add_argument("addresses", nargs="*")
    check.add_argument("--syntax-only", action="store_true")
    ports = commands.add_parser("ports")
    ports.add_argument("database"); ports.add_argument("excluded", nargs="+", type=int)
    write = commands.add_parser("apply")
    for name in ("database", "domain", "target", "ports", "xray"):
        write.add_argument(name)
    write.add_argument("xhttp_port", type=int)
    verify = commands.add_parser("audit")
    verify.add_argument("database"); verify.add_argument("metadata")
    args = parser.parse_args()
    try:
        if args.command == "target":
            validate_target(args.target, args.domain, args.addresses, args.syntax_only)
        elif args.command == "audit":
            with closing(sqlite3.connect(Path(args.database).resolve().as_uri() + "?mode=ro", uri=True)) as db:
                audit(db, json.loads(Path(args.metadata).read_text()))
                audit_runtime(db)
        elif args.command == "ports":
            if Path(args.database).is_file():
                with closing(sqlite3.connect(Path(args.database).resolve().as_uri() + "?mode=ro", uri=True)) as db:
                    result = allocate_ports(db, args.excluded)
            else:
                result = allocate_ports(None, args.excluded)
            print(json.dumps(result))
        else:
            with closing(sqlite3.connect(args.database)) as db, db:
                entries = apply(db, args.domain, args.target, json.loads(Path(args.ports).read_text()), args.xray, args.xhttp_port)
                print(json.dumps(entries))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError):
        # Never echo DB content, key-generation output, or client identities.
        print("vpn-script: REALITY preflight or configuration failed; verify target TLS/DNS and managed inbound identities", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
