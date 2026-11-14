#!/usr/bin/env bash
# One tuning experiment: ./exp.sh <tag>   (config via the run_vllm.sh env vars)
# Starts container "exp", runs the quick suite, writes results/tune/<tag>.txt
set -u
TAG=$1; cd "$(dirname "$0")"; mkdir -p results/tune
OUT=results/tune/$TAG.txt
{
  echo "=== $TAG  $(date -u +%T)  MTP=${MTP:-3} BATCH=${BATCH:-8192} SEQS=${SEQS:-1} KVD=${KVD:-fp8} SPEC=${SPEC:-} ENVS=${ENVS:-} EXTRA=${EXTRA:-} MODEL=$(basename "${MODEL:-RedHat-INT4}")"
  if ! NAME=exp ./run_vllm.sh > results/tune/$TAG.start.log 2>&1; then echo "START FAILED"; tail -5 results/tune/$TAG.start.log | cut -c1-300; podman rm -f exp >/dev/null 2>&1; exit 1; fi
  grep -E "KV cache size" results/tune/$TAG.start.log | grep -oE "KV cache size: [0-9,]+ tokens"
  python3 parbench.py -p 1 2 3 4 --tokens 48 >/dev/null 2>&1      # warm all batch sizes
  python3 speedbench.py --tag "$TAG"
  python3 mannbench.py --tag "$TAG"
  podman logs exp 2>&1 | grep -iE "inc|ark|wna16|w4a8" | grep -iE "backend|scheme|kernel" | sort | uniq -c | head -5 | cut -c1-250
  if [ -n "${QUICK:-}" ]; then
    python3 parbench.py -p 4 --tokens 256 | tail -1
    [ -n "${LONG:-}" ] && python3 longctx.py --tokens 60000
    podman logs exp 2>&1 | grep "SpecDecoding metrics" | tail -1 | grep -oE "Mean acceptance length: [0-9.]+|Per-position acceptance rate: [0-9., ]+" | tr '\n' ' '; echo
    podman rm -f exp >/dev/null 2>&1; exit 0
  fi
  python3 parbench.py -p 4 --tokens 256 | tail -1
  python3 longctx.py --tokens 60000
  python3 evalset.py --tag "tune-$TAG" -p 4
  python3 canary.py --mode on --key "$(cat ~/.config/vllm/api-key)" | grep score
  if [ -n "${CHECKS:-}" ]; then   # streamed tool calls and parallel correctness (burst of 4)
    python3 stream_tools.py --repeat 2 | tail -1
    python3 concurrency.py -n 24 -p 4 | tail -2
  fi
  podman logs exp 2>&1 | grep "SpecDecoding metrics" | tail -1 | grep -oE "Mean acceptance length: [0-9.]+|Per-position acceptance rate: [0-9., ]+" | tr '\n' ' '; echo
} 2>&1 | tee $OUT
podman rm -f exp >/dev/null 2>&1
