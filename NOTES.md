> Chronological lab notes. The curated write-up is [README.md](README.md).

# Qwen3.8-27B on Arc Pro B70 — current setup (2026-11-10)

Production container: `qwen38` (restart unless-stopped, autostarts via podman-restart.service + linger).
Launch: `./start-qwen38.sh` (starts the stopped container) or `./start-qwen38.sh --recreate` (rebuild; = `NAME=qwen38 RESTART=unless-stopped MAXLEN=196608 UTIL=0.93 SEQS=4 BATCH=4096 MTP=3 LMO= ./run_vllm.sh`). Vision input ON since 2026-11-11 (fresh-start KV 199,457 tokens).
Image: docker.io/vllm/vllm-openai-xpu:v0.33.0, weights RedHatAI/Qwen3.8-27B-INT4 (W4A16), fp8 KV.
API key: Podman secret `vllm_api_key` (from ~/.config/vllm/api-key), no longer on the command line.
Fallback: old container `qwen38-rh` (131k ctx, 1 seq), stopped, restart=no. `podman stop qwen38 && podman start qwen38-rh`.

## Measurements (this config)
| test | result |
|---|---|
| canary.py thinking on | 12/12 |
| stream_tools.py (streamed tool calls, think on/off) | 16/16 clean, no XML leak |
| decode, 1 client (parbench.py) | 47–50 t/s |
| decode, 2 / 3 / 4 clients | ~47 / 44–46 / 45 t/s each; 92 / 128–131 / 170 t/s total |
| concurrency.py 48 req, 4 parallel | 48/48 correct, no crash |
| longctx.py 3-needle retrieval | 3/3 at 75k (63 s), 3/3 at 187k (268 s cold prefill) |
| context cache | 206,580 tokens at util 0.93 (1.05x of 196,608) |
| MTP off for comparison | 31–34 t/s per client; cache 265k tokens (would allow native 262k) |

## Findings
- `--max-num-seqs 1` limit is not needed on upstream v0.33.0: MTP + 4 concurrent seqs stable.
- 229k+ context does not fit with MTP at 0.93; native 262k only fits without MTP (not worth -35% speed).
- Hermes streaming tool calls are fine with qwen3_coder + qwen3 reasoning parser; keep streaming on.
- concurrency.py needle prompt (NATO-word filler) makes the model treat it as a puzzle (~6k reasoning tokens); a test artifact, not a bug.

## Engine/quant comparison (2026-11-10, suite.sh, results/)
llama.cpp: ghcr.io/ggml-org/llama.cpp:server-intel b12242 (SYCL), run_llama.sh: 196k ctx, 4 slots,
unified q8_0 KV, flash attention on, MTP via `--spec-type draft-mtp --spec-draft-n-max 3` (MTP layer is
inside the main GGUF, no separate draft file needed; acceptance 92-94%).

| config | 1 client t/s | 4 clients each / total | TTFT | 75k prefill | evalset off / on (of 80) |
|---|---|---|---|---|---|
| **vLLM RedHat INT4 (production)** | 54 | 44 / 167 | 0.30 s | 64 s | 30 / 77 |
| llama.cpp Q4_K_M (local, 16.2 GiB) | 53 | 32 / 112 | 0.69 s | 94 s | 29 / 79 |
| llama.cpp unsloth UD-Q5_K_XL (19.4 GiB) | 45 | 29 / 101 | 0.72 s | 98 s | 31 / 80 |
| llama.cpp unsloth UD-Q4_K_XL (16.4 GiB) | 35 | 25 / 89 | 0.81 s | 110 s | 32 / 78 |

All four: canary 12/12, streamed tool calls 8/8, 3/3 retrieval at 75k.
- Quality: no significant difference at n=80; the shared miss ('-'.join(sorted('yuwoep'))) is a base-model
  weakness. Thinking off is ~30/80 everywhere, so keep thinking on.
- UD-Q4_K_XL is slow on SYCL because of its IQ4_XS/Q5_K/Q3_K tensors; plain Q4_K/Q6_K/Q8_0 is fastest.
- f16 KV gives the same speed as q8_0; the "Flash Attention ... assigned to device CPU" warning is harmless.
- Verdict: vLLM stays production (same single-stream speed, ~1.5x concurrency, ~1.5x faster prefill).
  Best llama.cpp fallback: the local Q4_K_M; UD-Q5_K_XL if you want the highest-bit quant.

## GPTQ + llm-scaler retest (2026-11-10, after disk resize to 405 GB)
GPTQ = SergiioB/Qwen3.8-27B-GPTQ-Int4-sym-G128-MTP-BF16 in ~/models/Qwen3.8-27B-GPTQ-Int4-MTP.
Same server settings for all (196k, 4 seqs, MTP 3, util 0.93, fp8 KV). speedbench.py = temp 0, fixed
code/prose/JSON prompts, reproducible to 0.1 t/s.

| config | speedbench mean (code/prose/json) | 4 clients each / total | evalset off / on | prefix check |
|---|---|---|---|---|
| vLLM 0.33 + GPTQ | 68.3 (67.4/58.3/79.1) | 44 / 152 | 26 / 77 | 24/24, 85% hits |
| **vLLM 0.33 + RedHat INT4 (production)** | 67.4 (66.8/57.9/77.5) | 44 / 167 | 30 / 77 | (81-86% in Hermes use) |
| llama.cpp Q4_K_M | 66.1 (64.6/58.3/75.3) | 32 / 112 | 29 / 79 | - |
| llm-scaler + GPTQ | 65.4 (64.6/55.9/75.8) | 41 / 152-158 (warm) | 25 / 79 | 24/24, 65% hits |
| llm-scaler + RedHat INT4 | 64.7 (63.7/55.9/74.4) | 41 / 156 | 30 / 77 | 24/24, 65% hits |

All: canary 12/12, streamed tool calls 8/8, 3/3 retrieval at 75k (63-66 s prefill on the vLLM family).
- The GPTQ "sum(i*i for i in range(4)) = 30" failure is a thinking-OFF answer; RedHat INT4 gives 30 too
  (both engines). With thinking on, both give 14. The GPTQ build is not broken; its rejection was unfair.
- vLLM v0.33.0 already contains the MTP fix (qwen3_5_mtp.py: GPTQ dynamic "-:...mtp..." rule => MTP
  layers unquantized). No patch or nightly needed even though PR #47828 is still open. Acceptance ~3.0-3.25.
- llm-scaler: prefix caching is OFF by default for this model (pass --enable-prefix-caching), and even then
  hits only 65% vs 85% upstream; ~5 min start; Triton JIT stalls of 13-17 s on the first request at each new
  batch size after a restart. No prefix-cache corruption seen with either weights.
- GPTQ vs RedHat: +1.3% decode (noise level), thinking-off 26 vs 30 of 80 (weak signal for RedHat).
  Verdict: keep production as is; GPTQ on upstream vLLM is a valid equal alternative.

## Scripts (this dir)
speedbench.py (deterministic decode), prefix_check.py (prefix-cache correctness), onequestion.sh,
run_llama.sh, suite.sh (`./suite.sh <tag> <port>`), evalset.py (80 seeded questions, results/<tag>.json).
run_vllm.sh (parameterized launcher), stream_tools.py, concurrency.py, parbench.py, longctx.py.
In ~: canary.py, bench_decode.py. (stress.sh no longer exists.)

## Other model tried: Qwen3.6-35B-A3B (2026-11-10)
palmfuture/Qwen3.6-35B-A3B-GPTQ-Int4 on vLLM 0.33 (131k ctx, 4 seqs, MTP 3; KV fits 329k tokens).
Hermes docs: no model recommendations; need >=64k context and server-side tool-call parsing.
| | Qwen3.8-27B RedHat INT4 | Qwen3.6-35B-A3B GPTQ |
|---|---|---|
| speedbench mean | 67.4 t/s | 147.9 t/s |
| 4 clients each / total | 44 / 167 | 89 / 315 |
| 75k prefill | 64 s | 22 s |
| evalset thinking off | 30/80 | 18/80 |
| evalset thinking on | 77/80, 12.4k tokens, 59 s | 75/80, 122k tokens, 329 s |
| thinking tokens per question (median / p90 / max) | 152 / 229 / 370 | 657 / 3319 / 12000 (4 hit the cap, no answer) |
Canary 12/12, tool calls 8/8, prefix check 24/24 (92% hits), MTP acceptance 3.9.
Verdict: 2.2x raw speed but no reasoning_effort control in its template, ~4x more thinking tokens,
occasional runaway reasoning with no answer, and weaker without thinking. Stays with Qwen3.8-27B.
llama.cpp GGUF of Qwen3.6 (~/models/qwen36-gguf) was downloaded but not run: the weakness is the model's.

## B70 stuck temperature/fan workaround (IGCIT #1574)
Symptom seen here: after a load, all hwmon temps frozen (pkg 58 C), fan ~2100 rpm, card 42 W while idle.
Holding /sys/kernel/debug/dri/0000:01:00.0/forcewake_all open briefly refreshes telemetry: a 0.5 s hold
every 10 s gave fan ~48 rpm and 7 W idle. Files: b70-telemetry-kick.sh + .service; install with
./install-b70-kick.sh (root systemd service).
Remove: sudo systemctl disable --now b70-telemetry-kick && sudo rm /usr/local/sbin/b70-telemetry-kick.sh /etc/systemd/system/b70-telemetry-kick.service

## vLLM tuning + alternative 4-bit builds (2026-11-11, exp.sh / sweep1.sh / sweep2.sh, results/tune/)
Baseline = production (RedHat INT4, MTP 3, batch 4096, 4 seqs, fp8 KV): 67.4 t/s, 174 t/s @4 clients, 63 s for 75k, 30/77 of 80.
- XPU graph is on by default in v0.33.0; VLLM_XPU_ENABLE_XPU_GRAPH is an unknown/ignored env var (removed from run_vllm.sh).
- No effect (within noise): batch 8192, KV f16 vs fp8, 1 vs 4 seqs (single-stream), VLLM_XPU_PP_MICROBATCH=0, VLLM_XPU_USE_SAMPLER_KERNEL=0.
- MTP 2: 63.6 t/s. MTP 4: 70.1 t/s single (json +12%, prose -5%) but 147 t/s @4 clients and ~8k less KV. MTP 5 and batch 16384: fail to start at 196k.
- Weights (all MTP 3): philbert440 W4A16-AWQ 67.5 t/s, 166 @4, 27/80 off, 80/80 on, KV 203,731;
  pearsonkyle GPTQ 67.2, 155 @4, 28/76; cyankiwi AWQ g32 (21 GB) 62.6, 151 @4, 29/78, KV only 154k; SergiioB GPTQ 66.2, 153 @4, 25/78.
- DSpark speculator (RedHatAI/Qwen3.8-27B-speculator.dspark, 4 GB) loads on XPU but leaves 3.45 GiB KV => max context 48k (< Hermes 64k minimum). Not usable on one B70. DFlash2 needs an unmerged vLLM PR; not tried.
- Verdict: production config is already at the optimum; philbert440 AWQ is the only candidate worth a longer accuracy test (same speed, 80/80 vs 77/80, n too small to call).

## AutoRound build + Mann-style benchmark (2026-11-11, sweep3.sh / sweep4.sh, mannbench.py)
mannbench.py = ~512-token prompt, 128 tokens out, 1 warm-up + 5 runs, median decode after first token, thinking off,
temp 0; prompts: count (fully predictable), code, prose. Mann's own prompt is unpublished.
| config | speedbench mean (code/prose/json) | mann count / code / prose | 4 clients total | evalset off / on | KV tokens |
|---|---|---|---|---|---|
| RedHat INT4 MTP3 (production) | 67.4 (66.8/57.9/77.5) | 81.1 / 64.7 / 49.1 | 174 | 30 / 77 | 206,580 |
| RedHat INT4 MTP4 | 70.2 (68.6/55.5/86.5) | 88.4 / 65.4 / 46.0 | 140 | - | 198,043 |
| SergiioB GPTQ MTP4, Mann's settings (131k, 1 seq, batch 8192, util 0.88, no prefix cache) | 69.3 | 88.3 / 69.3 / 42.6 | - | - | 146,410 |
| AutoRound + VLLM_XPU_INC_WNA16_BACKEND=w4a16, MTP3 | 69.8 (66.5/60.1/82.9) | 85.8 / 68.4 / 58.5 | 175-177 | 28 / 80 | 213,704 |
| AutoRound + w4a16, MTP4 | 72.1 (65.3/58.4/92.5) | 94.3 / 76.3 / 53.4 | 158 | - | 206,653 |
| AutoRound + w4a8, MTP3 | 65.0 | 79.2 / 63.1 / 52.8 | 148 | - | 213,704 |
- AutoRound = HaberstrohSystems/Qwen3.8-27B-int4-g128-sym-autoround in ~/models/alt/Qwen3.8-27B-AutoRound (17.7 GiB).
- Default backend (auto => ark, auto_round_kernel) and explicit ark: engine process dies silently right after
  "Loading weights took", at 196k and 131k (results/tune/ar-auto.full.log). Only w4a16 / w4a8 start.
- AutoRound+w4a16 MTP3 full suite: canary 12/12, 3/3 at 75k in 64 s. Not yet run: stream_tools, prefix_check, 187k retrieval.
- Mann's 84.6 t/s reproduced and exceeded (88.3-88.4) with MTP4 on a fully predictable prompt; same config gives 43-46 on prose.
- SergiioB GPTQ MTP4 does not start at 196k/0.93 (cause not captured; starts at 131k).

## OpenVINO Model Server test (2026-11-11, run_ovms.sh, results/ovms-mtp.txt)
openvino/model_server:weekly (OVMS 2026.5.0), OpenVINO/Qwen3.8-27B-int4-ov (NNCF INT4_ASYM g128, 15 GB) in
~/models/ov, GPU, built-in MTP draft (--draft_model_path .), tool_parser qwen3coder, reasoning_parser qwen3,
max_num_seqs 4, prefix caching flag on, dynamic KV. Needs --user 0 under rootless podman. Loads in ~30 s.
| | vLLM RedHat INT4 (production) | OVMS int4-ov + MTP | OVMS, MTP off |
|---|---|---|---|
| speedbench mean (code/prose/json) | 67.4 (66.8/57.9/77.5) | 71.3 (67.6/51.8/94.4) | 32.0 |
| mann count / code / prose | 81.1 / 64.7 / 49.1 | 86.6 / 75.8 / 45.1 | - |
| 4 clients each / total | 44 / 174 | 37 / 88 (TTFT up to 5 s) | 30 / 113 |
| 75k prefill / 187k prefill | 63 s / 268 s | 99 s / 457 s (3/3 both) | - |
| evalset off / on | 30 / 77 (12.4k tok, 59 s) | 23 / 79 (17.3k tok, 146 s) | - |
| canary / streamed tools | 12/12, 8/8 | 12/12, 8/8 | - |
| prefix cache | 81-86% hits | 0 cached tokens on a repeated 3.6k prefix, same latency | 0 as well |
Verdict: single-stream decode on par or slightly ahead, but no working prefix cache, half the 4-client
throughput and ~1.6x slower prefill => worse for Hermes/agentic use. Stay on vLLM.
- OVMS prefix caching (pfxtest.py): with the default dynamic KV (cache_size 0) no hits. With --cache_size N (static)
  and MTP off it works: 15.7k prompt 11 s cold -> 1.0 s; 79k prompt 97-100 s cold -> 6-7 s (cached in 384/1024-token
  steps); u8 KV precision makes no difference to speed. Decode is 32 t/s without MTP.
- With MTP + --cache_size: usage reports cache hits but a cached 15.7k turn takes 4 s (vs 1 s), and a cold 79k
  prompt did not finish in 9-15 min (vs 99 s with dynamic KV). Model card: MTP path supported only with prefix
  caching disabled. => on OVMS it is MTP speed or prefix cache, not both. vLLM has both (15.8k: 8.6 s cold, 1.1 s cached).

## Vision input (2026-11-11)
Production runs --language-model-only. With vision enabled (LMO= ./run_vllm.sh, same settings): fresh-start KV
199,457 tokens vs 206,580 (-7.1k, -3.4%), 196,608 max context still fits; image request works (448x448 image =
~200 prompt tokens, 1.0 s); speedbench 67.3 t/s (unchanged). Not switched in production.
- 2026-11-11: production recreated with vision on. Verified: canary 12/12, stream_tools 8/8, 166 t/s @4 clients, image request OK.
- Tool parser names: in vLLM v0.33.0 (and llm-scaler 0.26) `qwen3_coder` and `qwen3_xml` are aliases of the same
  class (tool_parsers/__init__.py -> Qwen3EngineToolParser). No behavioural difference; no reason to change.

## Compile-cache mount + vision memory (2026-11-11)
- run_vllm.sh now mounts ~/.cache/vllm-xpu/{vllm,neo_compiler_cache} into the container (CACHEDIR= disables).
  Effect: recreate start 180 s -> 80-95 s (AOT compile loaded instead of rebuilt). It does NOT enlarge the KV cache.
- CORRECTION: the larger KV after a restart (257,869) was a text-only effect. With vision on, restart and recreate
  both give 199,457: the vision encoder is profiled at the maximum image size (peak activation 1.96 GiB).
  So vision cost vs the old warm text-only state is ~58k tokens of cache, not 7k. Max context 196,608 is unaffected.
- `--mm-processor-kwargs {"max_pixels":1003520}` (~1 MP, larger images downscaled): peak activation 0.81 GiB,
  KV 227,951 tokens. Now in start-qwen38.sh. Verified: canary 12/12, stream_tools 8/8, 1600x1200 image answered (1008 prompt tokens).

## Reasoning effort comparison (2026-11-11, evalset.py -n 240 and --hard -n 120, production, 4 parallel, temp 0)
See results/effort.txt and results/effort-*.json. NOTE: all earlier "evalset thinking on" numbers used effort=low
(the script default), not the server default medium.
- effort-low think_on: 233/240  (179s, 37510 completion tokens)
- effort-hard-low think_on: 106/120  (224s, 53994 completion tokens)
- effort-medium think_on: 233/240  (199s, 44393 completion tokens)
- effort-hard-medium think_on: 111/120  (263s, 62859 completion tokens)
- effort-xhigh think_on: 238/240  (309s, 57621 completion tokens)
- effort-hard-xhigh think_on: 116/120  (311s, 67640 completion tokens)
- effort-hard-off think_off: 0/120  (16s, 441 completion tokens)

## Power-cap sweep (2026-11-11, powerbench.sh, results/power/)
Cap = /sys/bus/pci/devices/0000:01:00.0/hwmon/hwmon0/power1_cap (microwatts, root-writable, default 312000000,
power1_cap_interval 15, power1_crit 575000000). Takes effect immediately, no restart. Card power from energy1_input.
Production server (vision on, MTP 3, 4 seqs); speedbench 600 tok, parbench p4 768 tok, longctx 60000 (fresh seed each run).
| cap | decode W / t/s / tok per Wh | 4 clients W / total t/s / tok per Wh | 75k prefill s / Wh | pkg / vram peak C | fan peak rpm |
|---|---|---|---|---|---|
| 312 (default) | 236 / 68.2 / 1040 | 253 / 166.5 / 2370 | 63 / 5.4 | 68 / 82 | 3926 |
| 260 | 236 / 68.2 / 1040 | 249 / 167.7 / 2420 | 68 / 4.9 | 65 / 82 | 3215 |
| 220 | 220 / 67.6 / 1110 | 220 / 160.9 / 2630 | 75 / 4.6 | 63 / 82 | 2911 |
| 200 | 200 / 67.3 / 1210 | 200 / 161.6 / 2910 | 79 / 4.4 | 62 / 80 | 2679 |
| 180 (chosen) | 180 / 66.7 / 1330 | 180 / 158.7 / 3170 | 86 / 4.3 | 61 / 78 | ~2500 |
| 150 | 150 / 64.4 / 1540 | 150 / 148.0 / 3550 | 102 / 4.2 | 59 / 72 | 2196 |
Canary 12/12 at 180 and 150 W. Knee at ~180 W: 200->180 costs 0.9% decode, 180->150 costs 3.4%.
180 W set on 2026-11-11 (sudo tee). Persistence: 99-b70-power-cap.rules (udev) ->
`sudo install -m 644 ~/llm-b70-eval/99-b70-power-cap.rules /etc/udev/rules.d/ && sudo udevadm control --reload`
(not yet confirmed installed / not yet verified across a reboot). Revert: echo 312000000 into power1_cap, remove the rule.

## Fan workaround: re-arm flapping found 2026-11-11
With FAN_STUCK=200 the service flaps: "card cooled" then 10-30 s later "fan high while idle, pulsing armed", forever.
Cause: fan1_input single readings blip to 300-1200 rpm while the fan is effectively off (seen at 20 Hz polling:
0 / 1177 / 1200 alternating while the card is awake). Result: card never rests; idle ~16 W over 4 min instead of ~7 W.
Not caused by the power cap (same pattern at 17:20 before the sweep). Fix in the project copy: re-arm only after
STUCK_N=3 consecutive readings >= FAN_STUCK. Needs reinstall: ./install-b70-kick.sh (now restarts the service).
Short-window idle power/residency readings are unreliable (counters catch up in jumps); use windows >= 2 min.

## Gateway (2026-11-11)
Bifrost gateway on :4000 in front of qwen38; see ~/llm-homelab-setup (README.md, docs/DESIGN.md).
speedbench.py and prefix_check.py gained an optional --url (default unchanged: localhost --port);
prefix_check still reads vLLM /metrics on --port with the vLLM key (--metrics-key to override).

## Fan workaround: final mechanism (2026-11-11/12)
Power-cap udev rule and container autostart verified after a reboot (cap 180 W present, canary 12/12).
Findings, in order:
- Stopping the pulses after cooldown leaves the idle card at ~42.7 W (energy1_input), even 105 s after the last
  request. Pulsed every 10 s it idles far lower. So pulses must continue while idle.
- Per-second sampling: two idle states, ~5 W / fan 0 and ~42 W / fan ~895 rpm. A forcewake pulse drops to the low
  state; the card can return to the high state 3-7 s later, more often above pkg ~40 C.
- VRAM sensors (temp3 = max of temp6..temp21) refresh a few at a time while awake (~18 s of forcewake for all 16).
  Reading tile0/gt{0,1}/uc/guc_log (0.4 s) refreshes 15 of 16 at once (vramprobe*.sh, results/vramprobe*.txt).
  No effect: DRM ioctls, VRAM buffer writes, freq/throttle/sensor reads. A log read spikes to 68-79 W and leaves
  the card in the 42 W state until the next pulse.
- Version with "fan < 200 rpm for 3 checks" as cooldown test never finished (fan cycles on every pulse): log reads
  every 30 s all night, idle 17-32 W at pkg 41-43 C.
- Final version (installed 2026-11-12 06:55 UTC): cooldown test = pkg and VRAM <= 55 C for 3 checks, no fan test;
  settling pulse after each log refresh; no request to the model server. After a 4-client load: "card cooled" 69 s
  after load end (pkg 49, vram 52); 30 s windows then 8-20 W, ~12 W average, pkg 37 C / vram 36 C after 13 min,
  fan 0 for 19-27 of 30 one-second samples, bursts to 480-900 rpm.
- 2026-11-12: after a reboot, everything came back on its own: qwen38, open-webui, llm-gateway (Quadlet), the 180 W cap (udev rule verified) and b70-telemetry-kick.

## Kick tuning and rest state (2026-11-12)
kicktune.sh (results/kicktune.txt), 90 s windows x2, pkg 33-37 C, each window starts with one pulse:
no kick + 1 s temp reads 6.5 W; 10 s/0.5 s 7.4-7.9 W (10.1 W with 1 s reads); 10/0.1 4.7; 20/0.5 5.0; 5/0.5 13.2;
3/0.5 17; 10/2 17.5; no kick + no reads 0.0-0.2 W and idle 4% = counters frozen, not a real reading.
Runtime PM is not involved (runtime_status always active, 11 s suspended since boot).
User confirmed on an external reading that power drops with the service on vs stopped in the 42.8 W state.
REST_MC=38000 version (stop pulses when cool): flapped, 6x "card at rest" -> "resting card at 42755 mW" in 25 min,
~17 W average. Default now REST_MC=0 (always pulse).

## Qwen3.8-Flash-Next / Swift 1.5 IQ3_XXS on XeStrata 0.2.2 and Strata 0.2.13-sycl (2026-11-12)
Raw: results/strata/. Production stopped 17:16-18:30 UTC, restored, canary 12/12.
XeStrata: podman build of ~/src/XeStrata/container (rpm xe0.2.2-1); setup --family swift --model IQ3_XXS
--context 196608 --vision yes --yes --no-start; data in ~/.local/share/xestrata (78 GB + mtp), config
~/.config/xestrata. First setup ran with production on the card and pinned --vram-free-mib 311: rerun with card free.
Upstream: ghcr.io/niko1221/strata:0.2.13-sycl, volume strata-data; launcher writes --ple-gguf shard 2 (table is in
shard 1 for Swift) and rewrites it each start -> use `strata serve --profile /data/install/fixed.json` (fixed-mtp.json
adds --mtp /mtp/rt from XeStrata's folder). PCIe probe 19.7 GB/s host->device.
speedbench mean: xestrata 79.0, strata no draft 48.9, strata+mtp 79.9; par4: xestrata 78.0 single / 86.9 x4,
strata+mtp 67.2 / 75.7. 75k prefill 37 s / 41 s. evalset 79/80 both, hard 111/120 both (p=1, effort low).

## Upstream Strata 0.2.13 on original Qwen3.8-Flash-Next IQ3_XXS (2026-11-12)
Files: ~/models/flashnext/IQ3_XXS (ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF, 76 GB). Launcher env: MODEL_PATH,
PRESET=orig, CONTEXT=196608, VISION=on, PORT=8096, API_KEY_FILE. Worked untouched; DFlash2 drafter (772 MiB VRAM),
parallel 1, no --vision in the written config. Raw: results/strata/strata0213-orig-iq3xxs-dflash2.txt.
Freed disk first: deleted ~/models/alt, ~/models/Qwen3.6-35B-A3B-GPTQ-Int4, intel/llm-scaler-vllm image.

## Agentic coding test, 27B vs Flash-Next on stock Strata (2026-11-13)
Files: agentic/ (briefs, runners, hidden tests). Work dirs ~/bench/delegate and ~/bench/plan (not in git).
Delegation (6 Go jobs from the homelab delegation trial, briefs from that session's transcript, one at a time):
all 12 pass vet/race tests, protected files untouched. 27B 944 s / 42k out (19.6k reasoning), Flash-Next IQ3_XXS
1087 s / 61k out. Strata IQ3_S aborted: DFlash2 accepted 0 drafts, 19 tok/s (bug with that pack on this card).
Planning (pi, empty repo, 45 min cap, hidden tests written first): logstat 27B 25/26 hidden, 35 own, 8 min;
FN 26/26, 146 own, 23 min. jobq 27B 22/22, 33 own, 24 min; FN 21/22 (400 not 404 for non-numeric id), 98 own,
hit the 45 min cap. 27B logstat fails escaped quotes in UA. Verdict: not much better; keep vLLM 27B.
27B run-to-run variance: job A 88-138 s (morning, 3 parallel) vs 417 s (rerun, alone).
