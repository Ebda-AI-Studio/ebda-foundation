#!/usr/bin/env python3
"""Fake Railway GraphQL endpoint for deploy-drift tests. Usage: fake-railway.py <port> <mode>

Railway answers auth and query failures with HTTP 200 + an `errors` array and data=null;
that shape is what made deploy-drift report a dead token as "stuck in status=-".
  unauthorized  200 {"errors":[{"message":"Not Authorized"}],"data":null}
  empty         200 {"data":{"deployments":{"edges":[]}}}
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, MODE = int(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "unauthorized")
BODIES = {
    "unauthorized": {"errors": [{"message": "Not Authorized", "path": ["deployments"]}], "data": None},
    "empty": {"data": {"deployments": {"edges": []}}},
}


class H(BaseHTTPRequestHandler):
    def _send(self, body):
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):  # readiness probe + net-probe preflight
        self._send({"ok": True})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        self._send(BODIES[MODE])

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
