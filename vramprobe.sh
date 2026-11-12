#!/usr/bin/env bash
# Run as root: sudo ./vramprobe.sh
# Finds out whether reading any xe debugfs file refreshes the frozen VRAM temperature (hwmon temp3).
# Read-only: it only cats info files. It never touches force_reset, force_reset_sync or wedged_mode.
# Stops the fan workaround service during the test (so nothing else refreshes telemetry) and restarts it.
set -u
PCI=0000:01:00.0; D=/sys/kernel/debug/dri/$PCI; H=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
U=${SUDO_USER:-fedora}; DIR=$(cd "$(dirname "$0")" && pwd); OUT=$DIR/results/vramprobe.txt
t() { echo "vram $(( $(cat $H/temp3_input)/1000 )) pkg $(( $(cat $H/temp2_input)/1000 )) fan $(cat $H/fan1_input)"; }
{
echo "=== vramprobe $(date -u +%FT%TZ)"
systemctl stop b70-telemetry-kick
echo "load for ~30 s ..."
runuser -u "$U" -- python3 "$DIR/parbench.py" -p 4 --tokens 600 | tail -1 | cut -c1-70
echo "end of load:        $(t)"
sleep 75
echo "75 s later (frozen): $(t)"
for f in info pcode_info dgfx_pkg_residencies dgfx_pcie_link_residencies \
         tile0/vram_mm tile0/sa_info tile0/ggtt gtt_mm stolen_mm \
         tile0/gt0/powergate_info tile0/gt1/powergate_info tile0/gt0/stats tile0/gt1/stats \
         tile0/gt0/hw_engines tile0/gt0/topology tile0/gt0/steering tile0/gt0/hwconfig \
         $(cd $D && find tile0/gt0/uc tile0/gt1/uc -type f 2>/dev/null | grep -viE "reset|dump|dmesg|force|selftest|wedge" ) ; do
  [ -f "$D/$f" ] || { echo "skip (missing) $f"; continue; }
  before=$(cat $H/temp3_input)
  timeout 10 cat "$D/$f" >/dev/null 2>&1; rc=$?
  sleep 2
  after=$(cat $H/temp3_input)
  mark=""; [ "$after" != "$before" ] && mark="   <== VRAM READING CHANGED"
  echo "read $f (rc $rc): $(t)$mark"
done
( exec 3< $D/forcewake_all; sleep 0.5 ); sleep 2
echo "forcewake_all hold: $(t)"
systemctl start b70-telemetry-kick
echo "done; fan service restarted"
} 2>&1 | tee "$OUT"
chown "$U" "$OUT" 2>/dev/null
