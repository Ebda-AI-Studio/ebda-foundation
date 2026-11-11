#!/usr/bin/env python3
"""Fake HTTP API for the monitor reachable-service tests.

Two modes, both entirely local — no real network call, no production request:

  healthy  /health            -> 200 {"status":"healthy"}
           /api/health        -> 401 (auth-gated; proves the API layer is up)
           /api/auth/login    -> 200 {"data":{"accessToken":"..."}}
           /api/auth/me       -> 200 {"data":{"role":"admin"}}

  error500 every route        -> 500

`error500` exists to prove the fix does not weaken real alerts: a reachable
service returning 5xx must still FAIL and still page, exactly as before.

Usage: fake-msg-api.py <port> [healthy|error500]
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = "healthy"


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _dispatch(self):
        if MODE == "error500":
            self._send_json(500, {"error": {"code": "INTERNAL"}})
            return
        if self.path.startswith("/health"):
            self._send_json(200, {"status": "healthy"})
        elif self.path.startswith("/api/health"):
            # 401 is EXPECTED and proves the API layer is running.
            self._send_json(401, {"error": {"code": "UNAUTHORIZED"}})
        elif self.path.startswith("/api/auth/login"):
            self._send_json(200, {"data": {"accessToken": "fake-probe-token"}})
        elif self.path.startswith("/api/auth/me"):
            self._send_json(200, {"data": {"role": "admin"}})
        else:
            self._send_json(404, {"error": {"code": "NOT_FOUND"}})

    do_GET = _dispatch
    do_POST = _dispatch
    do_HEAD = _dispatch

    def log_message(self, fmt, *args):
        pass  # keep test output quiet


if __name__ == "__main__":
    port = int(sys.argv[1])
    if len(sys.argv) > 2:
        MODE = sys.argv[2]
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
