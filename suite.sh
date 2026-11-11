#!/usr/bin/env bash
# Run the full comparison suite against one running server: ./suite.sh <tag> <port>
: "${VLLM_API_KEY:=$(cat ~/.config/vllm/api-key)}"; export VLLM_API_KEY
set -u
TAG=$1; PORT=${2:-8000}; U=http://localhost:$PORT/v1/chat/completions
mkdir -p results
{
  echo "=== $TAG ($(date -u +%FT%TZ))"
  python3 bench_decode.py --url $U --key "$VLLM_API_KEY" 2>&1 | tail -1
  python3 parbench.py --url $U -p 1 2 4 --tokens 256
  python3 evalset.py --url $U --tag "$TAG" -p 4
  python3 canary.py --url $U --mode on --key "$VLLM_API_KEY" | grep score
  python3 stream_tools.py --url $U --repeat 1 | tail -1
  python3 longctx.py --url $U --tokens 60000
} 2>&1 | tee results/$TAG.txt
