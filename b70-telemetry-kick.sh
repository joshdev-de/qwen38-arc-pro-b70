#!/usr/bin/env bash
# Workaround for IGCIT issue #1574 (Arc Pro B70: package temperature and fan
# speed freeze after a load ends, fan stays fast, card idles at ~40 W).
# After GPU activity, briefly holds the xe debugfs forcewake file open every
# INTERVAL seconds so telemetry refreshes and the firmware fan curve sees real
# values. Once the card has cooled (pkg <= COOL_MC and fan < FAN_CALM for
# CALM_N checks) it stops pulsing, so deep idle is left undisturbed until the
# next load. Plain sysfs reads used for detection do not wake the card.
# No driver or firmware change. Remove once Intel ships a fix.
INTERVAL=${INTERVAL:-10}
HOLD=${HOLD:-0.5}
COOL_MC=${COOL_MC:-55000}     # package temperature considered cooled (millidegrees C)
FAN_CALM=${FAN_CALM:-200}     # rpm considered off (idle reads 0-140)
FAN_STUCK=${FAN_STUCK:-200}    # rpm that re-arms pulsing while idle
CALM_N=${CALM_N:-3}
STUCK_N=${STUCK_N:-3}           # consecutive high fan readings (INTERVAL apart) before re-arming
# VRAM temperatures only refresh on real GPU work, not on forcewake. If KICK_URL
# is set, send a one-token request every KICK_EVERY pulses while cooling down.
# Pulsing stops only when package AND VRAM (temp3) are both <= COOL_MC. If the
# server is down the VRAM reading cannot be refreshed, so it is then ignored.
KICK_URL=${KICK_URL:-http://127.0.0.1:8000/v1/completions}
KICK_MODEL=${KICK_MODEL:-qwen3.8-27b}
KICK_KEYFILE=${KICK_KEYFILE:-/home/fedora/.config/vllm/api-key}
KICK_EVERY=${KICK_EVERY:-6}
kick() {
  [ -n "$KICK_URL" ] || return 0
  curl -sf -m 10 -o /dev/null "$KICK_URL" -H "Authorization: Bearer $(cat "$KICK_KEYFILE" 2>/dev/null)" \
    -H 'Content-Type: application/json' -d "{\"model\":\"$KICK_MODEL\",\"prompt\":\"Hi\",\"max_tokens\":1}"
}

PCI=""
for d in /sys/bus/pci/devices/*; do
  [ "$(basename "$(readlink -f "$d/driver")")" = xe ] && [ -e "/sys/kernel/debug/dri/$(basename "$d")/forcewake_all" ] && PCI=$(basename "$d") && break
done
[ -n "$PCI" ] || { echo "no xe device with forcewake_all found"; exit 1; }
FW=/sys/kernel/debug/dri/$PCI/forcewake_all
HW=$(echo /sys/bus/pci/devices/$PCI/hwmon/hwmon*)
RES=/sys/bus/pci/devices/$PCI/tile0/gt0/gtidle/idle_residency_ms
echo "watching $PCI (hwmon $HW)"

armed=1; calm=0; n=0; vram_known=1; stuck=0
last_res=$(cat "$RES"); last_t=$(date +%s%3N)
while true; do
  sleep "$INTERVAL"
  res=$(cat "$RES"); t=$(date +%s%3N)
  idle_pct=$(( (res - last_res) * 100 / (t - last_t) ))
  last_res=$res; last_t=$t
  if [ "$idle_pct" -lt 80 ]; then          # GPU did real work in this window
    [ "$armed" = 0 ] && echo "load seen, pulsing armed"
    armed=1; calm=0
    continue
  fi
  if [ "$armed" = 0 ]; then
    # single fan readings can blip to 300-1200 rpm while the fan is off; re-arm only on STUCK_N readings in a row
    if [ "$(cat "$HW/fan1_input" 2>/dev/null || echo 0)" -ge "$FAN_STUCK" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    [ "$stuck" -ge "$STUCK_N" ] && { armed=1; calm=0; stuck=0; echo "fan high while idle, pulsing armed"; }
    continue
  fi
  ( exec 3< "$FW"; sleep "$HOLD"; cat "$HW/temp2_input" >/dev/null )
  n=$((n + 1))
  if [ $((n % KICK_EVERY)) -eq 0 ]; then
    if kick; then vram_known=1; sleep 1; else vram_known=0; fi
  fi
  vram_ok=1
  [ "$vram_known" = 1 ] && [ "$(cat "$HW/temp3_input")" -gt "$COOL_MC" ] && vram_ok=0
  if [ "$vram_ok" = 1 ] && [ "$(cat "$HW/temp2_input")" -le "$COOL_MC" ] && [ "$(cat "$HW/fan1_input")" -lt "$FAN_CALM" ]; then
    calm=$((calm + 1))
    [ "$calm" -ge "$CALM_N" ] && { armed=0; echo "card cooled (pkg $(cat "$HW/temp2_input"), vram $(cat "$HW/temp3_input")), pulsing stopped"; }
  else
    calm=0
  fi
done
