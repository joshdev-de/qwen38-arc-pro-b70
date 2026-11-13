#!/usr/bin/env bash
# Launch Qwen3.8-27B (RedHat INT4) on vLLM XPU. Override any knob via env:
#   NAME=qwen38-test MAXLEN=196608 UTIL=0.93 SEQS=2 BATCH=4096 MTP=3 ./run_vllm.sh
set -euo pipefail
NAME=${NAME:-qwen38-test}
IMAGE=${IMAGE:-docker.io/vllm/vllm-openai-xpu:v0.33.0}
MODEL=${MODEL:-$HOME/models/Qwen3.8-27B-RedHat-INT4}
MAXLEN=${MAXLEN:-131072}
UTIL=${UTIL:-0.88}
SEQS=${SEQS:-1}
BATCH=${BATCH:-8192}
MTP=${MTP:-3}
RESTART=${RESTART:-no}
EXTRA=${EXTRA:-}
KVD=${KVD:-fp8}            # --kv-cache-dtype
SPEC=${SPEC:-}             # full --speculative-config JSON (overrides MTP)
SPECDIR=${SPECDIR:-}       # host dir of an external draft model, mounted at /spec
ENVS=${ENVS:-}             # extra container env, e.g. "-e VLLM_XPU_PP_MICROBATCH=0"
CACHEDIR=${CACHEDIR-$HOME/.cache/vllm-xpu}   # persistent compile caches; set CACHEDIR= to disable
LMO=${LMO---language-model-only}   # set LMO= (empty) to enable vision input

spec=()
[ "$MTP" -gt 0 ] && spec=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$MTP}")
[ -n "$SPEC" ] && spec=(--speculative-config "$SPEC")
specvol=()
if [ -n "$CACHEDIR" ]; then
  mkdir -p "$CACHEDIR/vllm" "$CACHEDIR/neo_compiler_cache"
  specvol+=(-v "$CACHEDIR/vllm":/root/.cache/vllm:Z -v "$CACHEDIR/neo_compiler_cache":/root/.cache/neo_compiler_cache:Z)
fi
[ -n "$SPECDIR" ] && specvol+=(-v "$SPECDIR":/spec:ro,Z)

podman rm -f "$NAME" >/dev/null 2>&1 || true
podman run -d --name "$NAME" --restart "$RESTART" \
  --network host --device /dev/dri --group-add keep-groups \
  -v /dev/dri/by-path:/dev/dri/by-path:ro \
  -v "$MODEL":/model:ro,Z "${specvol[@]}" $ENVS \
  --secret vllm_api_key,type=env,target=VLLM_API_KEY \
  -e ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE -e ZE_AFFINITY_MASK=0 \
  -e PYTORCH_ALLOC_CONF=expandable_segments:True \
  "$IMAGE" \
  /model --served-model-name qwen3.8-27b --port 8000 \
  --dtype float16 \
  --max-model-len "$MAXLEN" --gpu-memory-utilization "$UTIL" --kv-cache-dtype "$KVD" \
  --max-num-seqs "$SEQS" --max-num-batched-tokens "$BATCH" $LMO \
  "${spec[@]}" \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"reasoning_effort":"'"${EFFORT:-medium}"'"}' $EXTRA

echo "started $NAME; waiting for /health ..."
for i in $(seq 1 120); do
  if curl -sf localhost:8000/health >/dev/null 2>&1; then echo "ready after $((i*5))s"; break; fi
  if ! podman ps --format '{{.Names}}' | grep -qx "$NAME"; then echo "container exited"; podman logs "$NAME" 2>&1 | grep -m1 -A30 Traceback | cut -c1-400; podman logs --tail 40 "$NAME"; exit 1; fi
  sleep 5
done
podman logs "$NAME" 2>&1 | grep -E "KV cache size|Maximum concurrency|Model loading took" || true
