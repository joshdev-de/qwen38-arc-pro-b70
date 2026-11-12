# Qwen3.8-27B on a single Intel Arc Pro B70

A measured comparison of inference engines, 4-bit builds and server settings for running
Qwen3.8-27B on one Intel Arc Pro B70 (32 GB), aimed at agent use (Hermes Agent, agentic coding)
with a few occasional extra users. Everything here was measured in one Proxmox virtual machine on
10–12 November 2026; the scripts to repeat it are in this repository.

**Short version:** upstream vLLM (XPU image v0.33.0) with `RedHatAI/Qwen3.8-27B-INT4` and
3-token MTP speculative decoding gives about 67 tokens/s for one client, about 165–175 tokens/s
across four clients, a 196k-token context, working prefix caching and clean streamed tool calls.
No other engine tested matched that combination.

**The target use case is several agents running in parallel** on one card, so throughput under
concurrency counts for more here than single-client speed. That is why vLLM stays the
recommendation even though the 125B Qwen3.8-Flash-Next on Strata or XeStrata, tested on
12 November, is faster for a single client: with four clients vLLM delivers about twice their
throughput and no queueing.

## Key findings

- **Engine:** vLLM is the best all-rounder and the best fit for parallel agents, the use case
  aimed for here. llama.cpp (SYCL) matches it for one client but has
  about two-thirds of the four-client throughput. OpenVINO Model Server is slightly faster for one
  stream but cannot combine MTP with prefix caching, which agents need.
- **Weights:** every 19 GB 4-bit build runs at the same speed within 2%, with no measurable
  accuracy difference. An AutoRound build is about 4% faster but needs a non-default backend.
- **MTP depth:** 3 tokens is the best general setting. 4 tokens is faster on predictable output
  and slower on prose and under concurrency. Published figures of 84 tokens/s are a best case.
- **Tuning:** batch size, cache precision, slot count and the Intel backend switches made no
  measurable difference.
- **Thinking:** keep it on. With thinking off the model fails most multi-step questions.
- **Bigger model, other engine:** the 125B Qwen3.8-Flash-Next on Strata or XeStrata decodes up
  to 18% faster for one client, reads long prompts twice as fast and is as accurate, but
  manages half the throughput with four clients. Upstream Strata now matches the XeStrata fork
  on speed; the fork is easier to set up on a B70.
- **Vision:** costs context cache; limiting images to about 1 megapixel recovers roughly half of it.
- **Power:** a 180 W cap costs 2% of decode speed and saves about a quarter of the power.
- **Fan bug:** the B70's stuck-fan problem can be worked around without touching driver or firmware.

## Terms used here

| Term | Meaning |
|---|---|
| Decode | Generating the answer, measured in tokens per second |
| Prefill | Reading the prompt before the first answer token |
| Cold prompt | A prompt the server has not seen, so nothing is cached |
| Prefix cache | Reuse of an already-read prompt prefix, so only the new part is read |
| Context cache | Memory holding the processed prompt (the KV cache); its size limits context and concurrency |
| Mixture of experts | A model built from many small sub-networks (experts), of which only a few run per token |
| Drafter | A small helper that guesses the next tokens so the main model can check several at once; MTP and DFlash2 are two kinds |
| MTP | Multi-token prediction: the model guesses several tokens ahead and keeps the correct ones |
| Canary | A 12-question sanity check run after every change |

## Contents

- [Key findings](#key-findings)
- [Terms used here](#terms-used-here)
- [Recommended setup](#recommended-setup)
- [Test system](#test-system)
- [Quick start](#quick-start)
- [Server settings explained](#server-settings-explained)
- [Results](#results)
  - [Engines](#engines)
  - [4-bit builds on vLLM](#4-bit-builds-on-vllm)
  - [GGUF quants on llama.cpp](#gguf-quants-on-llamacpp)
  - [vLLM tuning parameters](#vllm-tuning-parameters)
  - [MTP depth and the "84 tokens/s" figure](#mtp-depth-and-the-84-tokenss-figure)
  - [OpenVINO Model Server in detail](#openvino-model-server-in-detail)
  - [Context size](#context-size)
  - [Vision input](#vision-input)
  - [Reasoning effort](#reasoning-effort)
  - [Another model: Qwen3.6-35B-A3B](#another-model-qwen36-35b-a3b)
  - [Another model: Qwen3.8-Flash-Next on Strata and XeStrata](#another-model-qwen38-flash-next-on-strata-and-xestrata)
  - [Power cap](#power-cap)
- [B70 stuck fan and temperature workaround](#b70-stuck-fan-and-temperature-workaround)
- [Scripts](#scripts)
- [How the numbers were measured](#how-the-numbers-were-measured)
- [Known gaps](#known-gaps)
- [Sources](#sources)
- [Licence](#licence)

## Recommended setup

| Item | Value |
|---|---|
| Engine | `docker.io/vllm/vllm-openai-xpu:v0.33.0` (upstream vLLM, Intel XPU backend) |
| Weights | [`RedHatAI/Qwen3.8-27B-INT4`](https://huggingface.co/RedHatAI/Qwen3.8-27B-INT4) (W4A16, 19 GB) |
| Speculative decoding | Built-in MTP, 3 tokens |
| Context | 196,608 tokens per request, 4 concurrent requests |
| Context cache | fp8, 227,951 tokens with vision on and images limited to about 1 megapixel |
| Tool calls and reasoning | `qwen3_coder` tool parser, `qwen3` reasoning parser, default reasoning effort `medium` |
| Power cap | 180 W (driver default is 312 W) |

Headline numbers for this setup:

| Measurement | Default power (312 W) | With the 180 W cap |
|---|---|---|
| Decode, one client (mixed code / prose / JSON) | 68.2 tokens/s | 66.7 tokens/s |
| Decode, four clients, total | 166.5 tokens/s | 158.7 tokens/s |
| Cold 75k-token prompt | 63 s | 86 s |

| Measurement | Result |
|---|---|
| Cold 187k-token prompt | 268 s, 3 of 3 planted values retrieved |
| 16k-token prompt, cold and then cached | 8.6 s, then 1.1 s |
| Streamed tool calls | 16 of 16 clean, thinking on and off |
| Idle power with the model loaded | about 7 W in deep idle |

## Test system

| Component | Detail |
|---|---|
| GPU | One Intel Arc Pro B70, 32 GB (30.3 GiB usable) |
| Host | Proxmox VE; the server runs in a KVM virtual machine with the B70 passed through |
| CPU | 12 of the 24 cores of an AMD EPYC 7443P assigned to the VM |
| RAM | 128 GB assigned to the VM |
| OS | Fedora, kernel 7.3.3, `xe` driver |
| Containers | Rootless Podman |
| Client | Hermes Agent on another machine, plus Open WebUI |

## Quick start

Requirements: a Linux host with the `xe` driver and a working `/dev/dri` render node, Podman,
Python 3, and the Hugging Face CLI (`hf`). The commands assume rootless Podman.

1. Download the weights (about 19 GB):

   ```bash
   hf download RedHatAI/Qwen3.8-27B-INT4 --local-dir ~/models/Qwen3.8-27B-RedHat-INT4
   ```

2. Create an API key file and a Podman secret from it:

   ```bash
   mkdir -p ~/.config/vllm && (umask 077; openssl rand -hex 24 > ~/.config/vllm/api-key)
   podman secret create vllm_api_key ~/.config/vllm/api-key
   ```

3. Start the server:

   ```bash
   ./start-qwen38.sh --recreate
   ```

   The first start takes about three minutes (kernels are compiled and cached in
   `~/.cache/vllm-xpu`); later rebuilds take about 80–95 s.

4. Check it:

   ```bash
   python3 canary.py --mode on --key "$(cat ~/.config/vllm/api-key)"   # expect 12/12
   python3 stream_tools.py                                             # expect 16/16 clean
   ```

The server listens on port 8000 on all interfaces over plain HTTP. Put it behind a firewall or a
TLS proxy if the network is not trusted.

`./start-qwen38.sh` without arguments starts the existing container if it is stopped. The container
uses `--restart unless-stopped`, so it restarts after a crash. For it to come back after a reboot
under rootless Podman, enable `podman-restart.service` for the user and turn on lingering
(`loginctl enable-linger`).

## Server settings explained

`start-qwen38.sh` calls `run_vllm.sh`, which accepts every setting as an environment variable.

| Setting | Value | What it does | Tested? |
|---|---|---|---|
| `--max-model-len` | 196608 | Longest prompt plus answer per request | Yes; 229k and above does not fit with MTP |
| `--gpu-memory-utilization` | 0.93 | Share of card memory vLLM may use | Not swept above 0.93 |
| `--kv-cache-dtype` | fp8 | Context cache at 8-bit, half the memory | Yes; 16-bit gave the same speed |
| `--max-num-seqs` | 4 | Requests processed at once | Yes; no single-client cost |
| `--max-num-batched-tokens` | 4096 | Chunk size when reading prompts | Yes; 8192 no effect, 16384 failed to start |
| `--speculative-config` | MTP, 3 tokens | Guesses 3 tokens ahead per step | Yes; see [MTP depth](#mtp-depth-and-the-84-tokenss-figure) |
| `--mm-processor-kwargs` | `{"max_pixels":1003520}` | Downscales images above about 1 megapixel | Yes; see [Vision input](#vision-input) |
| `--tool-call-parser` | `qwen3_coder` | Turns the model's tool-call text into structured calls | Yes |
| `--reasoning-parser` | `qwen3` | Separates thinking from the answer | Yes |
| `--default-chat-template-kwargs` | `reasoning_effort: medium` | Thinking depth when the client does not set one | See [Reasoning effort](#reasoning-effort) |
| `ZE_FLAT_DEVICE_HIERARCHY`, `ZE_AFFINITY_MASK` | `COMPOSITE`, `0` | Select the card | No |
| Cache mount | `~/.cache/vllm-xpu` | Reuses compiled kernels across rebuilds | Yes; halves start time, does not change cache size |

Notes:

- Prefix caching is on by default in vLLM and needs no flag.
- XPU graph mode is on by default in v0.33.0. `VLLM_XPU_ENABLE_XPU_GRAPH` is not a recognised
  variable in this version and is ignored.
- `qwen3_coder` and `qwen3_xml` are two names for the same parser class in v0.33.0.
- `reasoning_effort` accepts only `low`, `medium` and `xhigh`.

## Results

Unless stated otherwise:

- Every server ran with a 196k context, 4 slots, MTP 3 and an 8-bit context cache.
- Speeds are in tokens per second.
- "Decode" is `speedbench.py`: temperature 0, thinking off, fixed code, prose and JSON prompts.
- "Accuracy" is the number of correct answers out of 80 generated questions.

See [How the numbers were measured](#how-the-numbers-were-measured) for the tests and their limits.

### Engines

| Engine | Decode, 1 client | 4 clients total | Cold 75k prompt | Prefix cache |
|---|---|---|---|---|
| **vLLM XPU v0.33.0** | 67.4 | 167–174 | 63 s | Works (81–86% hits in agent use) |
| Intel llm-scaler-vllm 0.26.0-b2 | 64.7 | 156 | 63–66 s | Off by default; 65% hits when enabled |
| llama.cpp SYCL (build b12242), Q4_K_M | 66.1 | 112 | 94 s | Not tested |
| OpenVINO Model Server 2026.5, int4-ov | 71.3 | 88 | 99 s | Not together with MTP |

All four passed the canary (12/12), streamed tool calls (8/8) and retrieval from a 75k-token prompt.

- **vLLM** is the only engine with full speed, concurrency and a working prefix cache together.
- **llm-scaler** is Intel's own vLLM build. It was slightly slower, took about five minutes to
  start, and stalled for 13–17 s on the first request at each new batch size after a restart.
- **llama.cpp** is the best fallback: same single-client speed, simpler to run, weaker with
  several clients and slower at reading long prompts.
- **OpenVINO Model Server** suits a single user who does not need caching; see
  [the details below](#openvino-model-server-in-detail).

Engines that were not tested because they wrap one of the above or lack a B70 backend: llama.cpp
with Vulkan (reported well below SYCL), Ollama and LM Studio (llama.cpp underneath), IPEX-LLM,
SGLang, MLC-LLM, and the OpenVINO backend for llama.cpp (a preview).

### 4-bit builds on vLLM

Same engine and settings, only the weights changed.

| Build | Decode | 4 clients total | Accuracy, thinking off / on (of 80) | Context cache, fresh start |
|---|---|---|---|---|
| **RedHatAI INT4** | 67.4 | 174 | 30 / 77 | 206,580 |
| HaberstrohSystems AutoRound + `VLLM_XPU_INC_WNA16_BACKEND=w4a16` | 69.8 | 175–177 | 28 / 80 | 213,704 |
| philbert440 W4A16-AWQ | 67.5 | 166 | 27 / 80 | 203,731 |
| pearsonkyle GPTQ-W4A16 | 67.2 | 155 | 28 / 76 | 206,580 |
| SergiioB GPTQ-Int4 (MTP in BF16) | 66.2–68.3 | 152–153 | 25–26 / 77–78 | 199,457 |
| cyankiwi AWQ-INT4 (group 32, 21 GB) | 62.6 | 151 | 29 / 78 | 154,043 |

- The 19 GB builds are within 2% of each other in speed, and the accuracy differences are within
  noise at 80 questions.
- The AutoRound build is about 4% faster, and 6% faster on a fully predictable prompt. It only
  starts with the `w4a16` backend variable: with the default backend the engine process dies
  silently right after loading weights. The `w4a8` backend also starts but is slower (65.0).
  Streamed tool calls, prefix caching and 187k retrieval were not tested on this build.
- GPTQ builds with unquantized MTP layers work on v0.33.0 without patches.
- The DSpark speculator (`RedHatAI/Qwen3.8-27B-speculator.dspark`, 4 GB) loads but leaves room for
  only about 48k tokens of context on one card. DFlash2 needs a vLLM change that was not merged
  at the time.

### GGUF quants on llama.cpp

Measured with an earlier benchmark (`bench_decode.py`), so compare these rows with each other,
not with the decode numbers above. vLLM scored 54 tokens/s on this benchmark.

| Quant | Decode | 4 clients each / total | Cold 75k prompt | Accuracy off / on (of 80) |
|---|---|---|---|---|
| Q4_K_M (16.2 GiB) | 53 | 32 / 112 | 94 s | 29 / 79 |
| unsloth UD-Q5_K_XL (19.4 GiB) | 45 | 29 / 101 | 98 s | 31 / 80 |
| unsloth UD-Q4_K_XL (16.4 GiB) | 35 | 25 / 89 | 110 s | 32 / 78 |

- Plain Q4_K, Q6_K and Q8_0 tensors are fastest on SYCL. UD-Q4_K_XL is slow because it mixes in
  IQ4_XS, Q5_K and Q3_K tensors.
- MTP works with `--spec-type draft-mtp --spec-draft-n-max 3`; the MTP layer is inside the main
  GGUF, with 92–94% acceptance.
- `q8_0` and `f16` context caches gave the same speed.

### vLLM tuning parameters

Baseline: 67.4 tokens/s, 174 at four clients, 63 s for a 75k prompt.

| Change | Effect |
|---|---|
| `--max-num-batched-tokens` 8192 | None |
| `--max-num-batched-tokens` 16384 | Failed to start at 196k (cause not captured) |
| Context cache f16 instead of fp8 | No speed change; half the capacity |
| 1 slot instead of 4 | No single-client change |
| `VLLM_XPU_PP_MICROBATCH=0` | None |
| `VLLM_XPU_USE_SAMPLER_KERNEL=0` | None |
| MTP 2 | 63.6 |
| MTP 4 | 70.1 single client, 140–147 at four clients, about 8k tokens less cache |
| MTP 5 | Failed to start at 196k (cause not captured) |

The settings in [Recommended setup](#recommended-setup) were already at the optimum for mixed use.

### MTP depth and the "84 tokens/s" figure

Published single-card results of 84–85 tokens/s use MTP 4 with a 512-token prompt, 128 generated
tokens and one prompt on which every guessed token is accepted. `mannbench.py` reproduces that
shape with three prompts.

| Setup | Predictable prompt | Code | Prose |
|---|---|---|---|
| Published result (Jonathan Mann) | 84.6 | – | – |
| RedHat INT4, MTP 4, settings from this repository | 88.4 | 65.4 | 46.0 |
| SergiioB GPTQ, MTP 4, the published server settings | 88.3 | 69.3 | 42.6 |
| RedHat INT4, MTP 3 | 81.1 | 64.7 | 49.1 |
| AutoRound + `w4a16`, MTP 4 | 94.3 | 76.3 | 53.4 |

The published figure reproduces, but it is a best case: the same server does 43–46 tokens/s on
prose, slower than MTP 3. MTP 4 also costs 16% of four-client throughput.

### OpenVINO Model Server in detail

OpenVINO Model Server (OVMS) is fast for one stream, but on this model prefix caching and MTP
do not work together, so it is a poor fit for agents.

Tested: `openvino/model_server:weekly` (2026.5.0) with `OpenVINO/Qwen3.8-27B-int4-ov` and its
built-in MTP draft; see `run_ovms.sh`. Under rootless Podman it needs `--user 0`. It loads in
about 30 s.

| | vLLM | OVMS with MTP | OVMS without MTP |
|---|---|---|---|
| Decode (code / prose / JSON) | 67.4 (66.8 / 57.9 / 77.5) | 71.3 (67.6 / 51.8 / 94.4) | 32.0 |
| 4 clients total | 174 | 88, up to 5 s to first token | 113 |
| Cold 75k / 187k prompt | 63 s / 268 s | 99 s / 457 s | – |
| Accuracy off / on (of 80) | 30 / 77 | 23 / 79 | – |

Prefix caching on OVMS (`pfxtest.py`):

| Setup | 16k-token prompt, cold then cached | 79k-token prompt, cold then cached |
|---|---|---|
| Default dynamic cache | No cache hits | No cache hits |
| `--cache_size 12`, MTP off | 11 s, then 1.0 s | 97–100 s, then 6–7 s |
| `--cache_size 12`, MTP on | 13 s, then 4 s | Did not finish in 9–15 minutes |

Prefix caching needs an explicit `--cache_size`, and it does not combine with MTP: the choice is
fast decoding or a working cache. The model card says the same. `--kv_cache_precision u8` made no
difference to speed.

### Context size

- With MTP 3 and utilization 0.93, 196,608 tokens fits; 229k and above does not.
- The model's native 262k context fits only without MTP, which costs about 35% of decode speed
  (31–34 tokens/s per client).
- A text-only server gets a 206,580-token cache on a fresh container and about 258k after a
  restart. With vision on it is the same either way.
- Retrieval of three planted values was correct at 75k and 187k tokens.

### Vision input

Removing `--language-model-only` enables image input. Text speed is unchanged (67.3 tokens/s),
but the context cache shrinks unless the image size is limited.

| Configuration | Context cache |
|---|---|
| Text only, fresh container / after restart | 206,580 / about 258,000 |
| Vision on, default image size | 199,457 |
| Vision on, images limited to about 1 megapixel | 227,951 |

The vision encoder is profiled at the largest allowed image, which reserves about 2 GiB.
`--mm-processor-kwargs {"max_pixels":1003520}` cuts that to 0.8 GiB. A 1600×1200 test image was
still answered correctly and cost about 1,000 prompt tokens. Fine text in large screenshots may
suffer; remove the flag for full-size images.

### Reasoning effort

Higher effort was more accurate for a modest token cost. Measured with `evalset.py`, 4 parallel
requests, temperature 0, on the recommended setup; cells show correct answers.

| Effort | Easy questions (240) | Chained questions (120) | Median tokens per question (easy / chained) |
|---|---|---|---|
| Thinking off | about 30 of 80 in earlier runs | 0 | – |
| low | 233 | 106 | 151 / 419 |
| medium | 233 | 111 | 167 / 472 |
| xhigh | 238 | 116 | 170 / 494 |

- From `low` to `xhigh`, correct answers rose from 339 to 354 of 360 for 13–18% more tokens.
  `medium` (344) is within noise of either.
- At `xhigh`, one of 360 questions reasoned until the 12,000-token limit without answering.
- Keep thinking on for anything with more than one step.

### Another model: Qwen3.6-35B-A3B

Much faster, but it thinks far longer and sometimes never answers. Tested:
`palmfuture/Qwen3.6-35B-A3B-GPTQ-Int4` on the same vLLM image (131k context, MTP 3).

| | Qwen3.8-27B | Qwen3.6-35B-A3B |
|---|---|---|
| Decode | 67.4 | 147.9 |
| 4 clients total | 167 | 315 |
| Cold 75k prompt | 64 s | 22 s |
| Accuracy, thinking off (of 80) | 30 | 18 |
| Accuracy, thinking on (of 80) | 77, using 12.4k tokens | 75, using 122k tokens |
| Thinking tokens per question (median / p90 / max) | 152 / 229 / 370 | 657 / 3,319 / 12,000 |

It is 2.2 times faster in raw decoding, but its template has no reasoning-effort control, it
thinks about four times as long, and 4 of 80 questions ran to the token limit without an answer.

### Another model: Qwen3.8-Flash-Next on Strata and XeStrata

A 125B mixture-of-experts model on the same single card. For one client it is faster than the
27B on vLLM, reads long prompts more than twice as fast, and scores the same on the accuracy
tests. With four clients it reaches about half of vLLM's throughput. Suggested by a reader of
this repo; tested on 2026-11-12.

**What was tested**

- **Model:** [Qwen3.8-Flash-Next](https://github.com/QwenLM/Qwen3.8-Flash-Next) activates about
  6B of its 125B parameters per token. Two 3-bit `IQ3_XXS` GGUF sets of 76 GB each: the original
  ([ISTA-DASLab](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF)) and
  UkisAI's [Swift 1.5](https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF)
  fine-tune, which is trained to think less.
- **Engines:** [Strata](https://github.com/Niko1221/Strata) 0.2.13 (image
  `ghcr.io/niko1221/strata:0.2.13-sycl`) and its fork
  [XeStrata](https://github.com/MistVVK/XeStrata) 0.2.2, which is developed on an Arc Pro B70.
  Both keep every expert in RAM (40 GB here) and the most-used ones in VRAM (about 13,900 of
  24,576 on the B70).
- **Settings:** 196k context, 8-bit KV cache, 180 W power cap, the same test scripts as the
  other sections (`stratabench.sh`). Accuracy runs used one client at a time and reasoning
  effort `low`.

**Results**

| | vLLM, Qwen3.8-27B | XeStrata, Swift | Strata, Swift, as set up | Strata, Swift + draft layer | Strata, original |
|---|---|---|---|---|---|
| Drafter | MTP 3 | MTP layer | none | MTP layer | DFlash2 |
| Decode mean, one client (tokens/s) | 66.7 | 79.0 | 48.9 | 79.9 | 70.7 |
| Code / prose / JSON (tokens/s) | – | 75 / 72 / 90 | 44 / 43 / 60 | 73 / 69 / 98 | 69 / 41 / 102 |
| 4 clients total, default (tokens/s) | 158.7 | 62.5 | 41.4 | – | 61.5 |
| Longest wait for first token, 4 clients | 0.2 s | 37 s | 56 s | – | 37 s |
| 4 clients total, 4 slots (tokens/s) | 158.7 | 86.9 | – | 75.7 | – |
| One client with 4 slots enabled (tokens/s) | 66.7 | 78.0 | – | 67.2 | – |
| Cold 75k prompt | 86 s | 37 s | 41 s | 41 s | 41 s |
| Long-context retrieval (of 3) | 3 | 3 | 3 | 3 | 3 |
| Streamed tool calls clean (of 16) | 16 | 16 | 16 | – | 16 |
| Prefix cache, 15.8k prompt: cold / cached | works | 7.9 s / 0.2–0.4 s | 8.0 s / 0.1–0.3 s | – | 8.4 s / 0.1–0.3 s |
| Accuracy, thinking off (of 80) | 30 | 25 | 26 | – | 24 |
| Accuracy, thinking on (of 80) | 77 | 79 | 79 | – | 79 |
| Chained questions, thinking on (of 120) | 106 | 111 | 111 | – | 113 |

A dash means not run. The vLLM figure for chained questions is at effort `low`; it scored 111
at `medium` and 116 at `xhigh`.

**What this shows**

- **One client:** up to 18% faster decode than the 27B on vLLM, and a 75k prompt is read in
  37–41 s against 86 s.
- **Several clients:** both engines serve one request at a time by default, so the fourth
  client waited 37–56 s for its first token. With four slots, total throughput is 76–87
  tokens/s against vLLM's 159. The slots cost XeStrata 1% of single-client speed and upstream
  Strata 16%, because upstream halves its expert cache.
- **Accuracy:** no loss from the 3-bit quant on these tests. Differences of two or three
  questions are noise. Whether the engines apply reasoning effort `low` exactly as vLLM does
  was not checked.
- **The drafter decides decode speed.** Without one, upstream runs at 49 tokens/s. With the MTP
  layer it matches XeStrata. Upstream's newer DFlash2 drafter is faster on predictable output
  (JSON 102 against 90 tokens/s) and much slower on prose (41 against 72).
- **XeStrata against upstream:** on speed they are level once upstream has a drafter, and
  prefill is within 10%. XeStrata's documented lead of two to three times in prefill does not
  hold against 0.2.13 on this card. XeStrata is still ahead on multi-client speed and on setup
  for the B70.
- **Swift against the original:** same accuracy within noise, and no visible saving in thinking
  at effort `low` (about 13k tokens for the 80 questions and 58k for the chained set on both).
- **Resources:** about 48 GB of RAM in use, plus a 29 GB table XeStrata keeps in RAM. CPU load
  stayed near 9% of 12 cores, because 99% of the experts needed were in VRAM.

**Which to pick**

| Situation | Choice |
|---|---|
| Several agents or people at once (the use case this setup aims for) | vLLM with Qwen3.8-27B, the recommended setup |
| One user, long prompts, a B70 | XeStrata with Swift 1.5 or the original model |
| One user, prefer the actively developed project | Upstream Strata with the original model |

**Conclusion for this repository:** vLLM with Qwen3.8-27B remains the recommended setup,
because the use case aimed for is several agents working in parallel. At four clients it
delivers 159 tokens/s with a 0.2 s wait for the first token, against 76–87 tokens/s for the
Strata engines with four slots, or 37–56 s of queueing without them. Strata and XeStrata are
the better choice only when one agent or one person uses the card at a time.

The Flash-Next runs are a single evening of testing; vision, the other quants and day-to-day
agent use are untested.

**Setup notes**

- **XeStrata** was built from `container/Containerfile` in its repository and set up with
  `xestrata --setup --family swift --model IQ3_XXS --context 196608 --vision yes --yes`. Setup
  downloaded the model, the draft layer and the image encoder, and configured vision.
- **Run setup with nothing else on the card.** XeStrata sizes its expert cache from the VRAM
  that is free during setup. With the vLLM server still running it recorded 311 MiB.
- **Upstream Strata with the original model** needed no hand edits: the container was started
  with `MODEL_PATH`, `CONTEXT=196608` and `VISION=on`. Its launcher fetched the DFlash2 drafter
  and set one request at a time, because DFlash2 has no parallel slots. It warned that the B70
  is untested by its maintainers, and did not enable vision.
- **Upstream Strata with the Swift files** did not load. The launcher pointed `--ple-gguf` at
  the second of the two files, where the Swift set does not have that table, and rewrote a
  corrected config on every start. The Swift columns come from
  `strata serve --profile <corrected config>`; the draft-layer column adds `--mtp` with the
  layer XeStrata had prepared.
- **Four slots:** `"parallel": 4` in XeStrata's model config, `--parallel 4` on `strata serve`.

### Power cap

The `xe` driver exposes a sustained power limit at
`/sys/bus/pci/devices/<pci-address>/hwmon/hwmon*/power1_cap` in microwatts (default 312 W here).
It is writable by root and takes effect immediately. Card power was read from `energy1_input`
by `powerbench.sh`.

Speed and efficiency:

| Cap | Decode | Decode, tokens per Wh | 4 clients total | 4 clients, tokens per Wh | Cold 75k prompt |
|---|---|---|---|---|---|
| 312 W (default) | 68.2 | 1,040 | 166.5 | 2,370 | 63 s |
| 260 W | 68.2 | 1,040 | 167.7 | 2,420 | 68 s |
| 220 W | 67.6 | 1,110 | 160.9 | 2,630 | 75 s |
| 200 W | 67.3 | 1,210 | 161.6 | 2,910 | 79 s |
| **180 W** | 66.7 | 1,330 | 158.7 | 3,170 | 86 s |
| 150 W | 64.4 | 1,540 | 148.0 | 3,550 | 102 s |

Power, heat and noise:

| Cap | Card power: decode / 4 clients / prefill | Energy for the 75k prompt | Peak package / VRAM | Fan peak |
|---|---|---|---|---|
| 312 W (default) | 236 / 253 / 310 W | 5.4 Wh | 68 °C / 82 °C | 3,926 rpm |
| 260 W | 236 / 249 / 260 W | 4.9 Wh | 65 °C / 82 °C | 3,215 rpm |
| 220 W | 220 / 220 / 220 W | 4.6 Wh | 63 °C / 82 °C | 2,911 rpm |
| 200 W | 200 / 200 / 200 W | 4.4 Wh | 62 °C / 80 °C | 2,679 rpm |
| **180 W** | 180 / 180 / 180 W | 4.3 Wh | 61 °C / 78 °C | about 2,500 rpm |
| 150 W | 150 / 150 / 150 W | 4.2 Wh | 59 °C / 72 °C | 2,196 rpm |

- Without a cap, decoding draws about 236 W; only prompt reading reaches the default limit.
- The knee is near 180 W: it costs 2% of decode speed, 5% of four-client throughput and 23 s on a
  cold 75k prompt, for about 55 W less while decoding. Below it, each watt saved costs roughly
  twice as much speed.
- Answers were still correct (canary 12/12) at 180 W and 150 W.

Set it, and make it persistent with the included udev rule (edit the PCI address and value first):

```bash
echo 180000000 | sudo tee /sys/bus/pci/devices/0000:01:00.0/hwmon/hwmon0/power1_cap
sudo install -m 644 99-b70-power-cap.rules /etc/udev/rules.d/ && sudo udevadm control --reload
```

The udev rule passes `udevadm verify` but had not yet been confirmed across a reboot when this
was written.

## B70 stuck fan and temperature workaround

After a load ends, the card's reported temperatures can freeze and the fan keeps following the
stale value (Intel issue IGCIT #1574). Left alone, the idle card here sat at about 42 W with the
fan running, and the readings only recovered on the next load.

`b70-telemetry-kick.sh` is a workaround that touches neither driver nor firmware. It only reads
files, and sends nothing to the model server:

1. **Idle detection.** It watches GPU idle residency through plain sysfs reads, which do not wake
   the card.
2. **Keep-alive pulse.** Every 10 s while the GPU is idle, it holds the `xe` debugfs
   `forcewake_all` file open for half a second. This refreshes the package temperature and fan
   control, and drops the card into its low-power idle state. The pulses never stop: without them
   the card returned to about 42 W, even after it had cooled down.
3. **VRAM temperature refresh.** After a load, every third pulse it also reads the two GuC
   firmware log files in debugfs. The 16 VRAM temperature sensors otherwise refresh only a few at
   a time; one 0.4 s log read refreshes almost all of them.
4. **Cooldown end.** Once package and VRAM are both at or below 55 °C for three checks, the log
   reads stop. Each log read costs a short 70–80 W spike, so they are not kept running.

Measured after a four-client load at a 180 W cap (card power from the card's own energy counter,
30 s windows; no wall meter was used):

| | Without the service | With the service |
|---|---|---|
| Idle card power | about 42 W | 8–20 W, about 12 W on average |
| Fan while idle | running | off most of the time, short bursts up to 900 rpm |
| VRAM reading after a load | frozen at the load value | 76 °C to 52 °C within a minute |
| Cooldown finished | never | about 70 s after the load |

Install as a root systemd service with `./install-b70-kick.sh`. Remove with:

```bash
sudo systemctl disable --now b70-telemetry-kick
sudo rm /usr/local/sbin/b70-telemetry-kick.sh /etc/systemd/system/b70-telemetry-kick.service
```

What was learned along the way:

- **The card has two idle states.** Per-second sampling shows it alternating between about 5 W
  with the fan off and about 42 W with the fan near 900 rpm. A pulse drops it to the low state; it
  can jump back a few seconds later, more often while the package is above about 40 °C. This is
  why idle power varies between 8 and 20 W from one 30 s window to the next.
- **Do not use the fan reading as a "cooled" test.** An earlier version waited for the fan to stay
  below 200 rpm. The fan cycles on every pulse, so that never happened, the log reads continued
  all night, and the card idled at 17–32 W.
- **What does not refresh the VRAM sensors:** DRM ioctls, writes to VRAM buffers, and reads of the
  frequency, throttle and sensor files. What does: the GuC log reads, a long forcewake hold
  (about 18 s for all 16 sensors), or any real GPU work. `vramprobe.sh`, `vramprobe2.sh` and
  `vramprobe3.sh` are the probes that established this; their output is in `results/`.
- **More pulses cost more power.** `kicktune.sh` measured 90 s windows at 33–37 °C: a 0.5 s pulse
  every 10 s read 7.4–7.9 W, every 5 s 13.2 W, and a 2 s pulse every 10 s 17.3–17.6 W. A 0.1 s
  pulse every 10 s read 4.7 W, but whether so short a pulse still pulls a warm card out of the
  42 W state was not checked.
- **Stopping the pulses once the card is cool did not work here.** At 33–36 °C the card stayed
  at 6.5 W for 90 s without pulses. With the pulses running it settles at 38–40 °C, and a
  version that stopped pulsing at 38 °C saw the card jump back to 42.7 W within about 30 s, six
  times in 25 minutes (about 17 W on average). The rest state remains in the script, off by
  default (`REST_MC`).
- **The energy counter freezes when nothing touches the card**, so an untouched card reads 0 W.
  Sample a sensor once a second while measuring, and measure over at least a minute.

## Scripts

All test scripts read the API key from `VLLM_API_KEY` or `~/.config/vllm/api-key`, except
`canary.py` and `bench_decode.py`, which take `--key`.

| Script | Purpose |
|---|---|
| `start-qwen38.sh` | Start or rebuild the recommended server |
| `run_vllm.sh` | Parameterized vLLM launcher (all settings as environment variables) |
| `run_llama.sh` | llama.cpp SYCL server on port 8001 |
| `run_ovms.sh` | OpenVINO Model Server on port 8001 |
| `canary.py` | 12 quick questions; a sanity check after any change |
| `speedbench.py` | Deterministic single-client decode speed (code, prose, JSON) |
| `mannbench.py` | 512-token prompt, 128 tokens out; predictable, code and prose prompts |
| `parbench.py` | Decode speed with N parallel clients |
| `bench_decode.py` | Earlier decode benchmark, used for the first engine comparison |
| `longctx.py` | Long prompt with three planted values; measures prefill time and retrieval |
| `evalset.py` | Seeded Python-expression questions; `--hard` chains three into one |
| `stream_tools.py` | Streamed tool calls: structure, JSON arguments, no leaked XML |
| `prefix_check.py`, `pfxtest.py` | Prefix-cache correctness and cold/cached latency |
| `concurrency.py` | Mixed short and long requests in parallel, checked for correctness |
| `suite.sh`, `exp.sh` | Run a standard set of tests against a server and save the output |
| `sweep1.sh` … `sweep4.sh` | The tuning and weights sweeps as they were run |
| `powerbench.sh` | Benchmarks with power, temperature and fan sampling |
| `stratabench.sh` | The test set against a Strata or XeStrata server |
| `kicktune.sh` | Root, read-only: idle power for different keep-alive pulse settings |
| `b70-telemetry-kick.sh`, `.service`, `install-b70-kick.sh` | Fan workaround |
| `vramprobe.sh`, `vramprobe2.sh`, `vramprobe3.sh` | Root, read-only probes: which debugfs reads refresh the VRAM temperature |
| `99-b70-power-cap.rules` | udev rule for a persistent power cap |
| `results/` | Raw outputs; `NOTES.md` is the chronological log |

Several scripts contain paths and a PCI address (`0000:01:00.0`) from the test machine. Check
them before running elsewhere.

## How the numbers were measured

- **Decode speed** is tokens after the first token divided by time after the first token, at
  temperature 0 with thinking off. `speedbench.py` is reproducible to about 0.1 tokens/s.
- **MTP speed depends on the text.** Predictable output (JSON, lists) decodes faster than prose
  because more guessed tokens are accepted. Compare engines only on the same prompts.
- **Four-client throughput** was usually measured once per configuration; differences of a few
  tokens/s are noise.
- **Accuracy** uses generated Python-expression questions with exact-match scoring. With 80
  questions, differences of two or three are not significant. All "thinking on" scores in the
  engine and weights tables used reasoning effort `low`.
- **Thinking off** scores about 30 of 80 on every engine and build; that is the model, not the
  quantization.
- **Prefill times** are cold: the prompt uses a fresh random seed so the prefix cache cannot help.

## Known gaps

- `--gpu-memory-utilization` above 0.93 was not tested.
- The AutoRound build lacks tool-call, prefix-cache and long-context tests.
- Why MTP 5, a 16k prefill batch, and the SergiioB GPTQ build with MTP 4 fail to start at 196k was
  not determined.
- Intel llm-scaler was tested with pre-quantized weights only, not its load-time `sym_int4` path.
- Qwen3.8-Flash-Next on Strata and XeStrata: vision, other quants (2-bit, 4-bit and larger),
  prompts above 75k tokens, reasoning effort above `low` and real agent sessions were not tested.
- Idle power figures (42 W, 8–20 W) come from the card's energy counter; they were not checked
  with a wall meter.
- Why the idle card alternates between a 5 W and a 42 W state was not determined.

## Sources

- [vLLM recipe for Qwen3.8-27B](https://recipes.vllm.ai/Qwen/Qwen3.8-27B.md)
- [intel/llm-scaler vLLM README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md)
- [Jonathan Mann: Qwen3.8-27B on the Arc Pro B70](https://jonathanmann.tech/blog/qwen38-intel-arc-b70/)
- [MikeCaldera/intel-arc-pro-b70-qwen38-vllm](https://github.com/MikeCaldera/intel-arc-pro-b70-qwen38-vllm)
- [Kuro's blog: Qwen3.8-27B on an Intel Arc Pro B70](https://khoit.dev/blog/intel-b70-vllm-qwen38/)
- [OpenVINO/Qwen3.8-27B-int4-ov model card](https://huggingface.co/OpenVINO/Qwen3.8-27B-int4-ov)
- [openvino.genai issue #4343 (VLM prefix caching)](https://github.com/openvinotoolkit/openvino.genai/issues/4343)
- [Strata: Intel Arc notes](https://github.com/Niko1221/Strata/blob/main/docs/INTEL_ARC.md)
- [XeStrata: differences from upstream (XE.md)](https://github.com/MistVVK/XeStrata/blob/main/docs/XE.md)
- [UkisAI Swift 1.5 model card](https://huggingface.co/ukisai/Swift1.5-Qwen3.8-Flash-Next)
- [HaberstrohSystems AutoRound build](https://huggingface.co/HaberstrohSystems/Qwen3.8-27B-int4-g128-sym-autoround)

## Licence

[MIT](LICENSE)
