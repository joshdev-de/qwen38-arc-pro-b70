#!/usr/bin/env bash
# Run as root: sudo ./vramprobe2.sh   - narrows down which media-GT (gt1) debugfs read refreshes VRAM temperature.
# Read-only, same safety rules as vramprobe.sh. Two load/freeze cycles, about 5 minutes.
set -u
PCI=0000:01:00.0; D=/sys/kernel/debug/dri/$PCI; H=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
U=${SUDO_USER:-fedora}; DIR=$(cd "$(dirname "$0")" && pwd); OUT=$DIR/results/vramprobe2.txt
t() { echo "vram $(( $(cat $H/temp3_input)/1000 )) pkg $(( $(cat $H/temp2_input)/1000 )) fan $(cat $H/fan1_input)"; }
freeze() {
  runuser -u "$U" -- python3 "$DIR/parbench.py" -p 4 --tokens 600 >/dev/null
  echo "end of load:         $(t)"; sleep 75; echo "75 s later (frozen): $(t)"
}
probe() {
  local before after mark=""
  before=$(cat $H/temp3_input); timeout 10 cat "$D/$1" >/dev/null 2>&1; sleep 5; after=$(cat $H/temp3_input)
  [ "$after" != "$before" ] && mark="   <== VRAM READING CHANGED"
  echo "read $1: $(t)$mark"
}
{
echo "=== vramprobe2 $(date -u +%FT%TZ)"
systemctl stop b70-telemetry-kick
echo "--- cycle 1: every gt1 file except guc_log, then guc_log last"
freeze
for f in tile0/gt1/uc/gsc_info tile0/gt1/uc/guc_info tile0/gt1/uc/guc_ctb tile0/gt1/uc/huc_info tile0/gt1/uc/guc_pc \
         tile0/gt1/powergate_info tile0/gt1/hw_engines tile0/gt1/uc/guc_log_lfd tile0/gt0/uc/guc_log tile0/gt1/uc/guc_log; do probe $f; done
echo "--- cycle 2: gt1 guc_log first, on its own"
freeze
sleep 10; echo "10 s more, nothing read: $(t)"
probe tile0/gt1/uc/guc_log
probe tile0/gt1/uc/guc_log
systemctl start b70-telemetry-kick
echo "done; fan service restarted"
} 2>&1 | tee "$OUT"
chown "$U" "$OUT" 2>/dev/null
