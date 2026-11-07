#!/bin/bash
# ディスク I/O: fio でブロックサイズ・キュー深さ・direct/バッファ・fsync の違いを見る。
#   /scenarios/03-disk-io.sh [秒=10] [サイズ=1G]
# 作業場所 /scratch は emptyDir = /glide (Samsung T5, USB 3)。MariaDB / ServiceNow と共有なので
# 1 テスト 10 秒・1G 程度に留めること。
# 試すこと: iodepth を変える、--direct=0 にする、bs を 4k/64k/1M で比べる、別の exec で `iostat -x 1`。
T=${1:-10}; SZ=${2:-1G}; D=/scratch/fio; mkdir -p $D
read -r -d '' SUMMARY <<'PY'
import json, sys
j = json.load(sys.stdin)["jobs"][0]
name = sys.argv[1]
for k in ("read", "write"):
    o = j[k]
    if o["io_bytes"] == 0:
        continue
    p = o["clat_ns"].get("percentile", {})
    print("%-22s %-5s %8.1f MB/s %9.0f IOPS  p50 %8.0f us  p99 %8.0f us" % (
        name, k, o["bw"] / 1024, o["iops"],
        p.get("50.000000", 0) / 1000, p.get("99.000000", 0) / 1000))
PY
run() { # name, fio args...
  local n=$1 out; shift
  out=$(fio --name=$n --directory=$D --size=$SZ --runtime=$T --time_based --ioengine=libaio \
            --group_reporting --output-format=json "$@" 2>&1) || { echo "$n: fio failed: $(echo "$out" | head -3)"; return; }
  echo "$out" | python3 -c "$SUMMARY" "$n"
}
echo "テスト時間 ${T}s / ファイル ${SZ} / 場所 $D"
run seq-write-1M-qd8     --rw=write    --bs=1M --iodepth=8  --direct=1
run seq-read-1M-qd8      --rw=read     --bs=1M --iodepth=8  --direct=1
run rand-read-4k-qd1     --rw=randread --bs=4k --iodepth=1  --direct=1
run rand-read-4k-qd32    --rw=randread --bs=4k --iodepth=32 --direct=1
run rand-write-4k-fsync  --rw=randwrite --bs=4k --iodepth=1 --direct=1 --fsync=1
rm -rf $D
