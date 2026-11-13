#!/usr/bin/env bash
# ./check.sh <tag> <M|H>: own tests and hidden tests in a clean, network-less sandbox copy
T=$1; N=$2; d=$HOME/bench/plan/$T/$N; tmp=$(mktemp -d); cp -a $d/. $tmp/
h=$([ $N = M ] && echo test_logstat_hidden.py || echo test_jobq_hidden.py)
podman run --rm --network none --userns keep-id -e HOME=/tmp/h -v "$tmp:/work:Z" -v $HOME/bench/plan/hidden/$h:/hidden/$h:ro,z -w /work localhost/llm-agents:2 sh -c "
  echo '-- own tests'; timeout 600 python3 -m pytest -q -p no:cacheprovider 2>&1 | tail -3
  echo '-- hidden tests'; timeout 900 python3 -m pytest -q -p no:cacheprovider -o addopts= --rootdir=/work /hidden/$h 2>&1 | grep -E '^(FAILED|ERROR)|passed|failed|error' | cut -c1-200 | tail -30"
rm -rf $tmp
