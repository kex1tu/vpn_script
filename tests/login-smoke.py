"""Verify real HTTP login using the issued credentials and a rejected default pair."""

import http.cookiejar
import json
import sys
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener


fields = dict(line.split(": ", 1) for line in Path(sys.argv[1]).read_text().splitlines() if ": " in line)
base = fields["Panel URL"]
address = urlsplit(base)
origin = f"{address.scheme}://{address.netloc}"
for username, password, expected in ((fields["Username"], fields["Password"], True), ("admin", "admin", False)):
    opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(http.cookiejar.CookieJar()))
    with opener.open(base + "csrf-token", timeout=5) as response:
        token = json.load(response)["obj"]
    request = Request(base + "login", data=urlencode({"username": username, "password": password}).encode(), headers={
        "X-CSRF-Token": token, "X-XSRF-TOKEN": token, "Origin": origin, "Referer": base,
    })
    with opener.open(request, timeout=5) as response:
        assert json.load(response)["success"] is expected, "Unexpected panel authentication result"
print("PASS Issued panel credentials authenticate and admin/admin is rejected")
