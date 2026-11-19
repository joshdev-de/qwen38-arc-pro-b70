#!/usr/bin/env bash
# Production Qwen3.8-27B server (since 2026-11-19): riceharvest b70-vllm image (patched vLLM 0.32 XPU, MTP 4,
# fp8 KV, 262k context, vision on, up to 8 sequences) + darioooooo0o/Qwen3.8-27B-Uncensored-GPTQ-Int4-asym.
# Measured at 312 W: results/rh-unc-asym-b70vllm-20261119.txt. Rollback to stock vLLM: ./start-qwen38-vllm.sh
#   ./start-qwen38.sh            start the existing container if it is stopped
#   ./start-qwen38.sh --recreate remove and rebuild the container from scratch with the production settings
cd "$(dirname "$0")"
NAME=qwen38
# pinned by digest: the :latest tag as pulled on 2026-11-19 (built 2026-10-18)
IMAGE=ghcr.io/riceharvest/b70-vllm@sha256:1aafc546ec1dae7ae91a8e943d36edb16cbecdf049902d6d3ff035c54baccfe1
MODEL=$HOME/models/darioooooo0o/Qwen3.8-27B-Uncensored-GPTQ-Int4-asym
wait_ready() {
  for i in $(seq 1 240); do
    curl -sf localhost:8000/health >/dev/null 2>&1 && { echo "ready after $((i*5))s"; exit 0; }
    podman ps --format '{{.Names}}' | grep -qx $NAME || { echo "container exited - try: $0 --recreate"; podman logs --tail 20 $NAME; exit 1; }
    sleep 5
  done
  echo "not healthy after 20 min - check: podman logs --tail 50 $NAME"; exit 1
}
if [ "${1:-}" != "--recreate" ] && podman container exists $NAME; then
  podman start $NAME >/dev/null && echo "started existing container $NAME; waiting for /health ..."
  wait_ready
fi
podman rm -f $NAME >/dev/null 2>&1 || true
# The image's entrypoint (b70-serve.sh) sets the vLLM arguments; MODEL/SERVED_NAME select the weights and API name.
# Embeddings and the vision tower are kept in host RAM (needs ~12 GB free). VLLM_API_KEY comes from the podman secret.
podman run -d --name $NAME --restart unless-stopped --network host \
  --device /dev/dri -v /dev/dri:/dev/dri:ro --group-add keep-groups --shm-size 8g \
  -v "$MODEL":/model:ro,Z -e MODEL=/model -e SERVED_NAME=qwen3.8-27b \
  --secret vllm_api_key,type=env,target=VLLM_API_KEY \
  "$IMAGE" >/dev/null
echo "started $NAME; waiting for /health (about 4 min) ..."
wait_ready
