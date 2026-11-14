#!/bin/bash
# この Pod の cgroup (v2) の今の状態を表示する。どのシナリオの最中でも別の exec から使える。
#   /scenarios/observe.sh        1 回だけ
#   /scenarios/observe.sh 2      2 秒ごとに繰り返す (Ctrl-C で止める)
CG=/sys/fs/cgroup
show() {
  echo "=== $(date +%T) cgroup: $(cat /proc/self/cgroup | cut -d: -f3)"
  echo "cpu.max        : $(cat $CG/cpu.max)   (quota period [usec]; max = 無制限)"
  awk '{printf "cpu.stat       : %s=%s\n", $1, $2}' $CG/cpu.stat | grep -E 'usage_usec|nr_periods|nr_throttled|throttled_usec'
  echo "memory.max     : $(cat $CG/memory.max)   memory.current: $(cat $CG/memory.current)"
  grep -E '^(anon|file|file_dirty|file_writeback|active_file|inactive_file|workingset_refault_file|pgmajfault) ' $CG/memory.stat | awk '{printf "memory.stat    : %s=%s\n", $1, $2}'
  awk '{printf "memory.events  : %s=%s\n", $1, $2}' $CG/memory.events
  if [ -s $CG/io.stat ]; then sed 's/^/io.stat        : /' $CG/io.stat; fi
  for p in cpu memory io; do if [ -r $CG/$p.pressure ]; then echo "$p.pressure : $(head -1 $CG/$p.pressure)"; fi; done
  return 0
}
if [ -n "${1:-}" ]; then while true; do clear; show; sleep "$1"; done; else show; fi
