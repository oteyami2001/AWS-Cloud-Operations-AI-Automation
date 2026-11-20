"""Monitored sample workload (stdlib only) with token-protected fault injection.

Endpoints
  GET  /                 -> 200 JSON hello
  GET  /health           -> 200, or 503 when the "unhealthy" fault is active
  GET  /work?ms=50       -> burns CPU for N ms (load testing)
  POST /fault/unhealthy  -> make /health fail         (requires X-Fault-Token)
  POST /fault/errors     -> make / return 500 + log ERROR (requires X-Fault-Token)
  POST /fault/reset      -> clear all faults          (requires X-Fault-Token)

The fault token is injected by ECS from AWS Secrets Manager (env FAULT_TOKEN). If FAULT_TOKEN is
unset, fault endpoints are disabled entirely.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO, format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
)
log = logging.getLogger("sample-app")


class FaultState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.unhealthy = False
        self.errors = False

    def set(self, **kwargs: bool) -> None:
        with self._lock:
            for k, v in kwargs.items():
                setattr(self, k, v)


STATE = FaultState()


class Handler(BaseHTTPRequestHandler):
    server_version = "aiops-sample/1.0"

    def log_message(self, fmt: str, *args: object) -> None:  # route access logs through logging
        log.info("access %s %s", self.address_string(), fmt % args)

    def _send(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        path, _, query = self.path.partition("?")
        if path == "/health":
            if STATE.unhealthy:
                log.error("health check failing: dependency 'orders-db' unreachable (fault injected)")
                return self._send(503, {"status": "unhealthy"})
            return self._send(200, {"status": "ok"})
        if path == "/work":
            ms = 50
            for part in query.split("&"):
                if part.startswith("ms="):
                    try:
                        ms = max(0, min(int(part[3:]), 2000))
                    except ValueError:
                        pass
            end = time.perf_counter() + ms / 1000
            while time.perf_counter() < end:
                pass
            return self._send(200, {"worked_ms": ms})
        if path == "/":
            if STATE.errors:
                log.error("Exception: unhandled NullReference in /checkout (fault injected)")
                return self._send(500, {"error": "internal error"})
            return self._send(200, {"service": "aiops-sample", "version": os.environ.get("APP_VERSION", "dev")})
        return self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self.path.startswith("/fault/"):
            return self._send(404, {"error": "not found"})
        token = os.environ.get("FAULT_TOKEN", "")
        supplied = self.headers.get("X-Fault-Token", "")
        if not token or not hmac.compare_digest(token, supplied):
            return self._send(403, {"error": "fault injection disabled or bad token"})
        action = self.path.removeprefix("/fault/")
        if action == "unhealthy":
            STATE.set(unhealthy=True)
        elif action == "errors":
            STATE.set(errors=True)
        elif action == "reset":
            STATE.set(unhealthy=False, errors=False)
        else:
            return self._send(404, {"error": "unknown fault"})
        log.warning("fault state changed: %s", action)
        return self._send(200, {"fault": action, "unhealthy": STATE.unhealthy, "errors": STATE.errors})


def make_server(port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)  # noqa: S104  # nosec B104 - container listens on all interfaces


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    log.info("starting on port %s", port)
    make_server(port).serve_forever()
