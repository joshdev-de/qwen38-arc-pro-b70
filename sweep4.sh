#!/usr/bin/env bash
# AutoRound + oneDNN w4a16 backend: full suite, MTP4, and failure diagnosis for the default backend.
cd "$(dirname "$0")"
export MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3
AR=$HOME/models/alt/Qwen3.8-27B-AutoRound
W="-e VLLM_XPU_INC_WNA16_BACKEND=w4a16"
podman stop qwen38 >/dev/null 2>&1
MODEL=$AR ENVS="$W" ./exp.sh ar-w4a16-full
MODEL=$AR ENVS="$W" QUICK=1 MTP=4 ./exp.sh ar-w4a16-mtp4
MODEL=$AR QUICK=1 ./exp.sh ar-auto
MODEL=$AR QUICK=1 MAXLEN=131072 ./exp.sh ar-auto-131k
podman start qwen38 >/dev/null
echo SWEEP4 DONE
