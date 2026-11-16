"""mystery.sh が起動する「調子の悪いアプリ」。どの問題を起こすかは環境変数 MODE で決まる。
ps には `python3 /scenarios/app.py` としか出ないので、見た目では区別できない。
ログは /tmp/app.log (本物のアプリと同じく、手がかりになることもある)。"""
import multiprocessing as mp
import os
import random
import socket
import sys
import threading
import time

MODE = os.environ.get("MODE", "cpu")
HOST = "web.tuning-lab.svc.cluster.local"


def log(msg):
    print(time.strftime("%H:%M:%S"), f"[pid {os.getpid()}]", msg, flush=True)


def heartbeat(label):
    n = 0
    while True:
        time.sleep(10)
        n += 1
        log(f"{label}: still running ({n * 10}s)")


def cpu_worker():
    x = 0
    while True:            # 4 プロセス × busy loop。limits.cpu=2 を超えるのでスロットリングされる
        x = (x * 31 + 7) % 1000003


def fsync_worker(i):
    path = f"/scratch/app-wal-{i}.log"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    buf = os.urandom(4096)
    n = 0
    while True:            # DB の WAL と同じ: 小さく書いて毎回 fdatasync
        os.write(fd, buf)
        os.fdatasync(fd)
        n += 1
        if n % 2048 == 0:
            os.ftruncate(fd, 0)


def make_file(path, mb):
    if os.path.exists(path) and os.path.getsize(path) == mb * 1048576:
        return
    with open(path, "wb") as f:
        chunk = os.urandom(1048576)
        for _ in range(mb):
            f.write(chunk)
    log(f"prepared {path} ({mb} MB)")


def read_loop(path):
    while True:
        t = time.time()
        with open(path, "rb") as f:
            while f.read(1048576):
                pass
        log(f"batch job: scanned dataset in {time.time() - t:.2f}s")


def ports_worker():
    req = f"GET / HTTP/1.1\r\nHost: {HOST}\r\nConnection: keep-alive\r\n\r\n".encode()
    while True:            # 毎回新しい接続を張り、クライアント側から先に close する
        try:
            s = socket.create_connection((HOST, 80), timeout=2)
            s.sendall(req)
            s.recv(4096)
            s.close()
        except OSError as e:
            log(f"ERROR upstream call failed: {e}")
            time.sleep(0.2)


def main():
    log(f"app started (workers={os.cpu_count()})")
    threading.Thread(target=heartbeat, args=("app",), daemon=True).start()
    procs = []
    if MODE == "cpu":
        procs = [mp.Process(target=cpu_worker) for _ in range(4)]
    elif MODE == "fsync":
        procs = [mp.Process(target=fsync_worker, args=(i,)) for i in range(12)]
    elif MODE == "cache":
        make_file("/scratch/app-data.bin", 1200)   # 上限 1Gi より大きい → 毎回ディスクから読み直す
        procs = [mp.Process(target=read_loop, args=("/scratch/app-data.bin",))]
    elif MODE == "memory":
        make_file("/scratch/app-data.bin", 300)
        hog = bytearray(850 * 1048576)              # anon 850MB を確保して触る (上限 1Gi の手前)
        for i in range(0, len(hog), 4096):
            hog[i] = 1
        log("cache warmed (850 MB)")
        procs = [mp.Process(target=read_loop, args=("/scratch/app-data.bin",))]
    elif MODE == "ports":
        for _ in range(4):
            threading.Thread(target=ports_worker, daemon=True).start()
    else:
        sys.exit(f"unknown MODE {MODE}")
    for p in procs:
        p.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    random.seed()
    main()
