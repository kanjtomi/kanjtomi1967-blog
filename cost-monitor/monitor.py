"""AWS cost monitor (stdlib only).

Every FETCH_INTERVAL_HOURS it asks AWS Cost Explorer for
  1. daily unblended cost per service, from the 1st of last month to today
  2. the forecast for the rest of this month
and serves the result on PORT:
  /         HTML dashboard
  /status   JSON snapshot
  /metrics  Prometheus text format
  /health   200 while the process is up

Cost Explorer charges $0.01 per API request, so each fetch makes exactly two
requests (plus one per extra result page) and the process never fetches more
often than FETCH_INTERVAL_HOURS - not even on demand. A pod restart does one
extra fetch.

Requests are signed with AWS Signature Version 4 by hand so the image needs no
boto3. Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
(a k8s Secret); the IAM user only has ce:GetCostAndUsage and ce:GetCostForecast.
"""
import hashlib
import hmac
import html
import json
import os
import statistics
import threading
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
FETCH_INTERVAL_HOURS = float(os.environ.get("FETCH_INTERVAL_HOURS", "24"))
MONTHLY_BUDGET_USD = float(os.environ.get("MONTHLY_BUDGET_USD", "10"))
DAILY_ALERT_USD = float(os.environ.get("DAILY_ALERT_USD", "1.0"))
SPIKE_RATIO = float(os.environ.get("SPIKE_RATIO", "2.0"))
SHOW_DAYS = int(os.environ.get("SHOW_DAYS", "14"))
MIN_SERVICE_USD = float(os.environ.get("MIN_SERVICE_USD", "0.01"))
AKID = os.environ.get("AWS_ACCESS_KEY_ID", "")
SECRET = os.environ.get("AWS_SECRET_ACCESS_KEY", "")

HOST = "ce.us-east-1.amazonaws.com"
REGION = "us-east-1"

state = {
    "last_fetch": None,       # ISO time of the last successful fetch
    "last_error": None,
    "fetch_errors": 0,
    "api_requests": 0,        # Cost Explorer requests made by this process ($0.01 each)
    "days": [],               # ["2026-11-01", ...]
    "daily": {},              # service -> {day: usd}
    "month_to_date": 0.0,
    "last_month": 0.0,
    "forecast": None,         # this month's total, actual + AWS forecast
    "pace": None,             # this month's total, actual + (last day's cost x days left)
    "latest": None,           # last day Cost Explorer has data for
    "alerts": [],
}
lock = threading.Lock()


def log(msg):
    print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg, flush=True)


# ---------------------------------------------------------------- AWS SigV4
def _hmac(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def ce_call(target, payload):
    body = json.dumps(payload).encode()
    now = datetime.now(timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    headers = {
        "content-type": "application/x-amz-json-1.1",
        "host": HOST,
        "x-amz-date": amz_date,
        "x-amz-target": "AWSInsightsIndexService." + target,
    }
    signed = ";".join(sorted(headers))
    canonical = "\n".join([
        "POST", "/", "",
        "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
        signed,
        hashlib.sha256(body).hexdigest(),
    ])
    scope = f"{day}/{REGION}/ce/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical.encode()).hexdigest()])
    key = _hmac(_hmac(_hmac(_hmac(("AWS4" + SECRET).encode(), day), REGION), "ce"), "aws4_request")
    sig = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={AKID}/{scope}, "
                                f"SignedHeaders={signed}, Signature={sig}")
    req = urllib.request.Request(f"https://{HOST}/", data=body, headers=headers, method="POST")
    with lock:
        state["api_requests"] += 1
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{target}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")


# ---------------------------------------------------------------- fetching
def fetch():
    today = datetime.now(timezone.utc).date()
    first_this = today.replace(day=1)
    first_last = (first_this - timedelta(days=1)).replace(day=1)
    first_next = (first_this + timedelta(days=32)).replace(day=1)

    daily = {}
    days = []
    token = None
    while True:
        q = {
            "TimePeriod": {"Start": first_last.isoformat(), "End": today.isoformat()},
            "Granularity": "DAILY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
        }
        if token:
            q["NextPageToken"] = token
        res = ce_call("GetCostAndUsage", q)
        for r in res["ResultsByTime"]:
            d = r["TimePeriod"]["Start"]
            if d not in days:
                days.append(d)
            for g in r.get("Groups", []):
                usd = float(g["Metrics"]["UnblendedCost"]["Amount"])
                daily.setdefault(g["Keys"][0], {})[d] = usd
        token = res.get("NextPageToken")
        if not token:
            break

    forecast = None
    try:
        res = ce_call("GetCostForecast", {
            "TimePeriod": {"Start": today.isoformat(), "End": first_next.isoformat()},
            "Metric": "UNBLENDED_COST", "Granularity": "MONTHLY"})
        forecast = float(res["Total"]["Amount"])
    except Exception as e:   # not enough history, or the last day of the month
        log(f"forecast unavailable: {e}")

    def total(start, end):
        return sum(v for s in daily.values() for d, v in s.items() if start.isoformat() <= d < end.isoformat())

    days = sorted(days)
    mtd = total(first_this, today)
    # Cost Explorer lags 1-2 days: the newest days come back empty. "latest" is the last day with any cost.
    day_total = {d: sum(s.get(d, 0.0) for s in daily.values()) for d in days}
    with_data = [d for d in days if day_total[d] >= 0.005]
    latest = with_data[-1] if with_data else None
    pace = None
    if latest:
        recent = [day_total[latest]]   # one day: reacts at once when something is stopped or started
        remaining = (first_next - (date.fromisoformat(latest) + timedelta(days=1))).days
        pace = mtd + statistics.mean(recent) * max(remaining, 0)
    with lock:
        state.update(days=days, daily=daily, month_to_date=mtd, latest=latest, pace=pace,
                     last_month=total(first_last, first_this),
                     forecast=(mtd + forecast) if forecast is not None else None,
                     last_fetch=datetime.now(timezone.utc).isoformat(timespec="seconds"),
                     last_error=None)
        state["alerts"] = find_alerts()
    for a in state["alerts"]:
        log("ALERT " + a)
    log(f"fetched: month-to-date ${mtd:.2f}, pace {pace}, AWS forecast {state['forecast']}, "
        f"latest day {latest}, {len(daily)} services, api requests so far {state['api_requests']}")


def find_alerts():
    """Called with the lock held."""
    alerts = []
    days, latest, pace = state["days"], state["latest"], state["pace"]
    # Budget: judged on the recent pace, because AWS's forecast keeps extrapolating a spike for
    # days after it has been stopped (seen 2026-11-16: forecast $115 while the pace was ~$60).
    if pace is not None and pace > MONTHLY_BUDGET_USD:
        alerts.append(f"今月の見込み ${pace:.2f} (直近 1 日のペース) が予算 ${MONTHLY_BUDGET_USD:.2f} を超えています")
    elif state["month_to_date"] > MONTHLY_BUDGET_USD:
        alerts.append(f"今月の実績 ${state['month_to_date']:.2f} が予算 ${MONTHLY_BUDGET_USD:.2f} を超えています")
    if not latest:
        return alerts
    i = days.index(latest)
    for svc, by_day in state["daily"].items():
        v = by_day.get(latest, 0.0)
        prev = [by_day.get(d, 0.0) for d in days[max(0, i - 7):i]]
        base = statistics.median(prev) if prev else 0.0
        if v >= DAILY_ALERT_USD and v > base * SPIKE_RATIO:
            alerts.append(f"{svc}: {latest} は ${v:.2f} (直前 7 日の中央値 ${base:.2f} の {v / base:.1f} 倍)"
                          if base > 0 else f"{svc}: {latest} は ${v:.2f} (直前 7 日はほぼ 0)")
        elif v >= DAILY_ALERT_USD * 3:
            alerts.append(f"{svc}: {latest} は ${v:.2f}/日 (月 ${v * 30:.0f} ペース)")
    return alerts


def fetch_loop():
    while True:
        try:
            fetch()
        except Exception as e:
            with lock:
                state["fetch_errors"] += 1
                state["last_error"] = f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {e}"
            log(f"fetch failed: {e}")
        time.sleep(FETCH_INTERVAL_HOURS * 3600)


# ---------------------------------------------------------------- output
def snapshot():
    with lock:
        return json.loads(json.dumps(state))


def metrics():
    s = snapshot()
    out = []

    def m(name, help_, typ, rows):
        out.append(f"# HELP {name} {help_}\n# TYPE {name} {typ}")
        for labels, v in rows:
            lab = ",".join(f'{k}="{str(val).replace(chr(34), "")}"' for k, val in labels.items())
            out.append(f"{name}{{{lab}}} {v}" if lab else f"{name} {v}")

    m("aws_cost_month_to_date_usd", "Unblended cost of this month so far", "gauge", [({}, s["month_to_date"])])
    m("aws_cost_last_month_usd", "Unblended cost of last month", "gauge", [({}, s["last_month"])])
    if s["forecast"] is not None:
        m("aws_cost_forecast_month_usd", "This month's total, actual + AWS forecast", "gauge", [({}, s["forecast"])])
    if s["pace"] is not None:
        m("aws_cost_pace_month_usd", "This month's total, actual + the last day's cost for the days left", "gauge", [({}, round(s["pace"], 6))])
    m("aws_cost_monthly_budget_usd", "Configured monthly budget", "gauge", [({}, MONTHLY_BUDGET_USD)])
    days = s["days"]
    latest = s["latest"]
    if latest:
        first_this = date.today().replace(day=1).isoformat()
        rows_d, rows_m = [], []
        for svc, by_day in s["daily"].items():
            if by_day.get(latest, 0) >= MIN_SERVICE_USD:
                rows_d.append(({"service": svc}, by_day[latest]))
            mtd = sum(v for d, v in by_day.items() if d >= first_this)
            if mtd >= MIN_SERVICE_USD:
                rows_m.append(({"service": svc}, round(mtd, 6)))
        m("aws_cost_daily_usd", f"Cost per service on the last day with data ({latest})", "gauge", rows_d)
        m("aws_cost_service_month_to_date_usd", "Cost per service this month so far", "gauge", rows_m)
    m("aws_cost_alerts", "Number of active alerts", "gauge", [({}, len(s["alerts"]))])
    ts = datetime.fromisoformat(s["last_fetch"]).timestamp() if s["last_fetch"] else 0
    m("aws_cost_last_fetch_timestamp_seconds", "Time of the last successful fetch", "gauge", [({}, ts)])
    m("aws_cost_fetch_errors_total", "Failed fetches", "counter", [({}, s["fetch_errors"])])
    m("aws_cost_api_requests_total", "Cost Explorer requests made ($0.01 each)", "counter", [({}, s["api_requests"])])
    return "\n".join(out) + "\n"


def dashboard():
    s = snapshot()
    e = html.escape
    days = s["days"][-SHOW_DAYS:]
    first_this = date.today().replace(day=1).isoformat()
    svcs = sorted(s["daily"].items(), key=lambda kv: -sum(v for d, v in kv[1].items() if d >= first_this))
    svcs = [(n, d) for n, d in svcs if sum(d.get(x, 0) for x in days) >= MIN_SERVICE_USD
            or sum(v for x, v in d.items() if x >= first_this) >= MIN_SERVICE_USD]   # monthly charges (Route 53, Tax)
    peak = max([d.get(x, 0) for _, d in svcs for x in days] + [0.01])
    fc = f"${s['forecast']:.2f}" if s["forecast"] is not None else "—"
    pc = f"${s['pace']:.2f}" if s["pace"] is not None else "—"
    over = s["pace"] is not None and s["pace"] > MONTHLY_BUDGET_USD
    rows = []
    for name, by_day in svcs:
        cells = []
        for d in days:
            v = by_day.get(d, 0)
            a = 0.08 + 0.85 * (v / peak) if v > 0 else 0
            cells.append(f'<td style="background:rgba(214,92,40,{a:.2f})" title="{d} ${v:.4f}">'
                         f'{v:.2f}</td>' if v >= 0.005 else '<td class="z">·</td>')
        mtd = sum(v for d, v in by_day.items() if d >= first_this)
        rows.append(f"<tr><th>{e(name)}</th>{''.join(cells)}<td class='t'>${mtd:.2f}</td></tr>")
    head = "".join(f"<th>{d[5:]}</th>" for d in days)
    alerts = "".join(f"<li>{e(a)}</li>" for a in s["alerts"]) or "<li class='ok'>アラートなし</li>"
    err = f"<p class='err'>前回の取得に失敗: {e(s['last_error'])}</p>" if s["last_error"] else ""
    return f"""<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>AWS 料金</title>
<meta http-equiv="refresh" content="600">
<style>
:root{{--bg:#faf9f6;--fg:#1d1d1b;--mut:#6b6b66;--line:#e2e0da;--card:#fff;--bad:#b3261e;--good:#2e7d32}}
@media (prefers-color-scheme:dark){{:root{{--bg:#16161a;--fg:#e8e6e1;--mut:#9a988f;--line:#2c2c31;--card:#1e1e23;--bad:#f2867c;--good:#81c784}}}}
body{{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,sans-serif}}
main{{max-width:1100px;margin:auto}} h1{{font-size:20px;margin:0 0 4px}} .mut{{color:var(--mut)}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:16px 0}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px 14px}}
.card b{{display:block;font-size:24px;font-variant-numeric:tabular-nums}} .bad{{color:var(--bad)}}
ul{{padding-left:20px}} .ok{{color:var(--good)}} .err{{color:var(--bad)}}
.wrap{{overflow-x:auto;border:1px solid var(--line);border-radius:8px;background:var(--card)}}
table{{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:12px;width:100%}}
td,th{{padding:5px 7px;text-align:right;border-bottom:1px solid var(--line);white-space:nowrap}}
tbody th{{text-align:left;font-weight:500;max-width:260px;overflow:hidden;text-overflow:ellipsis}}
.z{{color:var(--mut)}} .t{{font-weight:600}}
</style></head><body><main>
<h1>AWS 料金</h1>
<div class="mut">最終取得 {e(s['last_fetch'] or 'まだ')} (UTC)・{FETCH_INTERVAL_HOURS:g} 時間ごと・
API 呼び出し {s['api_requests']} 回 (1 回 $0.01)・日付は UTC、データは {e(s['latest'] or '—')} まで (直近 1〜2 日は AWS 側でまだ集計中)。
AWS の予測は過去の傾向から外挿するので、急に止めた直後は高く出る</div>
{err}
<div class="cards">
<div class="card">今月の実績<b>${s['month_to_date']:.2f}</b></div>
<div class="card">今月の見込み (直近 1 日のペース)<b class="{'bad' if over else ''}">{pc}</b></div>
<div class="card">AWS の予測<b>{fc}</b></div>
<div class="card">予算<b>${MONTHLY_BUDGET_USD:.2f}</b></div>
<div class="card">先月<b>${s['last_month']:.2f}</b></div>
</div>
<h2 style="font-size:16px">アラート</h2><ul>{alerts}</ul>
<h2 style="font-size:16px">サービス別・日別 (USD、直近 {len(days)} 日)</h2>
<div class="wrap"><table><thead><tr><th style="text-align:left">サービス</th>{head}<th>今月</th></tr></thead>
<tbody>{''.join(rows) or '<tr><td>データなし</td></tr>'}</tbody></table></div>
</main></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/":
            self._send(200, "text/html; charset=utf-8", dashboard())
        elif p == "/status":
            self._send(200, "application/json", json.dumps(snapshot(), ensure_ascii=False, indent=1))
        elif p == "/metrics":
            self._send(200, "text/plain; version=0.0.4", metrics())
        elif p == "/health":
            self._send(200, "text/plain", "ok\n")
        else:
            self._send(404, "text/plain", "not found\n")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    if not (AKID and SECRET):
        log("AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are not set; fetching will fail")
    threading.Thread(target=fetch_loop, daemon=True).start()
    log(f"listening on :{PORT}, fetching every {FETCH_INTERVAL_HOURS:g}h, budget ${MONTHLY_BUDGET_USD:g}")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
