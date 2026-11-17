"""myapp — トラブルシューティング練習用の小さな Web サービス。

  起動時: 設定ファイル /etc/myapp/myapp.conf を読み、port で待ち受ける
  GET /health:
    1. data_dir/requests.log に 1 行書く        (ディスク・権限の問題がここで出る)
    2. upstream (web.tuning-lab.svc.cluster.local:80) に GET する (DNS・ネットワークの問題がここで出る)
    3. 全部成功なら 200 "ok"、失敗なら 500 とエラー内容
  ログ: /var/log/myapp/myapp.log

LEAK=1 のときは /health のたびにファイルを開いたまま閉じない (fd リーク)。
"""
import http.client
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/myapp/myapp.conf"
LOG = "/var/log/myapp/myapp.log"
LEAK = os.environ.get("LEAK") == "1"
leaked = []


try:   # 本物のサービスと同じく、ログは起動時に 1 回開いて開いたままにする (fd が尽きても書ける)
    LOGF = open(LOG, "a", buffering=1)
except OSError:
    LOGF = sys.stderr


def log(msg):
    LOGF.write(time.strftime("%Y-%m-%d %H:%M:%S") + f" myapp[{os.getpid()}] {msg}\n")


def load_conf():
    conf = {}
    with open(CONF) as f:
        for raw in f:
            raw = raw.split("#", 1)[0].strip()
            if "=" in raw:
                k, v = raw.split("=", 1)
                conf[k.strip()] = v.strip()
    return conf


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            return self._send(404, "not found\n")
        try:
            with open(os.path.join(DATA, "requests.log"), "a") as f:
                f.write(f"{time.time():.3f} health\n")
            if LEAK:
                leaked.append(open(os.path.join(DATA, "requests.log")))
            host, port = UPSTREAM.rsplit(":", 1)
            c = http.client.HTTPConnection(host, int(port), timeout=3)
            c.request("GET", "/")
            r = c.getresponse()
            r.read()
            c.close()
            if r.status != 200:
                raise RuntimeError(f"upstream {UPSTREAM} returned {r.status}")
        except Exception as e:
            log(f"ERROR /health failed: {type(e).__name__}: {e}")
            return self._send(500, f"error: {e}\n")
        self._send(200, "ok\n")

    def _send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    log(f"starting (uid={os.getuid()}, LEAK={int(LEAK)})")
    try:
        conf = load_conf()
    except OSError as e:
        log(f"FATAL cannot read config {CONF}: {e}")
        sys.exit(1)
    PORT = int(conf.get("port", "8080"))
    DATA = conf.get("data_dir", "/data/myapp")
    UPSTREAM = conf.get("upstream", "web.tuning-lab.svc.cluster.local:80")
    try:
        srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    except OSError as e:
        log(f"FATAL cannot bind 0.0.0.0:{PORT}: {e}")
        sys.exit(1)
    log(f"listening on :{PORT}, data_dir={DATA}, upstream={UPSTREAM}")
    srv.serve_forever()
