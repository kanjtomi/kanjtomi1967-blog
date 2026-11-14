#!/bin/bash
# CPU: limits.cpu (CFS quota) を超えて CPU を使おうとしたときのスロットリングを見る。
#   /scenarios/01-cpu-throttle.sh [ワーカー数=4] [秒=20]
# 試すこと:
#   1. ワーカー 1 → 2 → 4 → 8 と増やす。limits.cpu=2 を超えると bogo ops/s が増えず、
#      nr_throttled / throttled_usec だけが増える。
#   2. k8s/bench.yaml の limits.cpu を変えて (例 "1", "4") apply し直し、同じ実験をする。
#   3. 別の exec で `mpstat -P ALL 1` / `pidstat -u 1` を流しておく (ホスト全体の CPU は使い切っていない)。
W=${1:-4}; T=${2:-20}; CG=/sys/fs/cgroup
get() { awk -v k="$1" '$1==k{print $2}' $CG/cpu.stat; }
echo "cpu.max = $(cat $CG/cpu.max)  (quota/period: 200000 100000 なら 2 コアぶん)"
u0=$(get usage_usec); p0=$(get nr_periods); t0=$(get nr_throttled); w0=$(get throttled_usec)
stress-ng --cpu "$W" --cpu-method matrixprod --timeout "${T}s" --metrics-brief 2>&1 | grep -E 'cpu |bogo'
u1=$(get usage_usec); p1=$(get nr_periods); t1=$(get nr_throttled); w1=$(get throttled_usec)
echo "--- 結果 (ワーカー $W, ${T} 秒)"
echo "使えた CPU          : $(echo "scale=2; ($u1-$u0)/($T*1000000)" | bc) コア"
echo "スロットリングされた期間 : $((t1-t0)) / $((p1-p0)) 周期 ($(echo "scale=1; 100*($t1-$t0)/($p1-$p0+1)" | bc)%)"
echo "止められていた時間合計 : $(echo "scale=2; ($w1-$w0)/1000000" | bc) 秒"
