"""
Lightweight uptime/response-time monitor for the blog's public URLs.

Runs a background thread that periodically HTTP-GETs each configured URL,
records success/failure and latency into an in-memory ring buffer per URL,
and serves the results over a tiny HTTP server: a human-readable dashboard,
a JSON status endpoint, a Prometheus /metrics endpoint, and /health for the
k8s readiness/liveness probes.

Stdlib only (no Flask/requests) so the container image stays small and the
build has no external package-index dependency at build time.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TARGET_URLS = [
    u.strip()
    for u in os.environ.get(
        "TARGET_URLS",
        "https://www.kanjtomi1967.net/,https://www.kanjtomi1967.net/search/",
    ).split(",")
    if u.strip()
]
CHECK_INTERVAL_SECONDS = float(os.environ.get("CHECK_INTERVAL_SECONDS", "60"))
TIMEOUT_SECONDS = float(os.environ.get("TIMEOUT_SECONDS", "10"))
HISTORY_SIZE = int(os.environ.get("HISTORY_SIZE", "100"))
PORT = int(os.environ.get("PORT", "8080"))

_lock = threading.Lock()
_state = {
    url: {
        "history": deque(maxlen=HISTORY_SIZE),  # each item: (ts_iso, success, latency_ms, detail)
        "last_checked_at": None,
        "last_success": None,
        "last_latency_ms": None,
        "last_detail": None,
    }
    for url in TARGET_URLS
}


def check_once(url: str) -> None:
    start = time.monotonic()
    success = False
    detail = ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "site-monitor/1.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            status = resp.getcode()
            success = 200 <= status < 400
            detail = f"HTTP {status}"
    except urllib.error.HTTPError as e:
        detail = f"HTTP {e.code}"
    except Exception as e:
        detail = f"{type(e).__name__}: {e}"
    latency_ms = round((time.monotonic() - start) * 1000, 1)
    now = datetime.now(timezone.utc).isoformat()

    with _lock:
        s = _state[url]
        s["history"].append((now, success, latency_ms, detail))
        s["last_checked_at"] = now
        s["last_success"] = success
        s["last_latency_ms"] = latency_ms
        s["last_detail"] = detail


def checker_loop() -> None:
    while True:
        for url in TARGET_URLS:
            check_once(url)
        time.sleep(CHECK_INTERVAL_SECONDS)


def snapshot() -> dict:
    with _lock:
        out = {}
        for url, s in _state.items():
            history = list(s["history"])
            total = len(history)
            successes = sum(1 for _, ok, _, _ in history if ok)
            uptime_ratio = (successes / total) if total else None
            out[url] = {
                "last_checked_at": s["last_checked_at"],
                "last_success": s["last_success"],
                "last_latency_ms": s["last_latency_ms"],
                "last_detail": s["last_detail"],
                "uptime_ratio": uptime_ratio,
                "checks_in_window": total,
            }
        return out


DASHBOARD_TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<title>Site Monitor</title>
<style>
body {{ font-family: system-ui, sans-serif; background: #111; color: #eee; margin: 2rem; }}
h1 {{ font-size: 1.3rem; }}
table {{ border-collapse: collapse; width: 100%; max-width: 900px; }}
th, td {{ text-align: left; padding: 0.5rem 1rem; border-bottom: 1px solid #333; }}
.up {{ color: #4caf50; font-weight: bold; }}
.down {{ color: #f44336; font-weight: bold; }}
.muted {{ color: #888; font-size: 0.85rem; }}
</style>
</head>
<body>
<h1>www.kanjtomi1967.net &mdash; Site Monitor</h1>
<p class="muted">Checks every {interval}s &middot; auto-refreshes every 30s &middot; window: last {history} checks</p>
<table>
<tr><th>URL</th><th>Status</th><th>Latency</th><th>Uptime (window)</th><th>Last checked</th><th>Detail</th></tr>
{rows}
</table>
</body>
</html>
"""


def render_dashboard() -> str:
    rows = []
    for url, s in snapshot().items():
        status_cls = "up" if s["last_success"] else "down"
        status_txt = "UP" if s["last_success"] else "DOWN"
        uptime = f"{s['uptime_ratio'] * 100:.1f}%" if s["uptime_ratio"] is not None else "n/a"
        latency = f"{s['last_latency_ms']} ms" if s["last_latency_ms"] is not None else "n/a"
        rows.append(
            f"<tr><td>{url}</td><td class='{status_cls}'>{status_txt}</td>"
            f"<td>{latency}</td><td>{uptime}</td>"
            f"<td class='muted'>{s['last_checked_at'] or 'n/a'}</td>"
            f"<td class='muted'>{s['last_detail'] or ''}</td></tr>"
        )
    return DASHBOARD_TEMPLATE.format(
        interval=int(CHECK_INTERVAL_SECONDS), history=HISTORY_SIZE, rows="\n".join(rows)
    )


def render_metrics() -> str:
    lines = [
        "# HELP site_monitor_up 1 if the last check succeeded, 0 otherwise",
        "# TYPE site_monitor_up gauge",
    ]
    data = snapshot()
    for url, s in data.items():
        up = 1 if s["last_success"] else 0
        lines.append(f'site_monitor_up{{url="{url}"}} {up}')
    lines += [
        "# HELP site_monitor_response_time_ms Last response time in milliseconds",
        "# TYPE site_monitor_response_time_ms gauge",
    ]
    for url, s in data.items():
        if s["last_latency_ms"] is not None:
            lines.append(f'site_monitor_response_time_ms{{url="{url}"}} {s["last_latency_ms"]}')
    lines += [
        "# HELP site_monitor_uptime_ratio Fraction of successful checks in the retained history window",
        "# TYPE site_monitor_uptime_ratio gauge",
    ]
    for url, s in data.items():
        if s["uptime_ratio"] is not None:
            lines.append(f'site_monitor_uptime_ratio{{url="{url}"}} {s["uptime_ratio"]:.4f}')
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep container logs quiet; failures are visible via /status and /metrics

    def _send(self, status: int, body: str, content_type: str) -> None:
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/health":
            # Always 200: this process being able to answer HTTP at all is the
            # liveness signal. Target-site outages are surfaced via /status and
            # /metrics, not by failing this container's own health check.
            self._send(200, "ok", "text/plain")
        elif self.path == "/status":
            self._send(200, json.dumps(snapshot(), indent=2), "application/json")
        elif self.path == "/metrics":
            self._send(200, render_metrics(), "text/plain; version=0.0.4")
        elif self.path == "/":
            self._send(200, render_dashboard(), "text/html; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")


def main():
    threading.Thread(target=checker_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
