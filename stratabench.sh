#!/usr/bin/env bash
# Test set against a Strata / XeStrata server: ./stratabench.sh <tag> [port]
# Same scripts as the vLLM runs; the server ignores the model name and key.
set -u
TAG=$1; PORT=${2:-8095}; cd "$(dirname "$0")"; mkdir -p results/strata
U=http://localhost:$PORT/v1/chat/completions; KEY=${KEY:-none}; export VLLM_API_KEY=$KEY; A="--key $KEY --model strata"
{
  echo "=== $TAG  $(date -u +%F\ %T)  port $PORT"
  python3 speedbench.py --port $PORT $A --tag "$TAG"
  python3 mannbench.py --port $PORT $A --tag "$TAG"
  python3 parbench.py --url $U $A -p 1 4 --tokens 768
  python3 longctx.py --url $U $A --tokens 60000 --seed $RANDOM
  python3 canary.py --url $U $A --mode both | grep -i score
  python3 stream_tools.py --url $U $A
  python3 pfxtest.py --port $PORT --model strata
  python3 evalset.py --url $U $A --tag "strata-$TAG" -p ${EVALP:-1} -n 80
  python3 evalset.py --url $U $A --tag "strata-hard-$TAG" -p ${EVALP:-1} -n 120 --hard --mode on
} 2>&1 | tee results/strata/$TAG.txt
