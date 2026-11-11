"""Import exported URIs into real Xray clients and transfer an HTTP response."""

import json
import copy
import http.client
import ipaddress
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

PROTOCOLS = ("VLESS xHTTP", "Hysteria 2", "Self RAW", "Self xHTTP", "Classic RAW", "Classic xHTTP")


def import_uri(raw):
    uri = urlsplit(raw)
    query = {key: value[0] for key, value in parse_qs(uri.query).items()}
    # The isolated fixture CA is installed in the container's system store.
    tls = {"serverName": query.get("sni", uri.hostname), "useSystemCA": True}
    if uri.scheme == "vless":
        settings = {
            "vnext": [{"address": uri.hostname, "port": uri.port or 443, "users": [{
                "id": unquote(uri.username), "encryption": query.get("encryption", "none"),
                "flow": query.get("flow", ""),
            }]}],
        }
        network = "raw" if query.get("type") in {"tcp", "raw"} else "xhttp"
        security = query.get("security", "tls")
        stream = {"network": network, "security": security}
        if network == "xhttp":
            stream["xhttpSettings"] = {
                "path": query["path"], "host": query.get("host", uri.hostname),
                "mode": query["mode"], **json.loads(query.get("extra", "{}")),
            }
        if security == "reality":
            stream["realitySettings"] = {"serverName": query["sni"], "fingerprint": query["fp"],
                                         "password": query["pbk"], "shortId": query["sid"], "spiderX": query.get("spx", "/")}
        else:
            stream["tlsSettings"] = tls
        return {"protocol": "vless", "settings": settings, "streamSettings": stream}
    if uri.scheme == "hysteria2":
        return {
            "protocol": "hysteria", "settings": {"version": 2, "address": uri.hostname, "port": uri.port or 443},
            "streamSettings": {
                "network": "hysteria", "security": "tls", "tlsSettings": tls,
                "hysteriaSettings": {"version": 2, "auth": unquote(uri.username)},
            },
        }
    raise ValueError("Unsupported test client URI")


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise OSError("SOCKS connection closed")
        data += chunk
    return data


def socks_command(port, command, host, destination_port):
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        sock.settimeout(3)
        sock.sendall(b"\x05\x01\x00")
        assert recv_exact(sock, 2) == b"\x05\x00"
        try:
            address = ipaddress.ip_address(host)
            destination = bytes([1 if address.version == 4 else 4]) + address.packed
        except ValueError:
            encoded = host.encode("ascii")
            destination = bytes([3, len(encoded)]) + encoded
        sock.sendall(bytes([5, command, 0]) + destination + struct.pack("!H", destination_port))
        header = recv_exact(sock, 4)
        if header[1] != 0:
            raise OSError("SOCKS destination rejected")
        address_length = {1: 4, 4: 16}.get(header[3])
        if address_length is None:
            address_length = recv_exact(sock, 1)[0]
        address = recv_exact(sock, address_length)
        bind_port = struct.unpack("!H", recv_exact(sock, 2))[0]
        return sock, bind_port
    except BaseException:
        sock.close()
        raise


def fetch(port, host="1.1.1.1", timeout=3):
    sock, _ = socks_command(port, 1, host, 18080)
    with sock:
        sock.settimeout(timeout)
        authority = f"[{host}]" if ":" in host else host
        request = f"GET /vpn-test.txt HTTP/1.0\r\nHost: {authority}:18080\r\n\r\n"
        sock.sendall(request.encode("ascii"))
        response = b""
        while len(response) < 65536:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
            if b"\r\n\r\n" in response and b"vpn-through-real-client" in response.split(b"\r\n\r\n", 1)[1]:
                break
        if b"vpn-through-real-client" not in response:
            raise OSError("Test HTTP payload was not delivered")


def echo_udp(port):
    association, bind_port = socks_command(port, 3, "0.0.0.0", 0)
    with association, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(3)
        payload = b"vpn-through-real-udp"
        packet = b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1") + struct.pack("!H", 443) + payload
        udp.sendto(packet, ("127.0.0.1", bind_port))
        response, _ = udp.recvfrom(65535)
        if not response.endswith(payload):
            raise OSError("UDP payload was not delivered")


def expect_blocked(function, *args):
    try:
        function(*args)
    except OSError:
        return
    raise AssertionError("A blocked destination was reachable")


def dns_attempt_count(path="/dns-attempts"):
    connection = http.client.HTTPConnection(os.environ["QA_TARGET_GATEWAY"], 18080, timeout=3)
    try:
        connection.request("GET", path)
        return int(connection.getresponse().read())
    finally:
        connection.close()


def main():
    mode = sys.argv[2] if len(sys.argv) > 2 else "n"
    dns_before = dns_attempt_count() if mode.startswith("dns") else 0
    queries_before = dns_attempt_count("/dns-queries") if mode == "dns-success" else 0
    for host in ("127.0.0.1", "::1", "1.1.1.1", "77.88.8.8"):
        connection = http.client.HTTPConnection(host, 18080, timeout=3)
        try:
            connection.request("GET", "/vpn-test.txt")
            assert b"vpn-through-real-client" in connection.getresponse().read()
        finally:
            connection.close()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(3)
        udp.sendto(b"direct-udp-probe", ("1.1.1.1", 443))
        reply, peer = udp.recvfrom(1024)
        assert reply == b"direct-udp-probe" and peer[0] == "1.1.1.1"
    links = [line for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith(("vless://", "hysteria2://"))]
    assert len(links) == 6
    with tempfile.TemporaryDirectory() as directory:
        outbounds = [dict(import_uri(link), tag=f"out-{i}") for i, link in enumerate(links)]
        udp_ports = {}
        for index, outbound in enumerate(outbounds[:]):
            if outbound["streamSettings"]["network"] == "raw":
                probe = copy.deepcopy(outbound)
                probe["settings"]["vnext"][0]["users"][0]["flow"] = "xtls-rprx-vision-udp443"
                probe["tag"] = f"out-{len(outbounds)}"
                udp_ports[index] = 10808 + len(outbounds)
                outbounds.append(probe)
        # Normal TCP tests import the six issued URIs unchanged. UDP/443 needs
        # Vision's explicit client opt-in to observe server-side RU policy.
        config = {
            "log": {"loglevel": "debug"},
            "inbounds": [{"tag": f"in-{i}", "listen": "127.0.0.1", "port": 10808+i, "protocol": "socks", "settings": {"auth": "noauth", "udp": True}} for i in range(len(outbounds))],
            "outbounds": outbounds,
            "routing": {"rules": [{"type": "field", "inboundTag": [f"in-{i}"], "outboundTag": f"out-{i}"} for i in range(len(outbounds))]},
        }
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(config))
        arch = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
        with (Path(directory) / "client.log").open("w+") as log:
            process = subprocess.Popen([f"/usr/local/x-ui/bin/xray-linux-{arch}", "run", "-c", str(path)], stdout=log, stderr=log)
            try:
                for i, name in enumerate(PROTOCOLS):
                    for attempt in range(8):
                        try:
                            fetch(10808+i)
                            break
                        except OSError:
                            if process.poll() is not None or attempt == 7:
                                log.seek(0)
                                print(log.read()[-7000:], file=sys.stderr)
                                raise
                            time.sleep(0.2)
                    print(f"PASS {name} imported URI delivers the test HTTP payload")
                    expect_blocked(fetch, 10808+i, "127.0.0.1")
                    expect_blocked(fetch, 10808+i, "::1")
                    print(f"PASS {name} rejects private IPv4 and IPv6 destinations")
                    if mode.startswith("dns"):
                        ordinary_before = dns_attempt_count()
                        fetch(10808+i, "qa-ordinary.test")
                        assert dns_attempt_count() == ordinary_before, "Ordinary domains leaked into the selective DoH profile"
                        if mode in {"dns-private", "dns-ru"}:
                            expect_blocked(fetch, 10808+i, "qa-doh.test")
                        else:
                            fetch(10808+i, "qa-doh.test", 15 if mode == "dns-timeout" else 3)
                        assert dns_attempt_count() > dns_before, "The selected DoH endpoint was not tried"
                        if mode == "dns-success":
                            assert dns_attempt_count("/dns-queries") > queries_before, "No authenticated DoH request reached the resolver"
                        print(f"PASS {name} selected-domain DNS works in {mode} mode")
                        continue
                    blocked = mode == "blocked"
                    for host in ("77.88.8.8", "rutracker.org"):
                        if blocked:
                            expect_blocked(fetch, 10808+i, host)
                        else:
                            fetch(10808+i, host)
                    if blocked:
                        expect_blocked(echo_udp, udp_ports.get(i, 10808+i))
                    else:
                        echo_udp(udp_ports.get(i, 10808+i))
                    print(f"PASS {name} RU-IP, RU-domain on a foreign IP and UDP/443 in mode {'y' if blocked else 'n'}")

            except BaseException:
                log.seek(0)
                print(log.read()[-5000:], file=sys.stderr)
                raise
            finally:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    main()
