#!/bin/sh
# DB コンテナ自身の cgroup を 1 秒ごとに読む(metrics-server / kubectl top の代わり)。
#   kubectl exec -n perf-lab deploy/perf-db -- sh /scenarios/cgroup-watch.sh
#
# cpu%      : 100% = 1 コア。limit 2 コアなら 200% で頭打ち
# throttled : その 1 秒間に「CPU を使いたいのに limit で止められていた」時間。0 でなければ CPU 不足
# anon      : プロセスが確保したメモリ(work_mem など)。解放できない → これが limit に届くと OOM kill
# file      : ページキャッシュ + shared_buffers。足りなくなればカーネルが回収できる
cg=/sys/fs/cgroup
stat() { grep "^$1 " "$cg/$2" | cut -d' ' -f2; }

limit=$(cat $cg/memory.max)
[ "$limit" = max ] || limit="$((limit / 1048576))MB"
echo "cpu.max=$(cat $cg/cpu.max)  memory.max=$limit"
printf '%-8s %6s %12s %8s %8s %8s %5s\n' time cpu% throttled_ms mem_MB anon_MB file_MB oom

pu=$(stat usage_usec cpu.stat); pt=$(stat throttled_usec cpu.stat)
while sleep 1; do
  u=$(stat usage_usec cpu.stat); t=$(stat throttled_usec cpu.stat)
  printf '%-8s %6s %12s %8s %8s %8s %5s\n' "$(date +%T)" \
    $(( (u - pu) / 10000 )) $(( (t - pt) / 1000 )) \
    $(( $(cat $cg/memory.current) / 1048576 )) \
    $(( $(stat anon memory.stat) / 1048576 )) \
    $(( $(stat file memory.stat) / 1048576 )) \
    "$(stat oom_kill memory.events)"
  pu=$u; pt=$t
done
