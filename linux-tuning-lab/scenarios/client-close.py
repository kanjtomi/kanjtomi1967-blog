#!/usr/bin/env python3
# 04-network.sh 用: 1 リクエストごとに接続を張り、クライアント側から先に close する負荷クライアント。
# 先に close した側に TIME_WAIT が残るので、クライアントのエフェメラルポートが減っていく。
#   python3 /scenarios/client-close.py <host> <リクエスト数> <並列数>
import socket, sys, threading, time
host, n, c = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ip = socket.gethostbyname(host)
req = b"GET / HTTP/1.1\r\nHost: web\r\n\r\n"
ok, errs, lock = 0, {}, threading.Lock()

def worker():
    global ok
    for _ in range(n // c):
        s = socket.socket()
        try:
            s.connect((ip, 80)); s.sendall(req); s.recv(4096)
            with lock:
                ok += 1
        except OSError as e:
            with lock:
                errs[e.strerror] = errs.get(e.strerror, 0) + 1
        finally:
            s.close()

t0 = time.time()
ts = [threading.Thread(target=worker) for _ in range(c)]
for t in ts: t.start()
for t in ts: t.join()
dt = time.time() - t0
print(f"  成功 {ok} / 失敗 {sum(errs.values())} {errs}  {dt:.1f} 秒 ({ok/dt:.0f} req/s)")
