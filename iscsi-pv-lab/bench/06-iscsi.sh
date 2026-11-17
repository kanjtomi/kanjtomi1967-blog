#!/bin/bash
# iSCSI の LUN は遅いか (性能問題 Q5)。iscsi-bench Pod の中で実行する。
#   /bench/06-iscsi.sh [秒=10] [サイズ=512M]
# 同じ fio を iSCSI の /data と、ローカル NVMe の /scratch (emptyDir) で実行して比べ、
# ネットワーク側 (経路・RTT・パス MTU) も見る。ホスト側 (イニシエーター) とターゲット側の
# 確認コマンドは iscsi-pv-lab/README.md の「性能の練習」を参照。
# /data は iscsi-pv-lab-demo Pod と共有 (同じノードなので RWO でも同時にマウントできる)。
# 作業ファイルは /data/fio-bench にだけ作り、最後に消す。
T=${1:-10}; SZ=${2:-512M}; TARGET=10.10.11.6
read -r -d '' SUMMARY <<'PY'
import json, sys
j = json.load(sys.stdin)["jobs"][0]
for k in ("read", "write"):
    o = j[k]
    if o["io_bytes"] == 0:
        continue
    p = o["clat_ns"].get("percentile", {})
    print("  %-8s %-20s %-5s %8.1f MB/s %8.0f IOPS  p50 %8.0f us  p99 %8.0f us" % (
        sys.argv[1], sys.argv[2], k, o["bw"] / 1024, o["iops"],
        p.get("50.000000", 0) / 1000, p.get("99.000000", 0) / 1000))
PY
run() { # place dir name fio-args...
  local where=$1 dir=$2 n=$3 out; shift 3; mkdir -p "$dir"
  out=$(fio --name=$n --directory="$dir" --size=$SZ --runtime=$T --time_based --ioengine=libaio \
            --group_reporting --output-format=json "$@" 2>&1) || { echo "  $where $n: fio failed"; return; }
  echo "$out" | python3 -c "$SUMMARY" "$where" "$n"
}
echo "=== ネットワーク: Pod → ターゲット $TARGET"
ip route get $TARGET | head -1 | sed 's/^/  /'
echo "  Pod の eth0 MTU: $(cat /sys/class/net/eth0/mtu)  (Calico。ホスト側の enp3s0 / Zadara の enp2s0 は 1500)"
ping -c 20 -i 0.2 -q $TARGET | tail -2 | sed 's/^/  /'
tracepath -n $TARGET 2>/dev/null | tail -3 | sed 's/^/  /'
echo "=== fio (${T}s / ${SZ})  iSCSI = /data, ローカル NVMe = /scratch"
for pair in "iSCSI:/data/fio-bench" "local:/scratch/fio-bench"; do
  w=${pair%%:*}; d=${pair#*:}
  run $w $d seq-read-1M-qd8     --rw=read      --bs=1M --iodepth=8  --direct=1
  run $w $d rand-read-4k-qd1    --rw=randread  --bs=4k --iodepth=1  --direct=1
  run $w $d rand-read-4k-qd32   --rw=randread  --bs=4k --iodepth=32 --direct=1
  run $w $d rand-write-4k-fsync --rw=randwrite --bs=4k --iodepth=1  --direct=1 --fsync=1
  rm -rf $d
done
cat <<'EOF'
=== 読み方
  - 4k qd1 の遅延 ≒ ネットワーク RTT + ターゲットの処理時間。ping の RTT と比べる。
  - qd32 で IOPS が伸びるなら、遅延は 1 件ずつの往復で決まっている (キュー深度で隠せる)。
  - 順次 1M の帯域が ~110 MB/s で頭打ちなら 1GbE の線速。
  - fsync: Zadara 側は LV (書き込みキャッシュの扱いは LIO の emulate_write_cache 次第) なので、
    ローカル NVMe の fsync と大きく違うことがある。
EOF
