#!/usr/bin/env bash
# Tuning sweep on RedHat INT4 weights. Restores production at the end.
cd "$(dirname "$0")"
export MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3
podman stop qwen38 >/dev/null 2>&1
./exp.sh base
MTP=2 ./exp.sh mtp2
MTP=4 ./exp.sh mtp4
MTP=5 ./exp.sh mtp5
BATCH=8192 ./exp.sh batch8k
BATCH=16384 ./exp.sh batch16k
KVD=auto MAXLEN=98304 ./exp.sh kv-f16
SEQS=1 ./exp.sh seqs1
ENVS="-e VLLM_XPU_PP_MICROBATCH=0" ./exp.sh no-microbatch
ENVS="-e VLLM_XPU_USE_SAMPLER_KERNEL=0" ./exp.sh no-sampler-kernel
podman start qwen38 >/dev/null
echo SWEEP1 DONE
