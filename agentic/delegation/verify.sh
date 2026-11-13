#!/usr/bin/env bash
# ./verify.sh <tag>  checks every job's result in a clean container: protected files, gofmt, vet, go test -race.
# Slices A-C are checked on their own package only (the other packages are still stubs at that commit).
TAG=$1; W=$HOME/bench/delegate/$TAG
declare -A PKG=([A]=./internal/promtext/ [B]=./internal/hwmon/ [C]=./internal/server/ [D-pi]=./... [D-opencode]=./... [B2]=./...)
for n in A B C D-pi D-opencode B2; do d=$W/$n; [ -d $d ] || continue
  prot=$(git -C $d status --short | grep -cE '_test\.go|internal/status|vendor/|go\.(mod|sum)')
  chk=$(podman run --rm --network none --userns keep-id -e HOME=/tmp/h -v "$d/mcp/homelab-mcp:/src:Z" -w /src localhost/llm-agents:2 sh -c '
     ch=$(git status --short 2>/dev/null | wc -l); f=$(gofmt -l $(ls -d main.go internal 2>/dev/null) 2>&1 | tr "\n" " "); echo "gofmt_unformatted=[$f]"
     go vet '"${PKG[$n]}"' >/dev/null 2>&1 && echo vet=ok || echo vet=FAIL
     go test -race -count=1 '"${PKG[$n]}"' >/tmp/t 2>&1 && echo test=ok || { echo test=FAIL; grep -E "^(---|FAIL)" /tmp/t | head -5; }' 2>&1 | tr '\n' ' ')
  echo "$n protected_changed=$prot $chk changed=[$(git -C $d status --short | tr '\n' ';')] diff=$(git -C $d diff --shortstat | tr -d '\n')"
done
