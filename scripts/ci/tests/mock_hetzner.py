#!/usr/bin/env python3
"""A mock of the Hetzner Cloud API for scripts/ci/tests/teardown-destroy-test.sh:
just enough for the real hcloud Terraform provider to create, read, and
delete volumes and Primary IPs and read the FDE image, and for
scripts/ci/teardown.sh to list and unprotect. It enforces delete protection
as the real API does (teardown.yml's first production run hit it): DELETE on
a protected resource -> 423 {"error": {"code": "protected"}}. Every request
is logged as "METHOD path -> status".

usage: mock_hetzner.py <port> <request-log>
"""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
NOW = "2026-10-04T00:00:00+00:00"
LOC = {"id": 2, "name": "nbg1", "description": "Nuremberg DC Park 1", "country": "DE", "city": "Nuremberg",
       "latitude": 49.45, "longitude": 11.07, "network_zone": "eu-central"}
DC = {"id": 2, "name": "nbg1-dc3", "description": "Nuremberg 1 virtual DC 3", "location": LOC,
      "server_types": {"supported": [], "available": [], "available_for_migration": []}}
SINGULAR = {"volumes": "volume", "primary_ips": "primary_ip", "images": "image", "servers": "server",
            "firewalls": "firewall", "ssh_keys": "ssh_key", "floating_ips": "floating_ip",
            "networks": "network", "load_balancers": "load_balancer"}
store = {c: {} for c in SINGULAR}
store["images"][439234041] = {
    "id": 439234041, "type": "snapshot", "status": "available", "name": None,
    "description": "fde-ubuntu-26.04-1791053558", "image_size": 2.1, "disk_size": 80, "created": NOW,
    "created_from": {"id": 1, "name": "packer-fde-build"}, "bound_to": None, "os_flavor": "ubuntu",
    "os_version": "26.04", "rapid_deploy": False, "protection": {"delete": False}, "deprecated": None,
    "deleted": None, "labels": {"fde": "true", "role": "menegroth-server-base"}, "architecture": "x86"}
next_id = [107025634]


def action(command):
    next_id[0] += 1
    return {"id": next_id[0], "command": command, "status": "success", "progress": 100, "started": NOW,
            "finished": NOW, "resources": [], "error": None}


def matches(obj, q):
    sel = q.get("label_selector", [""])[0]
    for term in filter(None, sel.split(",")):
        k, _, v = term.partition("=")
        if obj.get("labels", {}).get(k) != v:
            return False
    if "type" in q and obj.get("type") not in q["type"]:
        return False
    if "name" in q and obj.get("name") != q["name"][0]:
        return False
    if "architecture" in q and obj.get("architecture") not in q["architecture"]:
        return False
    return True


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path} -> {code}\n")

    def route(self):
        u = urllib.parse.urlparse(self.path)
        parts = [p for p in u.path.split("/") if p][1:]  # drop "v1"
        q = urllib.parse.parse_qs(u.query)
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        return parts, q, body

    def do_GET(self):
        parts, q, _ = self.route()
        if parts and parts[-1] == "actions" or (len(parts) >= 2 and parts[-2] == "actions"):
            ids = [int(i) for i in q.get("id", [])] or ([int(parts[-1])] if parts[-1].isdigit() else [])
            if parts[-1].isdigit():
                return self.send(200, {"action": action("x") | {"id": ids[0]}})
            return self.send(200, {"actions": [action("x") | {"id": i} for i in ids],
                                   "meta": {"pagination": {"page": 1, "per_page": 50, "next_page": None,
                                                           "previous_page": None, "last_page": 1,
                                                           "total_entries": len(ids)}}})
        coll = parts[0]
        if coll not in store:
            return self.send(404, {"error": {"code": "not_found", "message": f"unknown {coll}"}})
        if len(parts) == 2:
            obj = store[coll].get(int(parts[1]))
            if obj is None:
                return self.send(404, {"error": {"code": "not_found", "message": f"{SINGULAR[coll]} not found"}})
            return self.send(200, {SINGULAR[coll]: obj})
        items = [o for o in store[coll].values() if matches(o, q)]
        page, per = int(q.get("page", ["1"])[0]), int(q.get("per_page", ["25"])[0])
        chunk = items[(page - 1) * per:page * per]
        nxt = page + 1 if page * per < len(items) else None
        self.send(200, {coll: chunk, "meta": {"pagination": {"page": page, "per_page": per, "next_page": nxt,
                                                             "previous_page": None, "last_page": 1,
                                                             "total_entries": len(items)}}})

    def do_POST(self):
        parts, _, body = self.route()
        coll = parts[0]
        if len(parts) == 4 and parts[2] == "actions" and parts[3] == "change_protection":
            obj = store[coll][int(parts[1])]
            for k in ("delete", "rebuild"):
                if k in body:
                    obj["protection"][k] = body[k]
            return self.send(201, {"action": action("change_protection")})
        next_id[0] += 1
        oid = next_id[0]
        if coll == "volumes":
            obj = {"id": oid, "name": body["name"], "size": body["size"], "server": None, "location": LOC,
                   "linux_device": f"/dev/disk/by-id/scsi-0HC_Volume_{oid}", "protection": {"delete": False},
                   "labels": body.get("labels") or {}, "status": "available", "created": NOW, "format": None}
            store[coll][oid] = obj
            return self.send(201, {"volume": obj, "action": action("create_volume"), "next_actions": []})
        if coll == "primary_ips":
            v4 = body["type"] == "ipv4"
            obj = {"id": oid, "name": body["name"], "type": body["type"],
                   "ip": "2.28.122.7" if v4 else "2a01:4f8:1c1c:7e06::/64",
                   "dns_ptr": [], "assignee_id": None, "assignee_type": "server",
                   "auto_delete": body.get("auto_delete", False), "blocked": False, "created": NOW,
                   "datacenter": DC, "location": LOC, "protection": {"delete": False},
                   "labels": body.get("labels") or {}}
            store[coll][oid] = obj
            return self.send(201, {"primary_ip": obj, "action": action("create_primary_ip")})
        self.send(400, {"error": {"code": "invalid_input", "message": f"mock can't create {coll}"}})

    def do_DELETE(self):
        parts, _, _ = self.route()
        coll, oid = parts[0], int(parts[1])
        obj = store[coll].get(oid)
        if obj is None:
            return self.send(404, {"error": {"code": "not_found", "message": "not found"}})
        if obj.get("protection", {}).get("delete"):
            what = {"volumes": "volume", "primary_ips": "Primary IP"}.get(coll, coll)
            return self.send(423, {"error": {"code": "protected", "message": f"{what} deletion is protected"}})
        del store[coll][oid]
        if coll == "servers":
            return self.send(200, {"action": action("delete_server")})
        self.send(204)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
