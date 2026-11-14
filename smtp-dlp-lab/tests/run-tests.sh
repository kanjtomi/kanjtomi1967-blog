#!/bin/bash
# Sends one test mail per case through the DLP gateway and checks the verdict.
#   kubectl -n smtp-dlp-lab exec deploy/client -- bash /opt/tests/run-tests.sh
# The card numbers are the brands' published test numbers, not real cards.
SERVER=${SERVER:-mta.smtp-dlp-lab.svc.cluster.local:25}
FROM=${FROM:-alice@corp.lab}
TO=${TO:-bob@partner.example}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ok=0
ng=0

utf8_subject() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"; }
UTF8=(--add-header "MIME-Version: 1.0" --add-header "Content-Type: text/plain; charset=UTF-8"
      --add-header "Content-Transfer-Encoding: 8bit")

# check <case name> <expected: pass|block> <swaks args...>
check() {
  local name=$1 expect=$2 out got reply
  shift 2
  out=$(swaks --server "$SERVER" --from "$FROM" --to "$TO" "$@" 2>&1)
  # the last 250/550 the server sent is the end-of-DATA verdict
  reply=$(printf '%s\n' "$out" | grep -E '^ *<(-|\*\*) +(250|550) ' | tail -1 | sed -E 's/^ *<(-|\*\*) +//')
  if printf '%s' "$reply" | grep -q 'blocked by DLP'; then
    got=block
  elif printf '%s' "$reply" | grep -q 'queued as'; then
    got=pass
  else
    got=error
  fi
  if [ "$got" = "$expect" ]; then
    ok=$((ok + 1)); printf 'OK  %-34s %-5s %s\n' "$name" "$got" "$reply"
  else
    ng=$((ng + 1)); printf 'NG  %-34s want=%s got=%s\n%s\n' "$name" "$expect" "$got" "$out"
  fi
}

# --- attachments
printf 'id,name,amount\n1,apple,120\n2,orange,80\n' > "$WORK/sales.csv"
printf 'id,name,card\n1,Taro Yamada,5555-5555-5555-4444\n' > "$WORK/customers.csv"
(cd "$WORK" && zip -q customers.zip customers.csv)
(cd "$WORK" && zip -q -P lab-pass locked.zip customers.csv)
printf 'MZ\x90\x00 not really a program\n' > "$WORK/setup.exe"

check "01 普通のメール"                pass --header "Subject: weekly report" --body "See you at the meeting."
check "02 本文にカード番号"            block --header "Subject: order" --body "Card: 4111 1111 1111 1111 exp 12/29"
check "03 16桁だがLuhn不一致"          pass --header "Subject: order" --body "Order no. 4111 1111 1111 1112"
check "04 全角のカード番号"            block --header "Subject: $(utf8_subject '注文')" "${UTF8[@]}" \
  --body "カード番号は ４１１１１１１１１１１１１１１１ です"
check "05 件名に「社外秘」"            block --header "Subject: $(utf8_subject '【社外秘】来期の売上見込み')" \
  --body "Please see attached."
check "06 本文に confidential"         block --header "Subject: plan" --body "This is Confidential, do not share."
check "07 CSV添付(問題なし)"           pass --header "Subject: sales" --body "Attached." \
  --attach-type text/csv --attach @"$WORK/sales.csv"
check "08 CSV添付にカード番号"         block --header "Subject: customers" --body "Attached." \
  --attach-type text/csv --attach @"$WORK/customers.csv"
check "09 ZIP内のCSVにカード番号"      block --header "Subject: customers" --body "Zipped." \
  --attach-type application/zip --attach @"$WORK/customers.zip"
check "10 パスワード付きZIP"           block --header "Subject: customers" --body "Password in next mail." \
  --attach-type application/zip --attach @"$WORK/locked.zip"
check "11 .exe 添付"                   block --header "Subject: tool" --body "Run this." \
  --attach-type application/octet-stream --attach @"$WORK/setup.exe"

echo
echo "結果: OK=$ok NG=$ng   (通過したメールと DLP の通知: http://192.168.0.200:30825)"
[ "$ng" -eq 0 ]
