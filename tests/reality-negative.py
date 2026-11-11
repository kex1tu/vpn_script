"""Bad REALITY key/short ID/SNI must never grant proxy access."""
import copy
import importlib.util
import json
import secrets
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

spec = importlib.util.spec_from_file_location("smoke", Path(__file__).with_name("client-smoke.py"))
smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)
links = [line for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith("vless://") and "security=reality" in line]
assert len(links) == 4
outbounds = []
for link in links:
    for fault in ("key", "sid", "sni"):
        outbound = copy.deepcopy(smoke.import_uri(link))
        reality = outbound["streamSettings"]["realitySettings"]
        if fault == "key": reality["password"] = secrets.token_urlsafe(32)
        elif fault == "sid": reality["shortId"] = format(int(reality["shortId"], 16) ^ 1, "016x")
        else: reality["serverName"] = "unmatched.qa.test"
        outbound["tag"] = "out-" + str(len(outbounds))
        outbounds.append(outbound)
with tempfile.TemporaryDirectory() as directory:
    config = {"log": {"loglevel": "none"}, "inbounds": [
        {"tag": f"in-{i}", "listen": "127.0.0.1", "port": 10900+i, "protocol": "socks", "settings": {"auth": "noauth"}}
        for i in range(len(outbounds))], "outbounds": outbounds,
        "routing": {"rules": [{"type": "field", "inboundTag": [f"in-{i}"], "outboundTag": f"out-{i}"} for i in range(len(outbounds))]}}
    path = Path(directory) / "negative.json"; path.write_text(json.dumps(config)); path.chmod(0o600)
    architecture = subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
    process = subprocess.Popen([f"/usr/local/x-ui/bin/xray-linux-{architecture}", "run", "-c", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(30):
            if process.poll() is not None: raise AssertionError("Negative test client configuration failed")
            try:
                with smoke.socket.create_connection(("127.0.0.1", 10911), timeout=1): break
            except OSError: time.sleep(0.1)
        else: raise AssertionError("Negative test SOCKS listeners did not start")
        def blocked(port):
            try: smoke.fetch(port, timeout=2)
            except OSError: return
            raise AssertionError("An invalid REALITY identity granted proxy access")
        with ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(blocked, range(10900, 10912)))
    finally:
        process.terminate(); process.wait(timeout=5)
print("PASS Four REALITY profiles reject incorrect keys, short IDs and SNI")
