#!/usr/bin/env bash
# OpenVINO Model Server with OpenVINO/Qwen3.8-27B-int4-ov on the B70, port 8001.
#   MTP=1 (default) uses the built-in MTP draft; PFX=true|false prefix caching; EXTRA = more flags
set -uo pipefail
NAME=${NAME:-ovms}; MTP=${MTP:-1}; PFX=${PFX:-true}; SEQS=${SEQS:-4}; EXTRA=${EXTRA:-}
TP=${TP:-qwen3coder}; RP=${RP:-qwen3}
draft=(); [ "$MTP" = 1 ] && draft=(--draft_model_path .)
podman rm -f "$NAME" >/dev/null 2>&1 || true
M=/models/OpenVINO/Qwen3.8-27B-int4-ov
podman run -d --name "$NAME" --user 0 --network host --device /dev/dri --group-add keep-groups \
  -v "$HOME/models/ov":/models:rw,Z --secret vllm_api_key,target=/run/secrets/key \
  docker.io/openvino/model_server:weekly \
  --rest_port 8001 --model_path $M --model_name qwen3.8-27b --api_key_file /run/secrets/key \
  --task text_generation --target_device GPU \
  --max_num_seqs "$SEQS" --enable_prefix_caching "$PFX" --tool_parser "$TP" --reasoning_parser "$RP" \
  "${draft[@]}" $EXTRA
for i in $(seq 1 120); do
  if curl -sf -H "Authorization: Bearer $(cat ~/.config/vllm/api-key)" localhost:8001/v3/models 2>/dev/null | grep -q qwen3.8-27b; then echo "ready after $((i*5))s"; exit 0; fi
  if ! podman ps --format '{{.Names}}' | grep -qx "$NAME"; then echo "container exited"; podman logs --tail 25 "$NAME" 2>&1 | cut -c1-400; exit 1; fi
  sleep 5
done
echo "timeout"; podman logs --tail 25 "$NAME" 2>&1 | cut -c1-400; exit 1
