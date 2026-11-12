"""A stand-in for the zone's public edge, for tests/cloudflare/: it answers as the declared edge should, from the same
two files the edge probe reads, except where an override of the test names a host, a raw request path and the answer.

Usage: fake_edge.py <tunnel lines json> <zone facts json> <overrides json>
Writes the loopback port it listens on as its first line, then serves until it is ended.
"""

import fnmatch
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote


def read_json(path):
    with open(path) as handle:
        return json.load(handle)


tunnel_lines, zone, overrides = read_json(sys.argv[1]), read_json(sys.argv[2]), read_json(sys.argv[3])
tunnel_hosts = [rule["hostname"] for rule in tunnel_lines["ingress"] if "hostname" in rule]
redirect = zone["redirect"]
apex = [host for host in redirect["hostnames"] if host in tunnel_hosts]


def decoded_path(raw_path):
    decoded = unquote(unquote(raw_path.split("?")[0]))
    while "//" in decoded:
        decoded = decoded.replace("//", "/")
    return decoded.lower()


def is_denied(host, raw_path):
    for denied in zone["hosts"].get(host, {}).get("denied_paths", []):
        if fnmatch.fnmatchcase(decoded_path(raw_path), "/*" + "/*".join(denied.strip("/").lower().split("/")) + "*"):
            return True
    return False


def answer(host, raw_path):
    """Returns status, location and the number of Strict-Transport-Security headers."""
    path = raw_path.split("?")[0]
    if is_denied(host, raw_path):
        return 403, None
    if host in redirect["hostnames"]:
        served = host in apex and (path in redirect["serve"]["pages"] or path.startswith(redirect["serve"]["files"]))
        if served:
            return (404 if path in redirect["serve"].get("not_found", []) else 200), None
        return 302, redirect["target"]
    if path == zone["hosts"].get(host, {}).get("health_path"):
        return 200, None
    return 404, None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        raw_path = self.requestline.split(" ")[1]
        host = self.headers["Host"].split(":")[0]
        status, location = answer(host, raw_path)
        ray, hsts = True, 1
        for override in overrides:
            if override["host"] == host and override["path"] == raw_path:
                status, location = override.get("status", status), override.get("location", location)
                ray, hsts = override.get("ray", ray), override.get("hsts", hsts)
        self.send_response(status)
        if ray:
            self.send_header("CF-RAY", "synthetic-ray")
        if location:
            self.send_header("Location", location)
        for _ in range(hsts):
            self.send_header("Strict-Transport-Security", "max-age=1")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write(f"{server.server_address[1]}\n")
sys.stdout.flush()
server.serve_forever()
