#!/usr/bin/env bash
# Diagnostic: does stock vLLM 0.33 DFlash2 accept any drafts on XPU? bf16 drafter (as published), 32k, with and
# without the TRITON_ATTN drafter backend. Speed test only.
cd "$(dirname "$0")"
export UTIL=0.93 SEQS=4 BATCH=4096 LMO= EXTRA='--mm-processor-kwargs {"max_pixels":1003520}' MAXLEN=32768
DV=$HOME/models/alt/Qwen3.8-27B-devan-AutoRound; D=$HOME/models/drafters/Qwen3.8-27B-DFlash2
W16="-e VLLM_XPU_INC_WNA16_BACKEND=w4a16"
podman stop -t 60 qwen38 >/dev/null 2>&1
for v in triton default; do
  if [ $v = triton ]; then SP='{"method":"dflash","model":"/spec","num_speculative_tokens":7,"attention_backend":"TRITON_ATTN"}'
  else SP='{"method":"dflash","model":"/spec","num_speculative_tokens":7}'; fi
  MODEL=$DV ENVS="$W16" SPECDIR=$D SPEC="$SP" NAME=exp ./run_vllm.sh > results/tune/dv-df16-$v-32k.start.log 2>&1 || { echo "$v START FAILED"; grep -m3 -E "Error" results/tune/dv-df16-$v-32k.start.log | cut -c1-300; continue; }
  python3 speedbench.py --tag "dv-df16-$v-32k" -r 1 | tail -1
  podman logs exp 2>&1 | grep "SpecDecoding metrics" | tail -1 | grep -oE "Mean acceptance length: [0-9.]+|Avg Draft acceptance rate: [0-9.%]+" | tr '\n' ' '; echo
  podman logs exp > results/tune/dv-df16-$v-32k.full.log 2>&1; podman rm -f exp >/dev/null
done
./start-qwen38.sh > /dev/null 2>&1
echo "SWEEP7 DONE $(date -u +%T) prod health $(curl -s -o /dev/null -w %{http_code} localhost:8000/health)"
