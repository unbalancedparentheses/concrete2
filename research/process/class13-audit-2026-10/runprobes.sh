#!/usr/bin/env bash
# usage: runprobes.sh <compiler> <dir>; prints name | native | interp
cc=$1; d=$2
for f in "$d"/*.con; do
  n=$(basename "$f" .con)
  out=$(timeout 60 "$cc" "$f" -o "/tmp/c13p_$n.bin" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then nat="ERR:$(echo "$out" | grep -m1 -oE 'error\[[a-z-]+\]: (\(E[0-9]+\))?.{0,70}' || echo "$out" | head -c 120 | tr '\n' ' ')"
  else timeout 20 "/tmp/c13p_$n.bin" >/dev/null 2>&1; nat="exit=$?"; fi
  iout=$(timeout 60 "$cc" "$f" --interp 2>&1); irc=$?
  if [ $irc -eq 0 ]; then int="out=$(echo "$iout" | grep -v '^\s*$' | tail -1)"
  else int="ERR:$(echo "$iout" | grep -m1 -oE 'error\[[a-z-]+\]: (\(E[0-9]+\))?.{0,60}' || echo "$iout" | tail -c 100 | tr '\n' ' ')"; fi
  printf '%s\t| %s\t| %s\n' "$n" "$nat" "$int"
done
