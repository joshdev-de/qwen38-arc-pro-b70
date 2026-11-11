#!/usr/bin/env bash
# ./powerbench.sh <tag>  - run speedbench, parbench p4 and longctx 60000 against production while sampling
# card energy, temperatures and fan from hwmon. Appends one summary line per test to results/power/<tag>.txt
H=$(echo /sys/bus/pci/devices/0000:01:00.0/hwmon/hwmon*)
cd "$(dirname "$0")"; mkdir -p results/power; TAG=$1; OUT=results/power/$TAG.txt
echo "=== $TAG cap=$(cat $H/power1_cap) $(date -u +%T)" | tee -a $OUT
measure() {  # measure <name> <cmd...>
  local name=$1; shift; local S=results/power/$TAG.$name.samples
  ( while :; do echo "$(date +%s.%N) $(cat $H/energy1_input) $(cat $H/energy2_input) $(cat $H/temp2_input) $(cat $H/temp3_input) $(cat $H/fan1_input)"; sleep 1; done ) > $S &
  local sp=$!
  local res; res=$("$@" 2>&1 | tail -1)
  kill $sp 2>/dev/null; wait $sp 2>/dev/null
  python3 - "$S" "$name" "$res" <<'P' | tee -a $OUT
import sys
rows=[list(map(float,l.split())) for l in open(sys.argv[1]) if len(l.split())==6]
t=rows[-1][0]-rows[0][0]; card=(rows[-1][1]-rows[0][1])/1e6/t; pkg=(rows[-1][2]-rows[0][2])/1e6/t
# peak 5-s card power
pk=max((rows[i+5][1]-rows[i][1])/1e6/(rows[i+5][0]-rows[i][0]) for i in range(len(rows)-5)) if len(rows)>6 else card
print(f"{sys.argv[2]:10s} {t:5.0f}s  card avg {card:5.1f} W (peak5s {pk:5.1f})  pkg avg {pkg:5.1f} W  pkg max {max(r[3] for r in rows)/1000:.0f} C  vram max {max(r[4] for r in rows)/1000:.0f} C  fan max {max(r[5] for r in rows):.0f} rpm | {sys.argv[3][:150]}")
P
}
measure speed python3 speedbench.py --tag "$TAG" --tokens 600
measure par4 python3 parbench.py -p 4 --tokens 768
measure prefill python3 longctx.py --tokens 60000 --seed $RANDOM
