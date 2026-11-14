#!/usr/bin/env bash
# sweep5 continued with lengths that fit: stock vLLM leaves 4.78 GiB KV with the W8A8 DFlash2 drafter (max ~83k at util 0.93,
# vision on); the bf16 drafter leaves ~1.7 GiB less, so it runs at 49k for speed only.
cd "$(dirname "$0")"
export UTIL=0.93 SEQS=4 BATCH=4096 LMO= EXTRA='--mm-processor-kwargs {"max_pixels":1003520}'
DV=$HOME/models/alt/Qwen3.8-27B-devan-AutoRound; D=$HOME/models/drafters
W16="-e VLLM_XPU_INC_WNA16_BACKEND=w4a16"; W8="-e VLLM_XPU_INC_WNA16_BACKEND=w4a8"
SP='{"method":"dflash","model":"/spec","num_speculative_tokens":7,"draft_tensor_parallel_size":1,"draft_sample_method":"probabilistic","rejection_sample_method":"standard","attention_backend":"TRITON_ATTN"}'
podman stop -t 60 qwen38 >/dev/null 2>&1
MAXLEN=81920 MODEL=$DV ENVS="$W16" SPECDIR=$D/Qwen3.8-27B-DFlash2-w8a8 SPEC="$SP" CHECKS=1 ./exp.sh dv-w4a16-df8-81920
MAXLEN=49152 MODEL=$DV ENVS="$W16" SPECDIR=$D/Qwen3.8-27B-DFlash2      SPEC="$SP" QUICK=1 ./exp.sh dv-w4a16-df16-49152
MAXLEN=81920 MODEL=$DV ENVS="$W8"  SPECDIR=$D/Qwen3.8-27B-DFlash2-w8a8 SPEC="$SP" QUICK=1 LONG=1 ./exp.sh dv-w4a8-df8-81920
./start-qwen38.sh > /dev/null 2>&1
echo "SWEEP6 DONE $(date -u +%T) prod health $(curl -s -o /dev/null -w %{http_code} localhost:8000/health)"
