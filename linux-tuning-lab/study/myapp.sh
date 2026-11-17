#!/bin/bash
# myapp の起動・停止 (systemctl の代わり)。
#   myapp start | stop | restart | status | log | pid
# 実行ユーザーや fd の上限は、いまの練習問題 (trouble start N) で決まる。
T=/tmp/.trouble; PIDF=/run/myapp.pid; LOG=/var/log/myapp/myapp.log
pid() { [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null && cat $PIDF; }
case "${1:-status}" in
  start)
    if [ -n "$(pid)" ]; then echo "already running (pid $(pid))"; exit 0; fi
    mode=$(cat $T/mode 2>/dev/null)
    case "$mode" in
      uid1000) setsid setpriv --reuid=1000 --regid=1000 --clear-groups python3 /study/myapp.py >/dev/null 2>&1 & ;;
      leak)    LEAK=1 setsid prlimit --nofile=64:4096 python3 /study/myapp.py >/dev/null 2>&1 & ;;
      *)       setsid python3 /study/myapp.py >/dev/null 2>&1 & ;;
    esac
    echo $! > $PIDF; sleep 1
    if [ -n "$(pid)" ]; then echo "myapp started (pid $(pid))"; else echo "myapp failed to start — see: myapp log"; exit 1; fi ;;
  stop) p=$(pid); [ -n "$p" ] && kill "$p" && echo "myapp stopped"; rm -f $PIDF ;;
  restart) "$0" stop; sleep 0.5; "$0" start ;;
  status) p=$(pid); if [ -n "$p" ]; then echo "running (pid $p)"; else echo "stopped"; fi ;;
  pid) pid ;;
  log) tail -n "${2:-20}" $LOG ;;
  *) echo "usage: myapp start|stop|restart|status|log [N]|pid"; exit 1 ;;
esac
