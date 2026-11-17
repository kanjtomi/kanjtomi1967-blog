#!/bin/bash
# Linux トラブルシューティング練習。study Pod の中で使う。
#   trouble            一覧
#   trouble start N    障害 N を起こす (前の障害は片付ける)。チケットが表示される
#   trouble hint       ヒント (何度でも。段階的に出る)
#   trouble check      直ったか判定する
#   trouble answer     原因と直し方
#   trouble reset      全部元に戻す
# 練習対象のサービスは myapp (myapp start|stop|status|log)。
# /tmp/.trouble に答えと元の設定が入っているが、見ない約束。
T=/tmp/.trouble; mkdir -p $T
APPLOG=/var/log/myapp/myapp.log
CONF=/etc/myapp/myapp.conf
H() { printf '\n\033[1m%s\033[0m\n' "$*"; }

reset_all() {
  myapp stop >/dev/null 2>&1
  for f in $T/*.pid; do [ -f "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
  pkill -f '^python3 -m http.server 8080' 2>/dev/null
  pkill -f 'TROUBLE-' 2>/dev/null
  [ -f $T/resolv.conf.orig ] && cat $T/resolv.conf.orig > /etc/resolv.conf
  mkdir -p /etc/myapp /var/log/myapp /data/myapp
  printf 'port = 8080\ndata_dir = /data/myapp\nupstream = web.tuning-lab.svc.cluster.local:80\n' > $CONF
  chmod 644 $CONF; chown root:root $CONF
  rm -rf /data/myapp/* /data/.cache 2>/dev/null
  chown root:root /data/myapp; chmod 755 /data/myapp
  chmod 777 /var/log/myapp; : > $APPLOG; chmod 666 $APPLOG
  rm -f $T/mode $T/scenario $T/hint
}
bgproc() { # name command... : 裏で動かして pid を記録する
  local n=$1; shift
  setsid "$@" >/dev/null 2>&1 & echo $! > $T/$n.pid
}
health() { curl -s -m 5 -o /tmp/.trouble/health.out -w '%{http_code}' http://127.0.0.1:8080/health 2>/dev/null; }

ticket() { H "チケット #$1"; shift; printf '%s\n' "$@"; echo; echo "調べて直したら: trouble check   (行き詰まったら: trouble hint)"; }

start() {
  reset_all
  [ -f $T/resolv.conf.orig ] || cp /etc/resolv.conf $T/resolv.conf.orig
  echo "$1" > $T/scenario
  case "$1" in
    1) # ポートが別のプロセスに使われている
      bgproc hog python3 -m http.server 8080 --directory /tmp
      sleep 1; myapp start >/dev/null 2>&1
      ticket 1 "「myapp を再起動したら上がってこなくなった。昨日まで動いていた」" \
               "症状: curl http://127.0.0.1:8080/health が myapp の応答を返さない" ;;
    2) # 消したのに開かれたままのファイルでディスクが一杯
      myapp start >/dev/null 2>&1
      bgproc filler python3 -c '
import os, time  # TROUBLE-filler
os.makedirs("/data/.cache", exist_ok=True)
p = "/data/.cache/debug-dump.bin"; f = open(p, "wb"); b = b"x" * 1048576
try:
    while True: f.write(b); f.flush()
except OSError: pass
os.remove(p)          # 消したが閉じていない
while True: time.sleep(3600)'
      sleep 4
      ticket 2 "「/health が 500 を返す。ディスクが一杯らしいので大きいファイルを探したが見つからない」" \
               "症状: curl http://127.0.0.1:8080/health → 500" ;;
    3) # DNS
      myapp start >/dev/null 2>&1
      sed -E 's/^nameserver .*/nameserver 192.0.2.53/' $T/resolv.conf.orig > /etc/resolv.conf
      echo "options timeout:1 attempts:1" >> /etc/resolv.conf
      ticket 3 "「myapp の /health がエラーになる。相手の web サーバーは動いていると担当者は言っている」" \
               "症状: curl http://127.0.0.1:8080/health → 500" ;;
    4) # 権限 (2 段階)
      echo uid1000 > $T/mode
      chmod 600 $CONF
      myapp start >/dev/null 2>&1
      ticket 4 "「セキュリティ対応で myapp を root ではなく uid 1000 で動かすように変えたら、起動しなくなった」" \
               "症状: myapp status が stopped。myapp start しても上がらない" ;;
    5) # ファイルディスクリプタ枯渇
      echo leak > $T/mode
      myapp start >/dev/null 2>&1
      bgproc traffic bash -c 'while :; do curl -s -m 2 -o /dev/null http://127.0.0.1:8080/health; sleep 0.2; done # TROUBLE-traffic'
      sleep 15
      ticket 5 "「myapp が起動してしばらくは動くが、だんだんエラーしか返さなくなる。再起動すると直るが、またなる」" \
               "症状: curl http://127.0.0.1:8080/health → 500 (起動直後は 200)" ;;
    *) echo "番号は 1〜5"; exit 1 ;;
  esac
}

hint() {
  local s; s=$(cat $T/scenario 2>/dev/null) || { echo "先に trouble start N"; exit 1; }
  local n; n=$(( $(cat $T/hint 2>/dev/null || echo 0) + 1 )); echo $n > $T/hint
  local -a h
  case $s in
    1) h=("まずログ: myapp log (または tail /var/log/myapp/myapp.log)"
          "Address already in use = そのポートを別のプロセスが持っている。誰が? → ss -ltnp"
          "ss -ltnp | grep 8080 で PID が分かる。ps -fp <PID> で正体を確認し、kill <PID> → myapp start") ;;
    2) h=("ログと容量: myapp log / df -h /data"
          "df は一杯なのに du -sh /data/* /data/.[!.]* は小さい。差は「消したのにまだ開かれているファイル」"
          "ls -l /proc/*/fd 2>/dev/null | grep deleted で、開いているプロセスとファイルが分かる"
          "そのプロセスを止める (kill <PID>) か、: > /proc/<PID>/fd/<N> で中身を空にする。再起動できないプロセスなら後者") ;;
    3) h=("ログ: myapp log。エラーの種類は何?"
          "Temporary failure in name resolution = 名前が引けない。getent hosts web.tuning-lab.svc.cluster.local"
          "名前はどこに問い合わせている? cat /etc/resolv.conf。その nameserver は正しい? (192.0.2.0/24 は文書用のアドレス)"
          "クラスタの DNS は外から kubectl -n kube-system get svc kube-dns で分かる。/etc/resolv.conf の nameserver を直す"
          "sed -i が Device or resource busy で失敗する? /etc/resolv.conf は k8s が bind mount しているので置き換え (rename) できない。中身を上書きする: sed 's/192.0.2.53/<正しいIP>/' /etc/resolv.conf > /tmp/r && cat /tmp/r > /etc/resolv.conf") ;;
    4) h=("ログ: myapp log"
          "Permission denied のファイルは? ls -l で所有者と権限を見る。myapp は uid 1000 で動く (id 1000 で確認)"
          "設定ファイルを uid 1000 が読めるようにする (chmod 644 か chown 1000)。直したら myapp start して、もう一度 /health"
          "まだ 500 なら 2 つ目の問題。ログの次のエラーを読む。データの置き場所 (/data/myapp) に書けるか?") ;;
    5) h=("ログ: myapp log。エラーの種類は何?"
          "Too many open files = ファイルディスクリプタ (fd) の上限。上限は cat /proc/<PID>/limits の Max open files"
          "今いくつ開いている? ls /proc/<PID>/fd | wc -l。何を開いている? ls -l /proc/<PID>/fd | tail"
          "応急処置: prlimit --pid <PID> --nofile=4096:4096。本当の原因 (開きっぱなし) も報告すること") ;;
  esac
  local i
  for ((i=0; i<n && i<${#h[@]}; i++)); do echo "ヒント $((i+1)): ${h[$i]}"; done
  [ $n -ge ${#h[@]} ] && echo "(ヒントはここまで。trouble answer で答え)"
}

check() {
  local s code; s=$(cat $T/scenario 2>/dev/null) || { echo "先に trouble start N"; exit 1; }
  code=$(health)
  case $s in
    1|2|4) ;;
    3) getent hosts web.tuning-lab.svc.cluster.local >/dev/null || { echo "✗ まだ名前が引けない (getent hosts web.tuning-lab.svc.cluster.local)"; exit 1; } ;;
    5) local p; p=$(myapp pid)
       if [ -n "$p" ]; then sleep 3; code=$(health)
         local lim; lim=$(awk '/Max open files/{print $4}' /proc/$p/limits)
         [ "${lim:-0}" -lt 1024 ] && { echo "✗ fd の上限がまだ ${lim} のまま (myapp を再起動しただけだと、またすぐ枯渇する)"; exit 1; }
       fi ;;
  esac
  if [ "$code" = 200 ]; then
    echo "✓ 直りました (/health = 200)。原因の説明は: trouble answer"
  else
    echo "✗ まだです: /health = ${code:-応答なし} $(cat $T/health.out 2>/dev/null | head -1)"
    echo "  myapp status: $(myapp status)"
  fi
}

answer() {
  case $(cat $T/scenario 2>/dev/null) in
    1) cat <<'EOF'
原因: 誰かが動かしたままの python3 -m http.server がポート 8080 を使っていて、myapp が bind できない
      (ログ: "cannot bind 0.0.0.0:8080: [Errno 98] Address already in use")
調べ方: myapp log → ss -ltnp | grep :8080 (users:(("python3",pid=...))) → ps -fp <PID>
直し方: kill <PID> → myapp start
再発防止: サービスは systemd などで管理して、手で起動したものを残さない。ポートの割り当てを決めておく
EOF
    ;;
    2) cat <<'EOF'
原因: あるプロセスが /data/.cache/debug-dump.bin を書き続けて /data を一杯にし、そのファイルは削除されたが
      プロセスが開いたままなので領域が解放されない。df は 100% なのに du では見つからない
      (ログ: "[Errno 28] No space left on device")
調べ方: df -h /data と du -sh の差 → ls -l /proc/*/fd 2>/dev/null | grep deleted (lsof があれば lsof +L1)
直し方: そのプロセスを止める (kill)。止められないなら : > /proc/<PID>/fd/<N> で切り詰める
再発防止: ログは rm ではなくローテート (copytruncate か、プロセスに再オープンさせる)。df と du の両方を監視
EOF
    ;;
    3) cat <<'EOF'
原因: /etc/resolv.conf の nameserver が存在しないアドレス (192.0.2.53、文書用の範囲) になっていて、
      web.tuning-lab.svc.cluster.local が引けない (ログ: "Temporary failure in name resolution")。
      相手のサーバーは正常で、IP アドレスで curl すれば届く
調べ方: myapp log → getent hosts <名前> (失敗) → cat /etc/resolv.conf → 外から kubectl -n kube-system get svc kube-dns
        → 正しい nameserver なら dig @<IP> <名前> で引けることを確かめる
直し方: /etc/resolv.conf の nameserver をクラスタの DNS (kube-dns の ClusterIP) に戻す。
        コンテナの /etc/resolv.conf は bind mount なので sed -i (新しいファイルを作って rename) は
        "Device or resource busy" で失敗する。cat /tmp/r > /etc/resolv.conf のように中身を上書きする。
        (Pod を作り直せば kubelet が正しい内容で作り直す。恒久的な設定は Pod の dnsConfig / dnsPolicy)
ポイント: 「つながらない」を名前解決・経路・相手のサービスに分ける。IP で試すと DNS かどうかが一発で分かる
EOF
    ;;
    4) cat <<'EOF'
原因は 2 つ:
  1. /etc/myapp/myapp.conf が root:root 600 で、uid 1000 からは読めない
     (ログ: "cannot read config ... [Errno 13] Permission denied")
  2. それを直しても、データの置き場所 /data/myapp が root:root 755 で uid 1000 は書けない
     (ログ: "/health failed: PermissionError ... /data/myapp/requests.log")
調べ方: myapp log → ls -l /etc/myapp/myapp.conf /data/myapp → id 1000 / ps -o uid,cmd -p <PID>
直し方: chmod 644 /etc/myapp/myapp.conf (秘密が入るなら chgrp + 640)、chown 1000 /data/myapp
ポイント: 実行ユーザーを変えたら、読むファイル・書くディレクトリ・待ち受けるポート (1024 未満は特権) を全部見直す。
         1 つ直したら必ずもう一度試す (エラーは 1 つずつしか出ない)
EOF
    ;;
    5) cat <<'EOF'
原因: myapp が /health のたびにファイルを開いて閉じない (fd リーク)。プロセスの fd 上限が 64 なので、
      数十リクエストで使い切り "[Errno 24] Too many open files" になる。再起動で fd が解放されるので一時的に直る
調べ方: myapp log → cat /proc/<PID>/limits (Max open files 64) → ls /proc/<PID>/fd | wc -l (上限に張り付き)
        → ls -l /proc/<PID>/fd で同じファイルを大量に開いていることが分かる
直し方 (応急): prlimit --pid <PID> --nofile=4096:4096 (起動時なら ulimit -n / systemd の LimitNOFILE)
本当の直し方: リークを直す (開いたファイルを閉じる)。上限を上げても、リークがあればいつかまた枯渇する。
             顧客には「応急処置をした」「原因はアプリの fd リーク」「開発側の修正が必要」の 3 点を伝える
EOF
    ;;
    *) echo "先に trouble start N" ;;
  esac
}

case "${1:-}" in
  start) start "${2:-}" ;;
  hint) hint ;;
  check) check ;;
  answer) answer ;;
  reset) reset_all; [ -f $T/resolv.conf.orig ] && cat $T/resolv.conf.orig > /etc/resolv.conf; echo "元に戻しました" ;;
  *) cat <<'EOF'
Linux トラブルシューティング練習 (study Pod)
  trouble start 1   ポートが使われていて起動しない          (ss -ltnp, kill)
  trouble start 2   ディスクが一杯なのにファイルが見つからない (df と du の差, /proc/*/fd)
  trouble start 3   相手は動いているのにつながらない       (DNS, /etc/resolv.conf)
  trouble start 4   実行ユーザーを変えたら起動しない        (権限, 2 段階)
  trouble start 5   しばらくするとエラーしか返さない        (fd の上限とリーク)
  trouble hint / check / answer / reset
対象のサービス: myapp start | stop | status | log
EOF
  ;;
esac
