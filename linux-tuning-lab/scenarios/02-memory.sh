#!/bin/bash
# メモリ: limits.memory (memory.max) の中でページキャッシュと anon メモリがどう扱われるかを見る。
#   /scenarios/02-memory.sh cache [ファイルMB=1200] [読む回数=3]
#   /scenarios/02-memory.sh anon  [確保MB=1300]
# cache: limits.memory=1Gi より大きいファイルを繰り返し読むと、キャッシュに載りきらず毎回ディスクから
#        読み直す (workingset_refault_file が増え、2 回目以降も速くならない)。
#        2026-11-07 に Multus (50Mi 制限) で実際に起きた障害と同じ現象。ファイルを 600 にすると
#        2 回目以降はキャッシュから読めて速くなる。
# anon : 上限を超えて anon メモリを確保すると OOM killer が動く。k8s 1.28 以降 (cgroup v2) は
#        memory.oom.group=1 なので、一番大きいプロセスだけでなく「コンテナごと」殺されて再起動する
#        (この exec も exit 137 で切れる)。確認は外から:
#          kubectl -n tuning-lab get pod -l app=bench   (RESTARTS が増える)
#          kubectl -n tuning-lab get pod -l app=bench -o jsonpath='{..lastState}'   (reason: OOMKilled)
#        確保 MB を 700 → 900 → 1300 と変えてみる。/scratch (emptyDir) は再起動後も残る。
CG=/sys/fs/cgroup; MODE=${1:-cache}
ms() { awk -v k="$1" '$1==k{print $2}' $CG/memory.stat; }
ev() { awk -v k="$1" '$1==k{print $2}' $CG/memory.events; }
rd() { awk '{for(i=2;i<=NF;i++) if($i ~ /^rbytes=/){split($i,a,"="); s+=a[2]}} END{print s+0}' $CG/io.stat; }
echo "memory.max = $(cat $CG/memory.max) bytes"
case "$MODE" in
  cache)
    MB=${2:-1200}; N=${3:-3}; F=/scratch/cachetest.bin
    if [ ! -f $F ] || [ $(( $(stat -c %s $F) / 1048576 )) -ne $MB ]; then
      echo "テスト用ファイル ${MB}MB を作成中 ($F)"; rm -f $F; dd if=/dev/urandom of=$F bs=1M count=$MB status=none; sync
    fi
    for i in $(seq 1 $N); do
      r0=$(ms workingset_refault_file); d0=$(rd); s=$(date +%s.%N)
      cat $F > /dev/null
      e=$(date +%s.%N); r1=$(ms workingset_refault_file); d1=$(rd)
      printf "読み込み %d 回目: %5.2f 秒  ディスクから %5d MB  refault %7d  (file キャッシュ %d MB)\n" \
        $i $(echo "$e - $s" | bc) $(( (d1-d0)/1048576 )) $((r1-r0)) $(( $(ms file)/1048576 ))
    done
    echo "片付け: rm $F" ;;
  anon)
    MB=${2:-1300}; k0=$(ev oom_kill); m0=$(ev max)
    echo "memory.oom.group = $(cat $CG/memory.oom.group)  (1 = 上限を超えたらコンテナごと OOMKilled)"
    [ $MB -gt $(( $(cat $CG/memory.max) / 1048576 )) ] && echo "※ ${MB}MB は上限より大きいので、この後コンテナごと殺されて exec が切れるはず"
    stress-ng --vm 1 --vm-bytes ${MB}M --vm-keep --timeout 15s --metrics-brief 2>&1 | grep -E 'vm |killed|OOM' | head -5
    echo "--- oom_kill +$(( $(ev oom_kill)-k0 ))   max(上限到達) +$(( $(ev max)-m0 ))" ;;
  *) echo "usage: $0 cache|anon ..."; exit 1 ;;
esac
