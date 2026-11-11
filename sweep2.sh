#!/usr/bin/env bash
# Alternative 4-bit builds and the DSpark speculator. Restores production at the end.
cd "$(dirname "$0")"
export MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3
A=$HOME/models/alt
podman stop qwen38 >/dev/null 2>&1
MODEL=$A/Qwen3.8-27B-W4A16-AWQ ./exp.sh w-philbert-awq
MODEL=$A/Qwen3.8-27B-GPTQ-W4A16 ./exp.sh w-pearsonkyle-gptq
MODEL=$A/Qwen3.8-27B-AWQ-INT4 MAXLEN=131072 ./exp.sh w-cyankiwi-awq
MODEL=$HOME/models/Qwen3.8-27B-GPTQ-Int4-MTP ./exp.sh w-sergiiob-gptq
S=$A/Qwen3.8-27B-speculator.dspark
MTP=0 SPECDIR=$S MAXLEN=131072 SPEC='{"model":"/spec","num_speculative_tokens":7,"method":"dspark"}' ./exp.sh dspark7
MTP=0 SPECDIR=$S MAXLEN=131072 SPEC='{"model":"/spec","num_speculative_tokens":4,"method":"dspark"}' ./exp.sh dspark4
podman start qwen38 >/dev/null
echo SWEEP2 DONE
