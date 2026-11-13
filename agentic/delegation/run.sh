#!/usr/bin/env bash
# ./run.sh <tag>   runs the six delegation jobs one after another against whatever serves the gateway's backend.
# Jobs: slice A, B, C (pi, from the scaffold commit), slice D (pi and OpenCode), bug fix B2 (pi).
set -u
TAG=$1; H=$HOME/bench/delegate; W=$H/$TAG; R=$HOME/llm-homelab-setup; mkdir -p $W; cd $H
job() {  # name agent commit promptfile
  local n=$1 a=$2 c=$3 p=$4 d=$W/$1
  rm -rf "$d"; git clone -q --no-hardlinks $R "$d" && git -C "$d" checkout -q -b delegate/$n $c || return 1
  local s=$(date -u +%FT%T) t0=$(date +%s)
  $R/agents/run-agent.sh $a "$d" "$(cat $p)" > $W/$n.log 2>&1; local rc=$?
  local e=$(date -u +%FT%T) secs=$(( $(date +%s)-t0 ))
  local chk; chk=$(podman run --rm --network none --userns keep-id -e HOME=/tmp/h -v "$d/mcp/homelab-mcp:/src:Z" -w /src localhost/llm-agents:2 \
     sh -c 'f=$(gofmt -l main.go internal/); [ -z "$f" ] && echo gofmt=ok || echo "gofmt=FAIL($f)"; go vet ./... >/dev/null 2>&1 && echo vet=ok || echo vet=FAIL; go test -race -count=1 ./... >/tmp/t 2>&1 && echo test=ok || { echo test=FAIL; grep -E "^(---|FAIL|ok)" /tmp/t | head -8; }' 2>&1 | tr '\n' ' ')
  local prot; prot=$(git -C "$d" status --short | grep -E '_test\.go|internal/status|vendor/|go\.(mod|sum)' | wc -l)
  echo "$n agent=$a rc=$rc secs=$secs start=$s end=$e protected_changed=$prot $chk files=[$(git -C "$d" status --short | tr '\n' ';')]" | tee -a $W/summary.txt
}
job A pi 260313e A.prompt
job B pi 260313e B.prompt
job C pi 260313e C.prompt
job D-pi pi eaefe2a D.prompt
job D-opencode opencode eaefe2a D.prompt
job B2 pi 608b60a B2.prompt
