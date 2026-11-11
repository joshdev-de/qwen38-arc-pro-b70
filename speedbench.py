#!/usr/bin/env python3
"""Deterministic single-stream decode benchmark: temperature 0, fixed prompts
(code / prose / JSON), thinking off, N tokens each, R repeats. Same text for
every config, so MTP acceptance is comparable. Reports mean decode t/s."""
import argparse, json, os, statistics, time, urllib.request

PROMPTS = {
    "code": "Write a complete Python module implementing an LRU cache with TTL expiry, thread safety, "
            "type hints, docstrings and a pytest test suite.",
    "prose": "Explain in detail how a modern CPU executes instructions out of order, covering the "
             "reorder buffer, register renaming, reservation stations and branch prediction.",
    "json": "Produce a JSON array of 40 objects describing fictional servers with fields id, hostname, "
            "ip, os, cpu_cores, ram_gb, disks (array of {device, size_gb}), tags (array) and status.",
}

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--url", default=None, help="full chat/completions URL (overrides --port), e.g. a gateway")
ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--tokens", type=int, default=400)
ap.add_argument("-r", type=int, default=3)
ap.add_argument("--tag", default="")
a = ap.parse_args()


def run(prompt):
    body = {"model": a.model, "stream": True, "temperature": 0, "max_tokens": a.tokens, "ignore_eos": True,
            "stream_options": {"include_usage": True}, "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(a.url or f"http://localhost:{a.port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 method="POST", headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {a.key}"})
    first = None; n = 0
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            d = json.loads(line[5:])
            if d.get("usage"):
                n = d["usage"]["completion_tokens"]
            if d["choices"] and first is None and d["choices"][0]["delta"].get("content"):
                first = time.time()
    return (n - 1) / (time.time() - first)


run(PROMPTS["prose"])  # warm-up
res = {k: [run(p) for _ in range(a.r)] for k, p in PROMPTS.items()}
allv = [v for vs in res.values() for v in vs]
print(f"{a.tag:16s} " + "  ".join(f"{k} {statistics.mean(v):5.1f}" for k, v in res.items())
      + f"  | mean {statistics.mean(allv):5.1f} t/s (spread {min(allv):.1f}-{max(allv):.1f})")
