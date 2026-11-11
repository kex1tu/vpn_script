"""Observe additive migration, independent identities, and repeat safety."""
import copy
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from reality import ROLES, allocate_ports, apply, audit, validate_target
from xray_config import all_managed_inbounds, configure_routes, export_links, initial_template, preflight_database


def rejected(function, *args):
    try:
        function(*args)
    except ValueError:
        return
    raise AssertionError("Unsafe or ambiguous state was accepted")


with tempfile.TemporaryDirectory() as directory:
    subprocess.run(["/usr/local/x-ui/x-ui", "migrate"], env=dict(os.environ, XUI_DB_FOLDER=directory, XUI_DB_TYPE="sqlite"), check=True, stdout=subprocess.DEVNULL)
    binary = "/usr/local/x-ui/bin/xray-linux-" + subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip()
    with sqlite3.connect(Path(directory) / "x-ui.db") as db:
        for protocol, port, tag, settings, stream in (
            ("vless", 24680, "original-xhttp", {"clients": [], "encryption": "none"}, {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "/original/", "mode": "stream-one"}}),
            ("hysteria", 443, "original-hy2", {"version": 2}, {"network": "hysteria", "tlsSettings": {"serverName": "test.example.com"}}),
        ):
            db.execute("INSERT INTO inbounds(user_id,up,down,total,enable,listen,protocol,port,tag,settings,stream_settings) VALUES(1,42,77,0,1,'127.0.0.1',?,?,?,?,?)", (protocol, port, tag, json.dumps(settings), json.dumps(stream)))
        for index in (1, 2):
            db.execute("INSERT INTO clients(id,email,uuid,auth,enable) VALUES(?,?,?,?,1)", (index, "original-" + str(index), "11111111-1111-4111-8111-111111111111", "test-hy2"))
            db.execute("INSERT INTO client_inbounds(client_id,inbound_id) VALUES(?,?)", (index, index))
        db.commit()
        before = list(db.execute("SELECT * FROM inbounds ORDER BY id"))
        original_clients = list(db.execute("SELECT * FROM clients ORDER BY id"))
        ports = allocate_ports(db, [24680, 2096, 9443])
        with db:
            roles = apply(db, "test.example.com", "classic.qa.test", ports, binary, 24680)
        assert list(db.execute("SELECT * FROM inbounds WHERE id<=2 ORDER BY id")) == before
        assert list(db.execute("SELECT * FROM clients WHERE id<=2 ORDER BY id")) == original_clients
        assert len(all_managed_inbounds(db, 24680)) == 6
        assert len({row[0] for row in db.execute("SELECT uuid FROM clients WHERE id>2")}) == 4
        assert {row[0] for row in db.execute("SELECT flow FROM clients WHERE id>2")} == {"", "xtls-rprx-vision"}
        for role in ROLES:
            stream = json.loads(db.execute("SELECT stream_settings FROM inbounds WHERE id=?", (roles[role]["id"],)).fetchone()[0])
            flow = db.execute("SELECT flow_override FROM client_inbounds WHERE inbound_id=?", (roles[role]["id"],)).fetchone()[0]
            assert stream["network"] == ("tcp" if role.endswith("raw") else "xhttp")
            assert flow == ("xtls-rprx-vision" if role.endswith("raw") else "")
        metadata = {"domain": "test.example.com", "reality_target": "classic.qa.test", "inbounds": roles}
        audit(db, metadata)
        links = export_links(db, "test.example.com", 24680)
        assert len(links) == 6
        for role, link in zip(ROLES, links[2:]):
            uri = urlsplit(link); query = parse_qs(uri.query)
            assert uri.hostname == "test.example.com" and uri.port == 443 and query["security"] == ["reality"]
            assert query["sni"] == ["test.example.com" if role.startswith("self") else "classic.qa.test"]
            assert (query.get("flow") == ["xtls-rprx-vision"]) == role.endswith("raw")
        config = initial_template()
        configure_routes(config, [row[1] for row in all_managed_inbounds(db, 24680)], True, "xboxdns", False)
        assert all(len(rule["inboundTag"]) == 6 for rule in config["routing"]["rules"] if rule.get("ruleTag", "").startswith("vpn-script:"))
        state = list(db.iterdump())
        with db:
            assert roles == apply(db, "test.example.com", "classic.qa.test", ports, binary, 24680)
        assert state == list(db.iterdump()) and links == export_links(db, "test.example.com", 24680)
        assert ports == allocate_ports(db, [24680, 2096, 9443])
        preflight_database(db, False, "none", False)
        with db:
            db.execute("UPDATE inbounds SET up=1234,down=5678 WHERE id>2")
        identities = list(db.execute("SELECT id,tag,up,down FROM inbounds ORDER BY id"))
        clients = list(db.execute("SELECT * FROM clients ORDER BY id"))
        with db:
            apply(db, "test.example.com", "classic-alt.qa.test", ports, binary, 24680)
        metadata["reality_target"] = "classic-alt.qa.test"
        audit(db, metadata)
        assert identities == list(db.execute("SELECT id,tag,up,down FROM inbounds ORDER BY id"))
        assert clients == list(db.execute("SELECT * FROM clients ORDER BY id"))
        for old, new in zip(links, export_links(db, "test.example.com", 24680)):
            assert urlsplit(old).username == urlsplit(new).username
            old_query, new_query = parse_qs(urlsplit(old).query), parse_qs(urlsplit(new).query)
            for name in ("pbk", "sid", "path"):
                assert old_query.get(name) == new_query.get(name)
        broken = copy.deepcopy(metadata); broken["inbounds"]["self_raw"]["port"] += 1
        rejected(audit, db, broken)
        with db:
            db.execute("UPDATE inbounds SET listen='0.0.0.0' WHERE id=?", (roles["self_raw"]["id"],))
        rejected(audit, db, metadata)
        with db:
            db.execute("UPDATE inbounds SET listen='127.0.0.1' WHERE id=?", (roles["self_raw"]["id"],))
            db.execute("DELETE FROM settings WHERE key='vpnScriptInbounds'")
        try:
            with db:
                apply(db, "test.example.com", "classic.qa.test", ports, binary, 24680)
        except ValueError:
            pass
        else:
            raise AssertionError("Foreign role collision was adopted")
        assert list(db.execute("SELECT * FROM clients ORDER BY id")) == clients
        assert db.execute("SELECT count(*) FROM inbounds").fetchone()[0] == 6
    for target in ("localhost", "test.example.com", "bad;include.conf", "https://example.com", "example.com:443", "a..example.com"):
        rejected(validate_target, target, "test.example.com", (), True)
    rejected(validate_target, "127.0.0.1", "localhost")
print("PASS REALITY additive upgrade, repeat, target changes, preserved identities/counters and rejected unsafe states")
