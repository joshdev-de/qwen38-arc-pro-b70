#!/usr/bin/env bash
# AutoRound build (INC path) + Mann-style 512-in/128-out benchmark. Restores production at the end.
cd "$(dirname "$0")"
export MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3
AR=$HOME/models/alt/Qwen3.8-27B-AutoRound
python3 mannbench.py --tag prod-mtp3 | tee results/tune/mann-prod-mtp3.txt   # production, before stopping it
podman stop qwen38 >/dev/null 2>&1
MODEL=$AR ./exp.sh ar-auto
MODEL=$AR QUICK=1 ENVS="-e VLLM_XPU_INC_WNA16_BACKEND=ark" ./exp.sh ar-ark
MODEL=$AR QUICK=1 ENVS="-e VLLM_XPU_INC_WNA16_BACKEND=w4a16" ./exp.sh ar-w4a16
MODEL=$AR QUICK=1 ENVS="-e VLLM_XPU_INC_WNA16_BACKEND=w4a8" ./exp.sh ar-w4a8
MODEL=$AR QUICK=1 MTP=4 ./exp.sh ar-mtp4
QUICK=1 MTP=4 ./exp.sh mann-redhat-mtp4
QUICK=1 MTP=4 MODEL=$HOME/models/Qwen3.8-27B-GPTQ-Int4-MTP ./exp.sh mann-sergiiob-mtp4
# Mann's own server settings: 131k, util 0.88, batch 8192, 1 seq, no prefix caching
QUICK=1 MTP=4 MODEL=$HOME/models/Qwen3.8-27B-GPTQ-Int4-MTP MAXLEN=131072 UTIL=0.88 BATCH=8192 SEQS=1 EXTRA="--no-enable-prefix-caching" ./exp.sh mann-exact
podman start qwen38 >/dev/null
echo SWEEP3 DONE
