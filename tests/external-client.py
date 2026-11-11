"""Import issued links from a separate Docker client and check backend isolation."""
import base64
import http.client
import importlib.util
import json
import os
import socket
import ssl
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

spec = importlib.util.spec_from_file_location("client_smoke", Path(__file__).with_name("client-smoke.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
metadata = json.loads(Path("/fixture/config.json").read_text())
ports = [metadata["panel_port"], metadata["xhttp_port"], *[metadata["inbounds"][role]["port"] for role in ("self_raw", "self_xhttp", "classic_raw", "classic_xhttp")]]
for port in ports:
    for host in (metadata["domain"], os.environ["QA_SERVER_IP6"]):
        try:
            with socket.create_connection((host, port), timeout=2):
                raise AssertionError(f"Internal port {port} is externally accessible")
        except OSError:
            pass
print("PASS Separate container cannot access panel, xHTTP or REALITY backend ports over native IPv4/IPv6")
with socket.create_connection((os.environ["QA_SERVER_IP6"], 443), timeout=5) as connection:
    with ssl.create_default_context().wrap_socket(connection, server_hostname=metadata["domain"]) as tls:
        tls.sendall(("GET / HTTP/1.0\r\nHost: " + metadata["domain"] + "\r\n\r\n").encode())
        assert b"200" in tls.recv(1024).split(b"\r\n", 1)[0]
print("PASS Public HTTPS is reachable over native IPv6 with the expected certificate")
credentials = Path("/fixture/credentials").read_text().splitlines()
links = [line for line in credentials if line.startswith(("vless://", "hysteria2://"))]
assert len(links) == 6
architecture = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
xray = f"/usr/local/x-ui/bin/xray-linux-{architecture}"

download_path = metadata["xhttp_download_path"]
password, = [line.split(": ", 1)[1] for line in credentials if line.startswith("xHTTP Download Password: ")]
authorization = "Basic " + base64.b64encode(f"xhttp:{password}".encode()).decode()
connection = http.client.HTTPSConnection(metadata["domain"], timeout=5)
try:
    connection.request("GET", download_path)
    response = connection.getresponse()
    assert response.status == 401
    response.read()
    connection.request("GET", download_path, headers={"Authorization": authorization})
    response = connection.getresponse()
    assert response.status == 200 and response.getheader("Cache-Control") == "private, no-store"
    exported = response.read()
finally:
    connection.close()
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "xhttp.json"
    path.write_bytes(exported)
    process = subprocess.Popen([xray, "run", "-c", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for attempt in range(10):
            try:
                client.fetch(10808)
                break
            except OSError:
                if process.poll() is not None or attempt == 9:
                    raise
                time.sleep(0.2)
    finally:
        process.terminate()
        process.wait(timeout=10)
print("PASS Separate client downloads authenticated xHTTP JSON and transfers traffic with it")

with tempfile.TemporaryDirectory() as directory:
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [{"tag": f"in-{i}", "listen": "127.0.0.1", "port": 10808+i, "protocol": "socks", "settings": {"auth": "noauth"}} for i in range(len(links))],
        "outbounds": [dict(client.import_uri(link), tag=f"out-{i}") for i, link in enumerate(links)],
        "routing": {"rules": [{"type": "field", "inboundTag": [f"in-{i}"], "outboundTag": f"out-{i}"} for i in range(len(links))]},
    }
    path = Path(directory) / "client.json"
    path.write_text(json.dumps(config))
    with open(Path(directory) / "client.log", "w") as log:
        process = subprocess.Popen([xray, "run", "-c", str(path)], stdout=log, stderr=log)
        try:
            for index, protocol in enumerate(client.PROTOCOLS):
                for attempt in range(10):
                    try:
                        client.fetch(10808+index)
                        break
                    except OSError:
                        if process.poll() is not None or attempt == 9: raise
                        time.sleep(0.2)
                print(f"PASS Separate container imports {protocol} URI and receives HTTP payload")
            with ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(client.fetch, range(10808, 10814)))
            print("PASS Six independent imported links transfer traffic concurrently")
        finally:
            process.terminate()
            process.wait(timeout=10)
