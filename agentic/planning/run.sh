#!/usr/bin/env bash
# ./run.sh <tag>   runs the two planning tasks (M = medium, H = hard) with the pi agent, one after the other, 45 min cap each.
set -u
TAG=$1; H=$HOME/bench/plan; W=$H/$TAG; R=$HOME/llm-homelab-setup; mkdir -p $W; cd $H
for n in M H; do d=$W/$n; rm -rf "$d"; mkdir -p "$d"; git -C "$d" init -q
  s=$(date -u +%FT%T); t0=$(date +%s)
  timeout 2700 $R/agents/run-agent.sh pi "$d" "$(cat $n.prompt)" > $W/$n.log 2>&1; rc=$?
  echo "$n agent=pi rc=$rc secs=$(( $(date +%s)-t0 )) start=$s end=$(date -u +%FT%T)" | tee -a $W/summary.txt
  podman ps -q --filter ancestor=localhost/llm-agents:2 | xargs -r podman rm -f >/dev/null 2>&1
done
