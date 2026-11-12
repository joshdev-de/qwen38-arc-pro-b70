#!/usr/bin/env bash
# Run as root: sudo ./kicktune.sh [seconds per window, default 90]
# Finds the keep-alive setting that keeps the idle B70 in its low-power state longest.
# Read-only on the card: forcewake_all holds and hwmon reads only. Stops the workaround service
# for the test and restarts it at the end. Each setting is measured twice, interleaved, so slow
# temperature drift does not favour one setting. Card power from hwmon energy1_input.
set -u
W=${1:-90}
PCI=0000:01:00.0; FW=/sys/kernel/debug/dri/$PCI/forcewake_all; H=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
RES=/sys/bus/pci/devices/$PCI/tile0/gt0/gtidle/idle_residency_ms
OUT="$(dirname "$0")/results/kicktune.txt"
systemctl stop b70-telemetry-kick
trap 'systemctl start b70-telemetry-kick' EXIT

# setting = "interval hold reads": kick every <interval> s, hold forcewake <hold> s (0 = no forcewake),
# and <reads> = hwmon reads between kicks: none | temp (temp2 each second) | fan (fan1 each second)
SETTINGS=("0 0 none" "10 0.5 none" "5 0.5 none" "3 0.5 none" "2 0.2 none" "1 0.1 none" "10 0.1 none" "10 2 none"
          "20 0.5 none" "10 0.5 temp" "10 0.5 fan" "0 0 temp" "5 0.1 temp" "10 0 temp")

run() {  # interval hold reads
  local iv=$1 hold=$2 reads=$3 end e1 t1 r1 e2 t2 r2 next
  ( exec 3< "$FW"; sleep 0.5; cat "$H/temp2_input" >/dev/null ); sleep 2      # same starting point for every setting
  e1=$(cat "$H/energy1_input"); t1=$(date +%s%3N); r1=$(cat "$RES")
  end=$(( $(date +%s) + W )); next=0
  while [ "$(date +%s)" -lt "$end" ]; do
    if [ "$iv" != 0 ] && [ "$(date +%s)" -ge "$next" ]; then
      if [ "$hold" != 0 ]; then ( exec 3< "$FW"; sleep "$hold"; cat "$H/temp2_input" >/dev/null ); fi
      next=$(( $(date +%s) + iv ))
    fi
    case $reads in temp) cat "$H/temp2_input" >/dev/null;; fan) cat "$H/fan1_input" >/dev/null;; esac
    sleep 1
  done
  e2=$(cat "$H/energy1_input"); t2=$(date +%s%3N); r2=$(cat "$RES")
  ( exec 3< "$FW"; sleep 0.5; p=$(cat "$H/temp2_input"); echo "$(date -u +%T) interval=$iv hold=$hold reads=$reads W=$(awk "BEGIN{printf \"%.1f\", ($e2-$e1)/($t2-$t1)/1000}") idle%=$(( (r2-r1)*100/(t2-t1) )) pkg=$p" | tee -a "$OUT" )
}

echo "# kicktune $(date -u +%F\ %T), ${W}s windows" | tee -a "$OUT"
for pass in 1 2; do
  for s in "${SETTINGS[@]}"; do
    run $s
  done
done
echo "done" | tee -a "$OUT"
