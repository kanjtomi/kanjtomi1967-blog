#!/bin/bash
# 性能の見方レッスン。study Pod の中で `lesson <番号>` と打つ。
# 各レッスン: 負荷を起こす → 問題を出す → (別の端末で調べる) → Enter で実測値と解説 → 片付け。
# 端末をもう 1 つ開いて調べるときは: kubectl -n tuning-lab exec -it deploy/study -- bash
# 実行ごとに作業場所と負荷の記録を分ける (同じ Pod で lesson を 2 つ動かしても、互いの負荷を止めない)
CG=/sys/fs/cgroup; S=/scratch/lesson-$$; PIDS=/tmp/lesson-$$.pids
mkdir -p $S

# ---------- 共通 ----------
bg() { setsid bash -c "$1" >/dev/null 2>&1 & echo $! >> $PIDS; }      # 負荷を裏で起こす
cleanup() {
  [ -f $PIDS ] && while read -r p; do kill -- -"$p" 2>/dev/null; kill "$p" 2>/dev/null; done < $PIDS
  rm -f $PIDS; rm -rf $S
}
trap cleanup EXIT INT TERM
h() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() {
  h "問題"; echo "$1"
  [ -n "${2:-}" ] && { echo; echo "使えるコマンドの例: $2"; }
  echo
  if [ -t 0 ]; then read -r -p "考えたら Enter (別の端末で調べてもよい) > " _; else sleep "${WAIT:-10}"; fi
}
cpu_usec() { awk '$1=="usage_usec"{print $2}' $CG/cpu.stat; }
thr() { awk '$1=="nr_throttled"{print $2}' $CG/cpu.stat; }
per() { awk '$1=="nr_periods"{print $2}' $CG/cpu.stat; }
ms() { awk -v k="$1" '$1==k{print $2}' $CG/memory.stat; }
mb() { echo $(( $1 / 1048576 )); }
disk() { # /scratch の下の物理ディスク名
  local mm s; mm=$(mountpoint -d /scratch); s=$(ls -d /sys/dev/block/$mm/slaves/* 2>/dev/null | head -1)
  [ -n "$s" ] || { basename "$(readlink -f /sys/dev/block/$mm)"; return; }
  s=$(readlink -f "$s"); [ -f "$s/partition" ] && s=$(dirname "$s"); basename "$s"
}
dsnap() { awk -v d="$1" '$3==d{print $4,$7,$8,$11,$13,$14}' /proc/diskstats; }   # r, r_ms, w, w_ms, io_ms, weighted_ms
ddiff() { # 前 後 秒 → iostat -x と同じ値
  echo "$1 $2 $3" | awk '{r=$7-$1; rms=$8-$2; w=$9-$3; wms=$10-$4; io=$11-$5; q=$12-$6; t=$13;
    printf "r/s %7.0f  r_await %5.2f ms  w/s %6.0f  w_await %5.2f ms  aqu-sz %6.2f  %%util %5.1f%%\n",
      r/t, (r?rms/r:0), w/t, (w?wms/w:0), q/(t*1000), io/(t*10)}'
}

# ---------- レッスン ----------
l1() {
  h "レッスン 1: load average が高い = CPU 不足 ?"
  echo "4k 書き込みのたびに fdatasync するプロセスを 8 個動かします (DB のコミットと同じ形)。"
  bg "fio --name=l1 --directory=$S --rw=randwrite --bs=4k --ioengine=sync --fdatasync=1 --numjobs=8 --size=16M --runtime=900 --time_based"
  sleep 15
  ask "load average は上がっていますか? この Pod の CPU は足りていませんか? 何を待っていますか?" \
      "uptime / top / vmstat 1 (r と b 列) / ps -eo stat,comm | sort | uniq -c"
  local c0 c1; c0=$(cpu_usec); sleep 5; c1=$(cpu_usec)
  h "実測"
  echo "load average      : $(cut -d' ' -f1-3 /proc/loadavg)   (ホスト全体の値。CPU は $(nproc) 個)"
  echo "D 状態のプロセス  : $(ps -eo stat= | grep -c '^D') 個"
  echo "この Pod の CPU   : $(echo "scale=2; ($c1-$c0)/5000000" | bc) コア (上限 1)"
  echo "vmstat (r=CPU 待ち, b=I/O 待ち):"; vmstat 1 3 | sed 's/^/  /'
  h "解説"
  cat <<'EOF'
load average は「実行中 + CPU 待ち (r) + D 状態 (主に I/O 待ち, b)」の数の平均。
CPU はほとんど使っていないのに load が上がるのは、fdatasync の完了を待つプロセスが D 状態で
数えられているから。r 列が CPU 数を超えていれば CPU 不足。load だけで「CPU が足りない」と決めない。
注意: vmstat の b 列 (procs_blocked) は「ブロック I/O の完了を待っている」タスクだけを数えるので、
fdatasync がファイルシステムのジャーナル待ちで寝ているときは数えられない。2026-11-15 の実測では
同じ負荷で b=0 / wa 6〜9% の回と、b=8 / wa 37% の回があった (待っている場所がその時々で違う)。
確実なのは ps の STAT が D のプロセスを数えること。
EOF
}

l2() {
  h "レッスン 2: CPU の飽和とスロットリング"
  echo "CPU を回すプロセスを 3 個動かします。この Pod の上限は 1 コアです。"
  bg "stress-ng --cpu 3 --cpu-method matrixprod --timeout 900s"
  sleep 5
  ask "ホスト全体の CPU は余っていますか? この Pod の中のプロセスは十分に CPU をもらえていますか?" \
      "mpstat 1 / top / pidstat -u 1 / cat /sys/fs/cgroup/cpu.stat"
  local t0 p0 t1 p1; t0=$(thr); p0=$(per); sleep 5; t1=$(thr); p1=$(per)
  h "実測"
  echo "ホスト全体の CPU (mpstat, %idle が余り):"; mpstat 1 2 | tail -1 | awk '{print "  %usr " $3 "  %sys " $5 "  %idle " $NF}'
  echo "プロセスごと (pidstat: %usr = 使えた, %wait = 実行できる状態なのに待たされた):"
  pidstat -u 1 2 | awk '/Average/ && /stress-ng/ {print "  %usr " $4 "  %wait " $7 "  " $NF}' | head -4
  echo "スロットリング   : 5 秒間で $((t1-t0)) / $((p1-p0)) 周期 (cpu.max = $(cat $CG/cpu.max))"
  h "解説"
  cat <<'EOF'
ホストの CPU は 90% 余っているのに、3 プロセスは合計 100% (1 つ約 33%) で頭打ち、残りの約 66% は
%wait (待たされた時間)。cgroup の上限 (cpu.max = 100000 100000 → 100ms ごとに 100ms ぶん) を使い切ると、
その周期の残りは止められる。これがスロットリングで、nr_throttled / throttled_usec に出る。
コンテナの CPU 飽和は vmstat の r 列 (ホスト全体) には出にくい。cpu.stat か pidstat の %wait を見る。
Prometheus なら rate(container_cpu_cfs_throttled_periods_total[5m]) / rate(container_cpu_cfs_periods_total[5m])。
EOF
}

l3() {
  h "レッスン 3: 平均は正常でも p99 が悪い"
  echo "この Pod の中で小さな Web サーバー (1 リクエスト約 2ms の CPU 処理) を動かし、ab で測ります。"
  bg "python3 -c '
import http.server, socketserver  # LESSON
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        sum(i*i for i in range(30000)); b=b\"ok\"
        self.send_response(200); self.send_header(\"Content-Length\",\"2\"); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
socketserver.ThreadingTCPServer.allow_reuse_address=True
socketserver.ThreadingTCPServer((\"127.0.0.1\",8080),H).serve_forever()'"
  sleep 2
  summ() { awk '/Requests per second/{print "  req/s    " $4} /Time per request.*\(mean\)/{print "  平均     " $4 " ms"} /^  50%/{print "  p50      " $2 " ms"} /^  99%/{print "  p99      " $2 " ms"} /^ 100%/{print "  最大     " $2 " ms"}'; }
  echo "--- 1 回目: Web サーバーだけ"
  ab -q -k -n 1500 -c 2 http://127.0.0.1:8080/ 2>&1 | summ
  echo "同じ Pod で、CPU を食うバッチ処理 (2 プロセス) を始めます。"
  bg "stress-ng --cpu 2 --timeout 900s"
  sleep 3
  ask "平均と p99 はそれぞれ何倍くらいになると思いますか? 平均だけを見ていたら気づけますか?"
  echo "--- 2 回目: バッチ処理と同居"
  ab -q -k -n 1500 -c 2 http://127.0.0.1:8080/ 2>&1 | summ
  h "解説"
  cat <<'EOF'
CPU の上限 (1 コア) を Web とバッチで取り合う。100ms の周期の途中で上限を使い切ると、
その周期の残りは止められるので、運の悪いリクエストだけが数十 ms 待たされる。
平均より p99 や最大が大きく悪化するのが特徴 (スロットリングの典型的な症状)。
応答時間は平均ではなくパーセンタイル (p95 / p99) で見る。対策: 上限を上げる、バッチを別の Pod に分ける。
EOF
}

l4() {
  h "レッスン 4: コンテナのメモリはどこを見る?"
  ask "コンテナの中で free -m を打つと、何の値が出ると思いますか? この Pod の上限 512Mi は見えますか?" "free -m / cat /sys/fs/cgroup/memory.max"
  h "実測 1: free -m (コンテナの中)"; free -m | sed 's/^/  /'
  echo "  → これはホスト全体 (93GB) の値。/proc/meminfo はコンテナごとに分かれていない。"
  echo "  この Pod の上限 memory.max = $(mb $(cat $CG/memory.max)) MB、今の使用量 memory.current = $(mb $(cat $CG/memory.current)) MB"
  echo
  echo "300MB のファイルを作って 2 回読みます (上限に収まる)。"
  dd if=/dev/urandom of=$S/a.bin bs=1M count=300 oflag=direct status=none   # direct: 書いた内容をキャッシュに残さない
  for i in 1 2; do s=$(date +%s.%N); cat $S/a.bin > /dev/null; e=$(date +%s.%N)
    echo "  $i 回目 $(printf "%.2f" $(echo "$e - $s" | bc)) 秒  current $(mb $(cat $CG/memory.current)) MB (うち file キャッシュ $(mb $(ms file)) MB)"; done
  rm -f $S/a.bin
  echo "700MB のファイルを作って 2 回読みます (上限より大きい)。"
  dd if=/dev/urandom of=$S/b.bin bs=1M count=700 oflag=direct status=none
  for i in 1 2; do r0=$(ms workingset_refault_file); s=$(date +%s.%N); cat $S/b.bin > /dev/null; e=$(date +%s.%N)
    echo "  $i 回目 $(printf "%.2f" $(echo "$e - $s" | bc)) 秒  refault +$(( $(ms workingset_refault_file) - r0 ))  current $(mb $(cat $CG/memory.current)) MB"; done
  local ws=$(( $(cat $CG/memory.current) - $(ms inactive_file) ))
  echo "  working set (current - inactive_file) = $(mb $ws) MB   ← k8s が OOM / 退避の判断に使う値"
  h "解説"
  cat <<'EOF'
コンテナの中の free / top のメモリはホストの値。コンテナの量は cgroup (memory.current / memory.max /
memory.stat) か、外から kubectl top (= working set) で見る。
ページキャッシュも上限に数えられる。上限より大きいファイルは何度読んでも速くならず、refault
(一度追い出したキャッシュの読み直し) が増える。OOM は起きない (キャッシュは捨てられる) ので、
メモリ不足が「ディスク I/O が多い」という形で見える。
EOF
}

l5() {
  h "レッスン 5: OOMKilled (この exec は切れます)"
  ask "上限 512Mi の Pod で 700MB の anon メモリを確保すると、何が起きますか? 外からどう確かめますか?" \
      "(別の端末で) kubectl -n tuning-lab get pod -l app=study -w"
  echo "確保します。数秒でコンテナごと殺され、この exec は exit 137 で切れるはず。"
  echo "そのあと外から: kubectl -n tuning-lab get pod -l app=study   (RESTARTS が 1 増える)"
  echo "                kubectl -n tuning-lab get pod -l app=study -o jsonpath='{..lastState}'   (reason: OOMKilled)"
  sleep 3
  stress-ng --vm 1 --vm-bytes 700M --vm-keep --timeout 20s 2>&1 | tail -2
  echo "(ここが表示されたら OOM は起きなかった: memory.events = $(tr '\n' ' ' < $CG/memory.events))"
}

l6() {
  h "レッスン 6: ディスクの %util は限界を表す?"
  local d; d=$(disk)
  echo "デバイス $d で 4k ランダム読み込みを、キュー深度 1 と 32 で 8 秒ずつ実行します。"
  fio --name=l6 --directory=$S --rw=randread --bs=4k --size=512M --runtime=1 --time_based --ioengine=libaio --direct=1 >/dev/null 2>&1
  for qd in 1 32; do
    local a b; a=$(dsnap $d)
    fio --name=l6 --directory=$S --rw=randread --bs=4k --size=512M --runtime=8 --time_based --ioengine=libaio --direct=1 --iodepth=$qd >/dev/null 2>&1
    b=$(dsnap $d); R[$qd]=$(ddiff "$a" "$b" 8)
    [ $qd = 1 ] && { echo "  qd1 : ${R[1]}"; ask "%util が 100% 近くなっていたら、このディスクは限界ですか? キュー深度を 32 にすると r/s はどうなると思いますか?" "iostat -x 1"; }
  done
  h "実測"; echo "  qd1 : ${R[1]}"; echo "  qd32: ${R[32]}"
  h "解説"
  cat <<'EOF'
%util は「1 件でも処理中だった時間の割合」。1 件ずつ (qd1) でも、ほぼずっと何かを処理しているので
100% 近くになる。NVMe や SAN は中で並列に処理できるので、qd32 にすると %util はほぼ同じまま r/s が
10 倍前後に伸びる。限界かどうかは %util ではなく、await (1 件の待ち時間) と aqu-sz (キューの長さ)、
「並列を増やしたらまだ伸びるか」で判断する。r/s と await は一緒に見る (IOPS ≒ キュー深度 / 遅延)。
EOF
}

l7() {
  h "レッスン 7: CPU もメモリも余っているのに接続できない"
  echo "web Service (nginx) に 3000 回リクエストします。まず keep-alive (接続を使い回す) で、次に毎回接続してクライアント側から close する方式で。"
  local ka; ka=$(ab -q -k -n 3000 -c 4 http://web.tuning-lab.svc.cluster.local/ 2>&1 | awk '/Complete requests|Failed requests/{printf "%s %s  ", $1, $NF}')
  local out; out=$(python3 - <<'PY'
import socket, threading
ok = err = 0; msg = ""; lock = threading.Lock()
def w():
    global ok, err, msg
    for _ in range(750):
        try:
            s = socket.create_connection(("web.tuning-lab.svc.cluster.local", 80), timeout=2)
            s.sendall(b"GET / HTTP/1.1\r\nHost: web\r\n\r\n"); s.recv(4096); s.close()
            with lock: ok += 1
        except OSError as e:
            with lock: err += 1; msg = str(e)
ts = [threading.Thread(target=w) for _ in range(4)]; [t.start() for t in ts]; [t.join() for t in ts]
print(ok, err, msg)
PY
)
  ask "接続の一部が失敗しました。原因を調べるには何を数えますか?" "ss -s / ss -tan state time-wait | wc -l / cat /proc/sys/net/ipv4/ip_local_port_range"
  h "実測"
  set -- $out; local ok=$1 err=$2; shift 2
  echo "  keep-alive        : $ka"
  echo "  毎回接続して close: 成功 $ok / 失敗 $err   エラー: $*"
  echo "  TIME_WAIT: $(ss -tan state time-wait | tail -n +2 | wc -l)   使えるポート: $(awk '{print $2-$1+1}' /proc/sys/net/ipv4/ip_local_port_range) 個"
  h "解説"
  cat <<'EOF'
先に close した側に TIME_WAIT (約 60 秒) が残り、その間そのポートは同じ宛先に使えない。
この Pod は ip_local_port_range を 1000 個に絞ってあるので、1000 回でポートを使い切り
"Cannot assign requested address" (EADDRNOTAVAIL) になる。CPU / メモリ / ディスクのどこにも出ない、
「エラー (USE の E)」でしか見えない飽和。対策は接続の使い回し (keep-alive / プール) が第一。
EOF
}

menu() {
  cat <<'EOF'
性能の見方レッスン (study Pod: CPU 上限 1 / メモリ上限 512Mi)
  lesson 1   load average が高い = CPU 不足 ?        (I/O 待ちと D 状態)
  lesson 2   CPU の飽和とスロットリング               (cpu.stat)
  lesson 3   平均は正常でも p99 が悪い                (パーセンタイル)
  lesson 4   コンテナのメモリはどこを見る?            (free の罠、キャッシュ、refault)
  lesson 5   OOMKilled                                (この exec が切れる)
  lesson 6   ディスクの %util は限界を表す?          (await / aqu-sz / キュー深度)
  lesson 7   CPU もメモリも余っているのに接続できない (TIME_WAIT とポート枯渇)
総合問題 (原因当て) は bench Pod の /scenarios/mystery.sh。
EOF
}

case "${1:-}" in
  [1-7]) declare -A R; "l$1" ;;
  *) trap - EXIT; rm -rf $S; menu ;;
esac
