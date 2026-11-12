#!/usr/bin/env bash
# Run as root: sudo ./vramprobe3.sh  - is it the GuC log read itself, or just staying awake long enough?
# Read-only. Three load/freeze cycles, about 7 minutes. Prints all 16 VRAM channel temperatures each step.
set -u
PCI=0000:01:00.0; D=/sys/kernel/debug/dri/$PCI; H=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
U=${SUDO_USER:-fedora}; DIR=$(cd "$(dirname "$0")" && pwd); OUT=$DIR/results/vramprobe3.txt
t() { local c=""; for i in $(seq 6 21); do c="$c $(( $(cat $H/temp${i}_input)/1000 ))"; done
      echo "vram $(( $(cat $H/temp3_input)/1000 )) pkg $(( $(cat $H/temp2_input)/1000 )) fan $(cat $H/fan1_input) | ch:$c"; }
freeze() {
  runuser -u "$U" -- python3 "$DIR/parbench.py" -p 4 --tokens 600 >/dev/null
  sleep 75; echo "frozen (75 s after load):  $(t)"
}
hold() { ( exec 3< $D/forcewake_all; sleep "$1" ); sleep 2; echo "forcewake hold $1 s:        $(t)"; }
gl() { local a b; a=$(date +%s%3N); timeout 20 cat "$D/$1" >/dev/null 2>&1; b=$(date +%s%3N); sleep 2; echo "read $1 ($((b-a)) ms): $(t)"; }
{
echo "=== vramprobe3 $(date -u +%FT%TZ)"
systemctl stop b70-telemetry-kick
echo "--- cycle A: forcewake holds only, increasing length"
freeze; hold 0.5; hold 0.5; hold 2; hold 5; hold 10; hold 10
echo "--- cycle B: gt1 guc_log reads only"
freeze; gl tile0/gt1/uc/guc_log; gl tile0/gt1/uc/guc_log; gl tile0/gt1/uc/guc_log; gl tile0/gt1/uc/guc_log
echo "--- cycle C: gt0 guc_log reads only"
freeze; gl tile0/gt0/uc/guc_log; gl tile0/gt0/uc/guc_log; gl tile0/gt0/uc/guc_log; gl tile0/gt0/uc/guc_log
systemctl start b70-telemetry-kick
echo "done; fan service restarted"
} 2>&1 | tee "$OUT"
chown "$U" "$OUT" 2>/dev/null
