#!/usr/bin/env bash
# Launch Qwen3.8-27B (RedHat INT4) on SGLang XPU with settings matching production vLLM. Override via env:
#   NAME=sgl MAXLEN=196608 MEM=0.90 SEQS=4 CHUNK=4096 MTP=3 KVD=fp8_e4m3 ./run_sglang.sh
set -euo pipefail
NAME=${NAME:-sgl}
IMAGE=${IMAGE:-docker.io/lmsysorg/sglang:v0.5.23-xpu}
MODEL=${MODEL:-$HOME/models/Qwen3.8-27B-RedHat-INT4}
MAXLEN=${MAXLEN:-196608}
MEM=${MEM:-0.90}           # --mem-fraction-static
SEQS=${SEQS:-4}            # --max-running-requests
CHUNK=${CHUNK:-4096}       # --chunked-prefill-size
MTP=${MTP:-3}              # 0 disables speculative decoding
KVD=${KVD:-fp8_e4m3}       # --kv-cache-dtype
LMO=${LMO:-}               # vision stays on; --language-model-only is not supported for Qwen3.8 in 0.5.23
EXTRA=${EXTRA:-}
ENVS=${ENVS:-}

spec=""
[ "$MTP" -gt 0 ] && spec="--speculative-algorithm EAGLE --speculative-num-steps $MTP --speculative-eagle-topk 1 --speculative-num-draft-tokens $((MTP+1))"

podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" \
  --network host --device /dev/dri --group-add keep-groups --ipc host \
  -v /dev/dri/by-path:/dev/dri/by-path:ro \
  -v "$MODEL":/model:ro,Z $ENVS \
  --secret vllm_api_key,type=env,target=VLLM_API_KEY \
  -e ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE -e ZE_AFFINITY_MASK=0 \
  --entrypoint bash "$IMAGE" -c "exec python3 -m sglang.launch_server --model-path /model \
    --served-model-name qwen3.8-27b --host 0.0.0.0 --port 8000 --api-key \"\$VLLM_API_KEY\" \
    --device xpu --context-length $MAXLEN --mem-fraction-static $MEM \
    --max-running-requests $SEQS --chunked-prefill-size $CHUNK --kv-cache-dtype $KVD $LMO \
    --linear-attn-backend intel_xpu $spec \
    --tool-call-parser qwen3_coder --reasoning-parser qwen3 \
    --default-chat-template-kwargs '{\"reasoning_effort\":\"${EFFORT:-medium}\"}' $EXTRA"

echo "started $NAME; waiting for /health ..."
for i in $(seq 1 180); do
  if curl -sf localhost:8000/health >/dev/null 2>&1; then echo "ready after $((i*5))s"; exit 0; fi
  if ! podman ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "container exited"; podman logs "$NAME" 2>&1 | grep -E "Error|error:" | tail -8 | cut -c1-400; podman logs --tail 25 "$NAME" | cut -c1-400; exit 1
  fi
  sleep 5
done
echo "not healthy after 15 min"; exit 1
