#!/bin/bash
# load average は高いのに CPU は暇 — fsync 待ちの D 状態 (性能問題 Q2 / Q3)。
#   /scenarios/05-iowait-load.sh [書き込みプロセス数=16] [秒=60]
# 4k 書き込みのたびに fdatasync するプロセス (DB のコミットと同じ形) を N 個動かし、5 秒ごとに
#   - load average (1 分) と D 状態 (uninterruptible sleep) のプロセス数
#   - この Pod が使っている CPU (コア数)
#   - /scratch の下にあるディスクの w/s, wkB/s, w_await, f/s, %util  (iostat -x と同じ計算)
#     f/s は単独の FLUSH 要求の数。XFS + この NVMe では flush が書き込みに付いて (PREFLUSH/FUA) 出るので 0 のまま。
# を表示する。load average と /proc/stat の procs_blocked はホスト全体の値 (コンテナでも名前空間で分かれない)。
# 読み方: load は N 近くまで上がるが CPU はほとんど使わない。load は「実行待ち + D 状態」の数なので、
#         I/O 待ちでも上がる。ディスクは少ない帯域で %util が高い = 1 件ずつの flush 待ちが律速。
# 試すこと: N を 1 / 4 / 16 / 32 で比べる。別の exec で `iostat -x 1` `vmstat 1` (b 列) `pidstat -d 1`。
# /glide は MariaDB / ServiceNow と共有。fsync の上限 (~160/s) を取り合うので 60 秒程度に留めること。
N=${1:-16}; T=${2:-60}; D=/scratch/q2; CG=/sys/fs/cgroup
mkdir -p $D
MM=$(mountpoint -d /scratch)                       # 例 253:2 (LVM の dm デバイス)
DEVS="$(basename "$(readlink -f /sys/dev/block/$MM)")"
for s in /sys/dev/block/$MM/slaves/*; do      # LVM の下の物理デバイス。パーティションなら親ディスクを見る
  [ -e "$s" ] || continue                     # (flush の回数はディスク全体でしか数えられない)
  s=$(readlink -f "$s"); [ -f "$s/partition" ] && s=$(dirname "$s")
  DEVS="$DEVS $(basename "$s")"
done
echo "/scratch のデバイス: $DEVS   書き込みプロセス $N 個 / ${T} 秒"
echo "開始前 load average: $(cut -d' ' -f1-3 /proc/loadavg)   (CPU は $(nproc) 個)"

fio --name=commit --directory=$D --rw=randwrite --bs=4k --ioengine=sync --fdatasync=1 \
    --numjobs="$N" --size=32M --runtime="$T" --time_based --group_reporting \
    --output-format=json > /tmp/05-fio.json 2>&1 &
FIO=$!

ds() { awk -v d="$1" '$3==d{print $8, $10, $11, $13, $18, $19}' /proc/diskstats; }  # w, 書いたsector, w_ms, io_ms, flush, flush_ms
cpu() { awk '$1=="usage_usec"{print $2}' $CG/cpu.stat; }
declare -A P
for d in $DEVS; do P[$d]="$(ds $d)"; done; c0=$(cpu); t0=$(date +%s.%N)
printf "%5s %6s %5s %7s | %-9s %7s %7s %8s %6s %6s\n" 秒 load1 D状態 CPUコア デバイス w/s wkB/s w_await f/s %util
i=0
while kill -0 $FIO 2>/dev/null; do
  sleep 5; i=$((i+5)); t1=$(date +%s.%N); c1=$(cpu); dt=$(echo "$t1 - $t0" | bc)
  dst=$(ps -eo stat= | grep -c '^D')
  first=1
  for d in $DEVS; do
    now="$(ds $d)"
    line=$(echo "${P[$d]} $now $dt" | awk '{dw=$7-$1; dsec=$8-$2; dms=$9-$3; dio=$10-$4; df=$11-$5; t=$13;
      printf "%7.0f %7.0f %8.2f %6.0f %5.1f%%", dw/t, dsec*512/1024/t, (dw>0?dms/dw:0), df/t, dio/(t*10)}')
    if [ $first = 1 ]; then
      printf "%5s %6s %5s %7.2f | %-9s %s\n" $i "$(cut -d' ' -f1 /proc/loadavg)" "$dst" \
        "$(echo "($c1 - $c0) / ($dt * 1000000)" | bc -l)" "$d" "$line"; first=0
    else
      printf "%5s %6s %5s %7s | %-9s %s\n" "" "" "" "" "$d" "$line"
    fi
    P[$d]="$now"
  done
  c0=$c1; t0=$t1
done
python3 - <<'PY'
import json
j = json.load(open("/tmp/05-fio.json"))["jobs"][0]["write"]
p = j["clat_ns"].get("percentile", {})
s = json.load(open("/tmp/05-fio.json"))["jobs"][0].get("sync", {}).get("lat_ns", {}).get("percentile", {})
print("--- fio 合計: %.0f 書き込み/s (%.2f MB/s)   書き込み p50 %.0f us / fdatasync p50 %.2f ms, p99 %.2f ms" % (
    j["iops"], j["bw"] / 1024, p.get("50.000000", 0) / 1000,
    s.get("50.000000", 0) / 1e6, s.get("99.000000", 0) / 1e6))
PY
echo "終了時 load average: $(cut -d' ' -f1-3 /proc/loadavg)  (1 分平均なので、下がるまで数分かかる)"
rm -rf $D /tmp/05-fio.json
