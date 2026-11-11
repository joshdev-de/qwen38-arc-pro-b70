#!/usr/bin/env python3
import argparse, json, random, statistics, time, urllib.request

WORDS = ("system kernel buffer queue thread memory socket parser token cache index "
         "vector matrix tensor stream packet router schema module object method").split()

def prompt(seed, n_words=420):
    rng = random.Random(seed)
    body = " ".join(rng.choice(WORDS) for _ in range(n_words))
    return (f"Run {seed}. Notes: {body}\n\n"
            "Ignore the notes. Explain in detail how a hash map handles collisions.")

def run(args, seed):
    req = {"model": args.model, "stream": True, "stream_options": {"include_usage": True},
           "max_tokens": 128, "min_tokens": 128, "ignore_eos": True, "temperature": 0,
           "chat_template_kwargs": {"enable_thinking": False},
           "messages": [{"role": "user", "content": prompt(seed)}]}
    r = urllib.request.Request(args.url, data=json.dumps(req).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {args.key}"})
    t0 = time.perf_counter(); t_first = t_last = None; usage = None
    with urllib.request.urlopen(r, timeout=600) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[5:])
            if chunk.get("usage"):
                usage = chunk["usage"]
            for ch in chunk.get("choices", []):
                d = ch.get("delta", {})
                if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                    now = time.perf_counter(); t_first = t_first or now; t_last = now
    if not usage or t_first is None or t_last == t_first:
        raise SystemExit(f"bad response, usage={usage}")
    out = usage["completion_tokens"]
    return {"prompt": usage["prompt_tokens"], "out": out, "ttft": t_first - t0,
            "e2e": t_last - t0, "decode": (out - 1) / (t_last - t_first)}

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
ap.add_argument("--key", default="change-me")
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--runs", type=int, default=5)
args = ap.parse_args()
base = random.randrange(10**6)
run(args, base)  # warm-up
res = []
for i in range(args.runs):
    m = run(args, base + i + 1)  # new prompt each run, so nothing is reused from cache
    res.append(m)
    print(f"run {i+1}: prompt {m['prompt']} tok, out {m['out']} tok, "
          f"TTFT {m['ttft']:.3f}s, decode {m['decode']:.2f} t/s")
d = [m["decode"] for m in res]
print(f"\nmedian decode {statistics.median(d):.2f} t/s (min {min(d):.2f}, max {max(d):.2f}), "
      f"median TTFT {statistics.median(m['ttft'] for m in res):.3f}s, "
      f"median e2e {statistics.median(m['e2e'] for m in res):.3f}s")
