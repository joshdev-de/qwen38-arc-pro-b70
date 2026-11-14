#!/usr/bin/env bash
# devan-carlin AutoRound weights with the DFlash2 drafter (Lumnus b70-flash-next 1-card preset, on stock vLLM 0.33.0).
# Production settings otherwise: vision on (max_pixels ~1 MP), 4 seqs, batch 4096, util 0.93, fp8 KV.
# If a config does not start at 196k context, it retries at shorter contexts.
cd "$(dirname "$0")"
export UTIL=0.93 SEQS=4 BATCH=4096 LMO= EXTRA='--mm-processor-kwargs {"max_pixels":1003520}'
DV=$HOME/models/alt/Qwen3.8-27B-devan-AutoRound; D=$HOME/models/drafters
W16="-e VLLM_XPU_INC_WNA16_BACKEND=w4a16"; W8="-e VLLM_XPU_INC_WNA16_BACKEND=w4a8"
df() { echo '{"method":"dflash","model":"/spec","num_speculative_tokens":7,"draft_tensor_parallel_size":1,"draft_sample_method":"probabilistic","rejection_sample_method":"standard","attention_backend":"TRITON_ATTN"}'; }
fit() { local tag=$1; shift
  for ml in 196608 163840 131072 98304 65536; do
    env MAXLEN=$ml "$@" ./exp.sh "$tag-${ml}" && ! grep -q "START FAILED" results/tune/$tag-$ml.txt && return 0
  done; return 1; }
podman stop -t 60 qwen38 >/dev/null 2>&1
MAXLEN=196608 MODEL=$DV ENVS="$W16" MTP=3 QUICK=1 LONG=1 ./exp.sh dv-w4a16-mtp3
fit dv-w4a16-df8  MODEL=$DV ENVS="$W16" SPECDIR=$D/Qwen3.8-27B-DFlash2-w8a8 SPEC="$(df)" CHECKS=1
fit dv-w4a16-df16 MODEL=$DV ENVS="$W16" SPECDIR=$D/Qwen3.8-27B-DFlash2 SPEC="$(df)" QUICK=1 LONG=1
fit dv-w4a8-df8   MODEL=$DV ENVS="$W8"  SPECDIR=$D/Qwen3.8-27B-DFlash2-w8a8 SPEC="$(df)" QUICK=1 LONG=1
./start-qwen38.sh > /dev/null 2>&1
echo "SWEEP5 DONE $(date -u +%T) prod health $(curl -s -o /dev/null -w %{http_code} localhost:8000/health)"
