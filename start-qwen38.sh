#!/usr/bin/env bash
# Production Qwen3.8-27B server (vLLM XPU, vision on). Safe to run any time.
#   ./start-qwen38.sh            start the existing container if it is stopped (keeps the 258k-token warm cache)
#   ./start-qwen38.sh --recreate remove and rebuild the container from scratch with the production settings
cd "$(dirname "$0")"
if [ "${1:-}" != "--recreate" ] && podman container exists qwen38; then
  podman start qwen38 >/dev/null && echo "started existing container qwen38; waiting for /health ..."
  for i in $(seq 1 120); do
    curl -sf localhost:8000/health >/dev/null 2>&1 && { echo "ready after $((i*5))s"; exit 0; }
    podman ps --format '{{.Names}}' | grep -qx qwen38 || { echo "container exited - try: $0 --recreate"; podman logs --tail 20 qwen38; exit 1; }
    sleep 5
  done
  echo "not healthy after 10 min - check: podman logs --tail 50 qwen38"; exit 1
fi
# max_pixels ~1 MP: larger images are downscaled; raises the context cache from 199k to 228k tokens. Remove EXTRA for full-size images.
NAME=qwen38 RESTART=unless-stopped MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3 LMO= EXTRA='--mm-processor-kwargs {"max_pixels":1003520}' exec ./run_vllm.sh
