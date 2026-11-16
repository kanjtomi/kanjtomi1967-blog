#!/bin/bash
# 原因当て (性能問題 Q1 の練習)。5 種類の問題からランダムに 1 つを裏で起こすので、
# 「サーバーが遅い」と言われた前提で、何が起きているかを調べて当てる。
#   /scenarios/mystery.sh start [分=10]   起こす (指定時間で自動的に止まる)
#   /scenarios/mystery.sh answer          正解と、見るべきだった指標を表示する
#   /scenarios/mystery.sh stop            止めて片付ける
# 起こす問題: cpu (スロットリング) / fsync (I/O 待ち) / cache (キャッシュに載らない) /
#             memory (上限ぎりぎりでの回収) / ports (エフェメラルポート枯渇)
# 使えるもの: uptime, top, vmstat 1, mpstat -P ALL 1, pidstat -u -d -r 1, iostat -x 1, free -m,
#             ss -s, ss -tan, /tmp/app.log, /scenarios/observe.sh 2 (cgroup)
# ※ /tmp/.mystery を読めば答えが分かるが、それは見ないこと。
STATE=/tmp/.mystery
stop() {
  # 先頭一致にする (ただの '/scenarios/app.py' だと、それを含むシェルのコマンド行まで殺してしまう)
  pkill -f '^timeout .* python3 /scenarios/app.py' 2>/dev/null
  pkill -f '^python3 /scenarios/app.py' 2>/dev/null; sleep 1; pkill -9 -f '^python3 /scenarios/app.py' 2>/dev/null
  rm -f /scratch/app-wal-*.log /scratch/app-data.bin
}
case "${1:-}" in
  start)
    M=${2:-10}; stop
    MODE=$(printf "cpu\nfsync\ncache\nmemory\nports\n" | shuf -n1)
    echo "$MODE" > $STATE
    MODE=$MODE nohup timeout "${M}m" python3 /scenarios/app.py > /tmp/app.log 2>&1 &
    echo "開始しました (${M} 分で自動停止)。顧客: 「アプリが遅い。何が起きているか調べてほしい」"
    echo "準備に 10〜30 秒かかる問題もあります。答え合わせは: /scenarios/mystery.sh answer" ;;
  answer)
    [ -f $STATE ] || { echo "まだ start していません"; exit 1; }
    case "$(cat $STATE)" in
      cpu) cat <<'EOF'
正解: cpu — limits.cpu=2 に対して 4 プロセスが CPU を回し、CFS でスロットリングされている
見るべきだった指標:
  - top / pidstat -u 1: python3 が 4 つ、合計 200% で頭打ち (1 つ 50% 前後)
  - observe.sh: cpu.stat の nr_throttled / throttled_usec が増え続ける、cpu.pressure が高い
  - mpstat -P ALL 1: ホスト全体の CPU は余っている (ホストの問題ではなく Pod の上限の問題)
対策: limits.cpu を上げる / ワーカー数を上限に合わせる / limit を外して requests だけにする
EOF
      ;;
      fsync) cat <<'EOF'
正解: fsync — 12 プロセスが 4k 書き込みのたびに fdatasync している (DB のコミットと同じ形)
見るべきだった指標:
  - uptime: load average が上がるのに top の %us/%sy は低い。ps で STAT が D のプロセスが多い
  - vmstat 1: b 列 (ブロック中) が多い、wa がある
  - iostat -x 1: w/s が数百・wkB/s は小さい (~1MB/s) のに %util が高い、f/s (flush) が多い
  - pidstat -d 1: python3 の kB_wr/s。observe.sh の io.pressure
対策: グループコミット / コミット回数を減らす / innodb_flush_log_at_trx_commit=2 のような
      耐久性とのトレードオフ / flush の速いデバイス (PLP 付き SSD) に置く
EOF
      ;;
      cache) cat <<'EOF'
正解: cache — 1200MB のファイルを何度も読むが、memory.max=1Gi に載りきらず毎回ディスクから読み直す
見るべきだった指標:
  - /tmp/app.log: 「scanned dataset in N s」が何度やっても速くならない
  - iostat -x 1 / pidstat -d 1: 読み込み帯域が出続ける (r/s, rkB/s)
  - observe.sh: memory.current が上限に張り付き、workingset_refault_file が増え続ける
  - OOM は起きない (ページキャッシュは回収できるので kill はされない)
対策: limits.memory を作業セットより大きくする / 読む量を減らす。2026-11-07 の Multus と同じ現象
EOF
      ;;
      memory) cat <<'EOF'
正解: memory — anon 850MB を抱えたまま、残り 150MB ほどで 300MB のファイルを読み続けている
見るべきだった指標:
  - pidstat -r 1 / top RES: python3 の 1 つが 850MB 以上
  - observe.sh: memory.current が memory.max に張り付く、anon が大きく (~900MB) file が小さい
    (~150MB)、workingset_refault_file が増え続ける、memory.pressure。
    memory.events の max / oom は 0 のまま (キャッシュを回収できているうちは上限超え扱いにならない)
  - あと少し確保すると OOMKilled (コンテナごと再起動) になる一歩手前
対策: limits.memory を上げる / キャッシュとして抱えているメモリを減らす
EOF
      ;;
      ports) cat <<'EOF'
正解: ports — 毎回接続してクライアント側から先に close するので TIME_WAIT が溜まり、
      ip_local_port_range (1000 ポート) を使い切っている
見るべきだった指標:
  - /tmp/app.log: 「Cannot assign requested address」(EADDRNOTAVAIL)
  - ss -s / ss -tan state time-wait | wc -l: TIME_WAIT が ~1000 (= ポートの数)
  - CPU・メモリ・ディスクは暇
対策: keep-alive / コネクションプールで接続を使い回す / ip_local_port_range を広げる /
      接続先を増やす。tcp_tw_reuse はこのクラスタでは unsafe sysctl なので使えない
EOF
      ;;
    esac ;;
  stop) stop; rm -f $STATE; echo "止めました" ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
