#!/usr/bin/env python3
"""Offline command doubles. Unknown commands/URLs fail closed: no networking."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["DDNS_TEST_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
if command == "logger":
    sys.exit(0)
if command == "ip":
    data = json.loads((root / "interfaces.json").read_text())
    if "dev" not in args:
        flag = args[0]
        for key, value in data.items():
            if key.startswith(flag + ":"):
                print(value)
        sys.exit(0)
    key = args[0] + ":" + args[args.index("dev") + 1]
    if key not in data:
        sys.exit(1)
    print(data[key])
    sys.exit(0)
if command != "curl":
    sys.exit(91)

def option(name, default=""):
    return args[args.index(name) + 1] if name in args else default

url = option("--url")
if "--config" in args:
    # Consume but NEVER save the secret.
    sys.stdin.read()
method = option("--request", "GET")
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"method": method, "url": url, "payload": option("--data"), "args": args}) + "\n")
if url.startswith("https://api.cloudflare.com/client/v4/zones?per_page=50&page="):
    zones = json.loads((root / "zones.json").read_text())
    print(json.dumps({"success": True, "result": zones,
                      "result_info": {"page": 1, "total_pages": 1}}) +
          "\n__DDNS_HTTP__200", end="")
    sys.exit(0)
if url.startswith("https://api.cloudflare.com/client/v4/zones/"):
    records = json.loads((root / "api.json").read_text())
    zone_id = url.split("/zones/", 1)[1].split("/", 1)[0]
    zone_tail = url.split("/zones/" + zone_id, 1)[1]
    if zone_tail in ("", "/"):
        zones = json.loads((root / "zones.json").read_text())
        zone = next((z for z in zones if z["id"] == zone_id), None)
        if zone is None:
            print('{"success":false}\n__DDNS_HTTP__404', end="")
        else:
            print(json.dumps({"success": True, "result": zone}) + "\n__DDNS_HTTP__200", end="")
        sys.exit(0)
    if not zone_tail.startswith("/dns_records"):
        sys.exit(93)
    endpoint = zone_tail[len("/dns_records"):]
    if endpoint.startswith("?"):
        query = dict(part.split("=", 1) for part in endpoint[1:].split("&"))
        result = [r for r in records.values()
                  if not r.get("fail")
                  and ("type" not in query or r["type"] == query["type"])
                  and ("name" not in query or r["name"] == query["name"])]
        print(json.dumps({"success": True, "result": result}) + "\n__DDNS_HTTP__200", end="")
        sys.exit(0)
    if endpoint == "" and method == "POST":
        record = json.loads(option("--data"))
        record.update(id="created-id", proxied=False)
        print(json.dumps({"success": True, "result": record}) + "\n__DDNS_HTTP__200", end="")
        sys.exit(0)
    record_id = endpoint.lstrip("/")
    if record_id not in records:
        print('{"success":false}\n__DDNS_HTTP__404', end="")
        sys.exit(0)
    record = records[record_id].copy()
    if record.get("fail"):
        print('{"success":false,"errors":[{"message":"DO_NOT_LEAK_RESPONSE"}]}\n__DDNS_HTTP__403', end="")
        sys.exit(0)
    if method == "PATCH":
        record.update(json.loads(option("--data")))
    print(json.dumps({"success": True, "result": record}) + "\n__DDNS_HTTP__200", end="")
elif url.startswith("https://lookup.invalid/"):
    replies = json.loads((root / "http.json").read_text())
    reply = replies[url]
    print(reply["body"] + "\n__DDNS_HTTP__" + str(reply.get("status", 200)), end="")
else:
    sys.exit(92)
