#!/usr/bin/env bash
# Workaround for IGCIT issue #1574 (Arc Pro B70: reported temperatures and fan
# speed freeze after a load ends, and the idle card draws ~42 W instead of ~8 W).
# No driver or firmware change; it only reads files. Remove once Intel ships a fix.
#
# What it does, every INTERVAL seconds while the GPU is idle:
#  - Keep-alive pulse: holds the xe debugfs forcewake file open for HOLD seconds.
#    This refreshes the package temperature and fan control and keeps the idle card
#    near 8 W. Measured here: without pulses the idle card settles at ~42 W.
#  - After a load, every REFRESH_EVERY pulses it also reads the GuC firmware logs
#    a few times. The 16 VRAM temperature sensors only refresh a few at a time while
#    the card is awake, and a 0.4 s log read refreshes most of them at once (a
#    forcewake hold needs 10-20 s for the same). No GPU work and no request to the
#    model server is involved.
#  - Once package and VRAM are at or below COOL_MC, the log reads stop; the
#    keep-alive pulses continue.
# Detection uses plain sysfs reads, which do not wake the card.
INTERVAL=${INTERVAL:-10}
HOLD=${HOLD:-0.5}
COOL_MC=${COOL_MC:-55000}       # package and VRAM temperature considered cooled (millidegrees C)
CALM_N=${CALM_N:-3}             # consecutive cool checks before the VRAM refreshes stop
REFRESH_EVERY=${REFRESH_EVERY:-3}   # pulses between VRAM refreshes during cooldown
REFRESH_READS=${REFRESH_READS:-4}   # log reads per refresh (2-3 were enough in tests)
STOP_WHEN_COOL=${STOP_WHEN_COOL:-0} # 1 = also stop the keep-alive pulses once cooled (card then idles at ~42 W here)
FAN_STUCK=${FAN_STUCK:-1500}        # with STOP_WHEN_COOL=1: fan rpm that restarts pulsing
POWER_STUCK_MW=${POWER_STUCK_MW:-25000}  # with STOP_WHEN_COOL=1: idle card power (mW) that restarts pulsing
STUCK_N=${STUCK_N:-3}

PCI=""
for d in /sys/bus/pci/devices/*; do
  [ "$(basename "$(readlink -f "$d/driver")")" = xe ] && [ -e "/sys/kernel/debug/dri/$(basename "$d")/forcewake_all" ] && PCI=$(basename "$d") && break
done
[ -n "$PCI" ] || { echo "no xe device with forcewake_all found"; exit 1; }
DBG=/sys/kernel/debug/dri/$PCI
FW=$DBG/forcewake_all
HW=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
RES=/sys/bus/pci/devices/$PCI/tile0/gt0/gtidle/idle_residency_ms
LOGS=()
for f in "$DBG/tile0/gt1/uc/guc_log" "$DBG/tile0/gt0/uc/guc_log"; do [ -r "$f" ] && LOGS+=("$f"); done
echo "watching $PCI (hwmon $HW, ${#LOGS[@]} GuC log files for VRAM refresh)"

vram_refresh() {
  if [ "${#LOGS[@]}" -gt 0 ]; then
    local i
    for i in $(seq 1 "$REFRESH_READS"); do timeout 10 cat "${LOGS[$(( i % ${#LOGS[@]} ))]}" >/dev/null 2>&1; done
  else
    ( exec 3< "$FW"; sleep 15 )      # fallback: a long forcewake hold
  fi
  sleep 1
  ( exec 3< "$FW"; sleep "$HOLD" )   # a log read leaves the card in its ~42 W state until the next pulse
}

armed=1; calm=0; n=0; fresh=0; stuck=0
while true; do
  # baseline taken here so the window covers only the sleep, not our own pulse and log reads
  last_res=$(cat "$RES"); last_t=$(date +%s%3N); last_e=$(cat "$HW/energy1_input")
  sleep "$INTERVAL"
  res=$(cat "$RES"); t=$(date +%s%3N); e=$(cat "$HW/energy1_input")
  idle_pct=$(( (res - last_res) * 100 / (t - last_t) ))
  power_mw=$(( (e - last_e) / (t - last_t) ))          # microjoules per millisecond = milliwatts
  if [ "$idle_pct" -lt 80 ]; then          # GPU did real work in this window
    [ "$armed" = 0 ] && echo "load seen, cooldown armed"
    armed=1; calm=0; fresh=0
    continue
  fi
  if [ "$armed" = 0 ] && [ "$STOP_WHEN_COOL" = 1 ]; then
    if [ "$(cat "$HW/fan1_input" 2>/dev/null || echo 0)" -ge "$FAN_STUCK" ] || [ "$power_mw" -ge "$POWER_STUCK_MW" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    [ "$stuck" -ge "$STUCK_N" ] && { armed=1; calm=0; fresh=0; stuck=0; echo "idle but fan $(cat "$HW/fan1_input") rpm / ${power_mw} mW, cooldown armed"; }
    continue
  fi
  ( exec 3< "$FW"; sleep "$HOLD"; cat "$HW/temp2_input" >/dev/null )   # keep-alive pulse
  [ "$armed" = 0 ] && continue             # cooled: pulses only
  n=$((n + 1))
  if [ $((n % REFRESH_EVERY)) -eq 0 ]; then vram_refresh; fresh=1; fi
  # The fan is not part of this test: while the card is above its fan-on temperature (about 40 C here) the
  # fan cycles between 0 and ~900 rpm on every pulse, and the pulses continue after cooldown anyway.
  if [ "$fresh" = 1 ] && [ "$(cat "$HW/temp3_input")" -le "$COOL_MC" ] && [ "$(cat "$HW/temp2_input")" -le "$COOL_MC" ]; then
    calm=$((calm + 1))
    [ "$calm" -ge "$CALM_N" ] && { armed=0; stuck=0; echo "card cooled (pkg $(cat "$HW/temp2_input"), vram $(cat "$HW/temp3_input")), VRAM refreshes stopped, keep-alive pulses continue"; }
  else
    calm=0
  fi
done
