"""HTTP and UDP targets inside the isolated Docker integration network."""

import http.server
import base64
import socket
import ssl
import struct
import threading
import time
import select
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

dns_attempts = 0
doh_queries = 0
doh_mode = "tlsfail"
classic_mode = "normal"


class Target(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global doh_mode
        if self.path.startswith("/classic-mode/"):
            mode = self.path.rsplit("/", 1)[1]
            if mode not in {"normal", "tls12", "no-h2"}:
                self.send_error(400)
                return
            change_classic(mode)
        if self.path.startswith("/doh-mode/"):
            mode = self.path.rsplit("/", 1)[1]
            if mode not in {"success", "tlsfail", "timeout", "private", "ru"}:
                self.send_error(400)
                return
            doh_mode = mode
        body = b"vpn-through-real-client\n"
        if self.path == "/dns-attempts": body = str(dns_attempts).encode()
        if self.path == "/dns-queries": body = str(doh_queries).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class DoH(http.server.BaseHTTPRequestHandler):
    def answer(self, query):
        global doh_queries
        doh_queries += 1
        if doh_mode == "timeout":
            time.sleep(15)
            return
        if len(query) < 17 or struct.unpack("!H", query[4:6])[0] != 1:
            self.send_error(400)
            return
        position = 12
        while position < len(query) and query[position]:
            position += query[position] + 1
        end = position + 5
        question = query[12:end]
        kind = struct.unpack("!H", query[position + 1:position + 3])[0]
        address = {"private": "127.0.0.1", "ru": "77.88.8.8"}.get(doh_mode, "1.1.1.1")
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton(address) if kind == 1 else b""
        response = query[:2] + struct.pack("!HHHHH", 0x8180, 1, int(bool(answer)), 0, 0) + question + answer
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_POST(self):
        self.answer(self.rfile.read(int(self.headers.get("Content-Length", "0"))))

    def do_GET(self):
        if self.path == "/":
            body = b"classic-mask-ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        value = parse_qs(urlsplit(self.path).query)["dns"][0]
        self.answer(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))

    def log_message(self, *_):
        pass


def relay(connection, port=8443):
    with connection, socket.create_connection(("127.0.0.1", port)) as upstream:
        sockets = [connection, upstream]
        while True:
            readable, _, _ = select.select(sockets, [], [], 30)
            if not readable: return
            for source in readable:
                try:
                    data = source.recv(65536)
                    if not data: return
                    (upstream if source is connection else connection).sendall(data)
                except (ConnectionResetError, BrokenPipeError):
                    return  # Negative REALITY/TLS probes intentionally abort handshakes.


def doh_listener():
    global dns_attempts
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", 443))
        listener.listen()
        while True:
            connection, _ = listener.accept()
            # Public fixture IP is the always-on Classic TLS target. Provider
            # requests arrive at the bridge address and retain fault injection.
            if connection.getsockname()[0] == "1.1.1.1":
                threading.Thread(target=relay, args=(connection, 8444), daemon=True).start()
            else:
                # Count only provider attempts. REALITY's independent Classic
                # handshakes must not look like selective-DNS leakage.
                dns_attempts += 1
                if doh_mode == "tlsfail": connection.close()
                else: threading.Thread(target=relay, args=(connection,), daemon=True).start()


def echo_udp():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("1.1.1.1", 443))
        while True:
            packet, peer = sock.recvfrom(65535)
            sock.sendto(packet, peer)


def write_nginx(mode):
    protocols = "TLSv1.2" if mode == "tls12" else "TLSv1.3"
    h2 = "off" if mode == "no-h2" else "on"
    Path("/tmp/qa-doh-nginx.conf").write_text('''
pid /tmp/qa-doh-nginx.pid;
events {}
http { access_log off; server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    ssl_certificate /etc/vpn-qa-doh/cert.pem;
    ssl_certificate_key /etc/vpn-qa-doh/key.pem;
    location / { proxy_pass http://127.0.0.1:18081; }
} server {
    listen 127.0.0.1:8444 ssl;
    http2 ''' + h2 + ''';
    ssl_protocols ''' + protocols + ''';
    ssl_certificate /etc/vpn-qa-doh/cert.pem;
    ssl_certificate_key /etc/vpn-qa-doh/key.pem;
    location / { return 200 "classic-mask-ok"; }
} }
''')


def change_classic(mode):
    global classic_mode
    write_nginx(mode)
    subprocess.run(["nginx", "-t", "-c", "/tmp/qa-doh-nginx.conf"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["nginx", "-c", "/tmp/qa-doh-nginx.conf", "-s", "reload"], check=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # Only a readiness probe inside the fixture.
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.maximum_version = ssl.TLSVersion.TLSv1_2 if mode == "tls12" else ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2", "http/1.1"])
    for _ in range(40):
        try:
            with socket.create_connection(("127.0.0.1", 8444), timeout=1) as connection:
                with context.wrap_socket(connection, server_hostname="classic.qa.test") as tls:
                    if ((tls.version() == "TLSv1.2") if mode == "tls12" else
                            (tls.version() == "TLSv1.3" and tls.selected_alpn_protocol() == ("http/1.1" if mode == "no-h2" else "h2"))):
                        classic_mode = mode
                        return
        except OSError:
            pass
        time.sleep(0.1)
    raise RuntimeError("Classic TLS fixture did not apply the requested mode")


write_nginx("normal")
subprocess.run(["nginx", "-c", "/tmp/qa-doh-nginx.conf"], check=True)
threading.Thread(target=echo_udp, daemon=True).start()
threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", 18081), DoH).serve_forever, daemon=True).start()
threading.Thread(target=doh_listener, daemon=True).start()
http.server.ThreadingHTTPServer(("0.0.0.0", 18080), Target).serve_forever()
