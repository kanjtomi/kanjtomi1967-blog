#!/bin/bash
# vmstat / iostat を読む練習。study Pod の中で `drill` と打つ。
#   drill            vmstat と iostat の両方を見て当てる
#   drill vmstat     vmstat だけで当てる
#   drill iostat     iostat だけで当てる
#   drill <種類> N   負荷を指定して練習 (cpu / fsync / seqread / seqwrite / randread)
# 裏で 5 種類の負荷のどれか 1 つを起こし、「負荷前」と「負荷中」の出力を見せる。
# ホストは MariaDB / ServiceNow と共有なので、負荷のない時でも少し値が動く (これも練習のうち)。
# 負荷は上限付き (CPU 1 コア、ディスク帯域 300MB/s など) で、1 問 20 秒ほどで終わる。
VIEW=${1:-both}; FORCE=""
case "$VIEW" in cpu|fsync|seqread|seqwrite|randread) FORCE=$VIEW; VIEW=${2:-both} ;; esac
S=/scratch/drill-$$; mkdir -p $S
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill -- -"$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf $S; }
trap cleanup EXIT INT TERM
B() { printf '\033[1m%s\033[0m\n' "$*"; }

disk() { # /scratch の下の物理ディスク (例 nvme0n1)
  local mm s; mm=$(mountpoint -d /scratch); s=$(ls -d /sys/dev/block/$mm/slaves/* 2>/dev/null | head -1)
  [ -n "$s" ] || { basename "$(readlink -f /sys/dev/block/$mm)"; return; }
  s=$(readlink -f "$s"); [ -f "$s/partition" ] && s=$(dirname "$s"); basename "$s"
}
DEV=$(disk)
F="--filename=$S/data.bin --size=512M --time_based --runtime=600 --group_reporting"
bg() { setsid "$@" >/dev/null 2>&1 & PIDS+=($!); }

KINDS=(cpu fsync seqread seqwrite randread)
KIND=${FORCE:-${KINDS[$((RANDOM % 5))]}}
# 読み込み系は先にファイルを用意しておく (準備の書き込みが問題に混ざらないように)
case $KIND in seqread|randread)
  printf "準備中..."; fio --name=prep $F --runtime=1 --rw=write --bs=1M --direct=1 >/dev/null 2>&1; echo ;; esac

show() { # 見出し
  [ "$VIEW" != iostat ] && { B "vmstat 1 (3 秒)"; vmstat -w 1 4 | sed '3d'; }
  [ "$VIEW" != vmstat ] && { B "iostat -dxy $DEV 1 (3 秒の平均)"; iostat -dxy $DEV 3 1 | grep -E "Device|$DEV" | cut -c1-200; }
}

clear 2>/dev/null
B "=== 負荷をかける前 ==="; show
case $KIND in
  cpu)      bg stress-ng --cpu 2 --cpu-method matrixprod ;;
  fsync)    bg fio --name=a $F --rw=randwrite --bs=4k --ioengine=sync --fdatasync=1 --numjobs=6 ;;
  seqread)  bg fio --name=a $F --rw=read --bs=1M --ioengine=libaio --iodepth=8 --direct=1 --rate=300m ;;
  seqwrite) bg fio --name=a $F --rw=write --bs=1M --ioengine=libaio --iodepth=8 --direct=1 --rate=,300m ;;
  randread) bg fio --name=a $F --rw=randread --bs=4k --ioengine=libaio --iodepth=16 --direct=1 --rate_iops=30000 ;;
esac
sleep 4
echo; B "=== 負荷をかけている最中 ==="; show
cleanup; PIDS=()

cat <<'EOF'

問題: 何が起きている?
  A) CPU を使う計算 (ディスクはほぼ使わない)
  B) 4k の書き込みを 1 回ごとに fsync (DB のコミット)
  C) 大きなファイルをディスクから順番に読む
  D) 大きなファイルをディスクに順番に書く
  E) 小さな (4k) 読み込みをばらばらな場所から大量に (DB の索引検索)
EOF
declare -A KEY=([cpu]=A [fsync]=B [seqread]=C [seqwrite]=D [randread]=E)
if [ -t 0 ]; then read -r -p "答え (A-E) > " ans; ans=${ans^^}; else ans="?"; fi
if [ "$ans" = "${KEY[$KIND]}" ]; then B "正解: ${KEY[$KIND]}"; else B "答え: ${KEY[$KIND]}  (あなた: $ans)"; fi
echo
case $KIND in
  cpu) cat <<'EOF'
決め手:
  vmstat: us が上がる (20 コア中 1 コアぶん = 約 5%)、r が 1〜2 増える。bi/bo・wa は変わらない
  iostat: 何も変わらない (r/s・w/s はホストのほかの I/O だけ)
  ※ この Pod の上限は 1 コアなので、stress-ng 2 つでも us は 1 コアぶんしか上がらない (レッスン 2 のスロットリング)
EOF
  ;;
  fsync) cat <<'EOF'
決め手:
  vmstat: b (I/O 待ちで寝ているプロセス) が増え、wa が上がる。us/sy はほぼそのまま。bo は数 MB/s と小さい
  iostat: w/s は千以上あるのに wkB/s は数 MB/s → wareq-sz が 4k 前後。f/s (flush) が数百、%util は 90% 以上
  つまり「たくさん書いてはいないのに、ディスクがずっと忙しい」= 1 件ずつ flush を待っている
EOF
  ;;
  seqread) cat <<'EOF'
決め手:
  vmstat: bi が大きい (約 300,000 KB/s = 300MB/s)。bo は小さい。CPU はあまり使わない
  iostat: rkB/s ≒ 300MB/s、r/s は約 600 → rareq-sz 512 (fio は 1M で読むが、デバイスの上限で 512k 2 つに分かれる)。
          r_await は短い (0.5ms)、%util は 17% 程度
  ※ direct I/O なので buff/cache は増えない (ページキャッシュを通さない)
EOF
  ;;
  seqwrite) cat <<'EOF'
決め手:
  vmstat: bo が大きい (約 300,000 KB/s)。bi は小さい
  iostat: wkB/s ≒ 300MB/s、w/s は約 600 → wareq-sz 約 500 (512k)。B (fsync) との違いは
          「帯域が大きく、1 件が大きい」こと。fsync は件数は多いが 1 件 4k で帯域は小さい
EOF
  ;;
  randread) cat <<'EOF'
決め手:
  vmstat: bi は増えるが C ほどではない (4k × 数万/秒 ≒ 100MB/s 前後)。in/cs (割り込み・切り替え) が大きく増える
  iostat: r/s が数万と非常に多く、rareq-sz が 4k。aqu-sz が上がる (同時に 16 件)。r_await はそれでも短い (NVMe)
  C との違いは「件数が多くて 1 件が小さい」こと。HDD だとこれが一番遅い (シークのため)
EOF
  ;;
esac
cat <<'EOF'

列のおさらい
  vmstat: r=CPU 待ち  b=I/O 待ち  bi/bo=ディスク読み書き KB/s  in/cs=割り込み/切り替え  us sy id wa
  iostat: r/s w/s=件数  rkB/s wkB/s=帯域  rareq-sz wareq-sz=1 件の大きさ  r_await w_await=1 件の待ち (ms)
          aqu-sz=待ち行列の長さ  %util=何かを処理していた時間の割合 (NVMe では限界の目安にならない)
もう 1 問: drill   種類を指定: drill fsync など
EOF
