#!/usr/bin/env bash
# Workaround for IGCIT issue #1574 (Arc Pro B70: reported temperatures and fan
# speed freeze after a load ends, and the idle card draws ~42 W instead of ~8 W).
# No driver or firmware change; it only reads files. Remove once Intel ships a fix.
#
# What it does, every INTERVAL seconds while the GPU is idle:
#  - Keep-alive pulse: holds the xe debugfs forcewake file open for HOLD seconds.
#    This refreshes the package temperature and fan control and drops the card into
#    its low-power idle state. Measured here: a warm card left without pulses stays
#    in a ~42 W state with the fan running.
#  - After a load, every REFRESH_EVERY pulses it also reads the GuC firmware logs
#    a few times. The 16 VRAM temperature sensors only refresh a few at a time while
#    the card is awake, and a 0.4 s log read refreshes most of them at once (a
#    forcewake hold needs 10-20 s for the same). No GPU work and no request to the
#    model server is involved.
#  - Once package and VRAM are at or below COOL_MC, the log reads stop; the
#    keep-alive pulses continue.
#  - Once the package is at or below REST_MC (below the card's fan-on temperature,
#    about 40 C here), the pulses stop too: a cool card stays in the low state by
#    itself (measured: 6.5 W without pulses against 10 W with them). One pulse every
#    REST_EVERY intervals keeps the temperature reading fresh. If the card is seen
#    in its ~42 W state while resting, the pulses start again.
# Detection uses plain sysfs reads, which do not wake the card.
INTERVAL=${INTERVAL:-10}
HOLD=${HOLD:-0.5}
COOL_MC=${COOL_MC:-55000}       # package and VRAM temperature considered cooled (millidegrees C)
REST_MC=${REST_MC:-0}           # experimental: package temperature at which the pulses stop (0 = never; 38000 flapped here)
CALM_N=${CALM_N:-3}             # consecutive checks before a state change
REFRESH_EVERY=${REFRESH_EVERY:-3}   # pulses between VRAM refreshes during cooldown
REFRESH_READS=${REFRESH_READS:-4}   # log reads per refresh (2-3 were enough in tests)
REST_EVERY=${REST_EVERY:-30}        # while resting: one pulse every this many intervals
POWER_STUCK_MW=${POWER_STUCK_MW:-25000}  # while resting: idle card power (mW) that restarts the pulses
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

# state: cooldown (pulses + VRAM refreshes) -> cooled (pulses) -> rest (no pulses)
state=cooldown; calm=0; n=0; fresh=0; stuck=0; r=0
pulse() { ( exec 3< "$FW"; sleep "$HOLD"; cat "$HW/temp2_input" >/dev/null ); }
while true; do
  # baseline taken here so the window covers only the sleep, not our own pulse and log reads
  last_res=$(cat "$RES"); last_t=$(date +%s%3N); last_e=$(cat "$HW/energy1_input")
  sleep "$INTERVAL"
  res=$(cat "$RES"); t=$(date +%s%3N); e=$(cat "$HW/energy1_input")
  idle_pct=$(( (res - last_res) * 100 / (t - last_t) ))
  power_mw=$(( (e - last_e) / (t - last_t) ))          # microjoules per millisecond = milliwatts
  # GPU did real work in this window. (An untouched resting card freezes both counters, which also
  # reads as "not idle", so there the energy counter must have moved as well.)
  if [ "$idle_pct" -lt 80 ] && { [ "$state" != rest ] || [ "$power_mw" -ge "$POWER_STUCK_MW" ]; }; then
    [ "$state" != cooldown ] && echo "load seen, cooldown armed"
    state=cooldown; calm=0; fresh=0; stuck=0
    continue
  fi
  if [ "$state" = rest ]; then
    if [ "$power_mw" -ge "$POWER_STUCK_MW" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    if [ "$stuck" -ge "$STUCK_N" ]; then
      state=cooled; calm=0; stuck=0; echo "resting card at ${power_mw} mW, pulses restarted"
    else
      r=$((r + 1)); [ $((r % REST_EVERY)) -eq 0 ] && pulse
    fi
    continue
  fi
  pulse
  if [ "$state" = cooled ]; then
    if [ "$REST_MC" -gt 0 ] && [ "$(cat "$HW/temp2_input")" -le "$REST_MC" ]; then calm=$((calm + 1)); else calm=0; fi
    [ "$calm" -ge "$CALM_N" ] && { state=rest; stuck=0; r=0; echo "card at rest (pkg $(cat "$HW/temp2_input")), pulses stopped"; }
    continue
  fi
  n=$((n + 1))
  if [ $((n % REFRESH_EVERY)) -eq 0 ]; then vram_refresh; fresh=1; fi
  # The fan is not part of this test: while the card is above its fan-on temperature (about 40 C here) the
  # fan cycles between 0 and ~900 rpm on every pulse.
  if [ "$fresh" = 1 ] && [ "$(cat "$HW/temp3_input")" -le "$COOL_MC" ] && [ "$(cat "$HW/temp2_input")" -le "$COOL_MC" ]; then
    calm=$((calm + 1))
    [ "$calm" -ge "$CALM_N" ] && { state=cooled; calm=0; echo "card cooled (pkg $(cat "$HW/temp2_input"), vram $(cat "$HW/temp3_input")), VRAM refreshes stopped, keep-alive pulses continue"; }
  else
    calm=0
  fi
done
