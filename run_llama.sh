#!/usr/bin/env bash
# Launch Qwen3.8-27B GGUF on llama.cpp SYCL. Override via env:
#   GGUF=~/models/unsloth/Qwen3.8-27B-UD-Q4_K_XL.gguf CTX=196608 NP=4 MTP=3 KV=q8_0 ./run_llama.sh
set -euo pipefail
NAME=${NAME:-llama-test}
IMAGE=${IMAGE:-ghcr.io/ggml-org/llama.cpp:server-intel}
GGUF=${GGUF:-$HOME/models/Qwen3.8-27B-Q4_K_M.gguf}
PORT=${PORT:-8001}
CTX=${CTX:-196608}
NP=${NP:-4}
MTP=${MTP:-3}
KV=${KV:-q8_0}
UB=${UB:-512}
RESTART=${RESTART:-no}
EXTRA=${EXTRA:-}

spec=()
[ "$MTP" -gt 0 ] && spec=(--spec-type draft-mtp --spec-draft-n-max "$MTP")

podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" --restart "$RESTART" \
  --network host --device /dev/dri --group-add keep-groups \
  -v /dev/dri/by-path:/dev/dri/by-path:ro \
  -v "$GGUF":/model.gguf:ro,Z \
  --secret vllm_api_key \
  "$IMAGE" \
  -m /model.gguf --alias qwen3.8-27b --host 0.0.0.0 --port "$PORT" \
  --api-key-file /run/secrets/vllm_api_key \
  -ngl 999 -fa on -c "$CTX" -np "$NP" -kvu -ctk "$KV" -ctv "$KV" -ub "$UB" \
  --jinja --reasoning-format deepseek \
  --chat-template-kwargs '{"reasoning_effort":"medium"}' \
  --metrics "${spec[@]}" $EXTRA

echo "started $NAME; waiting for /health ..."
for i in $(seq 1 120); do
  if curl -sf localhost:$PORT/health >/dev/null 2>&1; then echo "ready after $((i*5))s"; break; fi
  if ! podman ps --format '{{.Names}}' | grep -qx "$NAME"; then echo "container exited"; podman logs --tail 40 "$NAME"; exit 1; fi
  sleep 5
done
podman logs "$NAME" 2>&1 | grep -iE "KV buffer size|model buffer size|compute buffer|draft|mtp|n_ctx_seq|error" | head -20 || true
