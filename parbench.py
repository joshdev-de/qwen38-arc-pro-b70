#!/usr/bin/env python3
"""Parallel decode benchmark: P clients each stream N tokens (ignore_eos) from a
short prompt; reports per-request decode t/s (after first token) and aggregate."""
import argparse, json, os, statistics, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

PROMPT = ("Write a long, detailed technical essay about the history of compilers, "
          "covering parsing, optimization, register allocation and JIT compilation.")


def one(args, i):
    body = {"model": args.model, "stream": True, "temperature": 0.7, "max_tokens": args.tokens,
            "ignore_eos": True, "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": f"[{i}] {PROMPT}"}]}
    req = urllib.request.Request(args.url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {args.key}"})
    t0 = time.time(); first = None; n = 0
    with urllib.request.urlopen(req, timeout=1200) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            d = json.loads(line[5:])
            if d.get("usage"):
                n = d["usage"]["completion_tokens"]
            if d["choices"] and first is None and (d["choices"][0]["delta"].get("content")):
                first = time.time()
    end = time.time()
    return (n - 1) / (end - first), first - t0, end


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
    ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--tokens", type=int, default=384)
    ap.add_argument("-p", type=int, nargs="+", default=[1, 2, 4])
    args = ap.parse_args()
    one(args, 0)  # warm-up
    for p in args.p:
        t0 = time.time()
        with ThreadPoolExecutor(p) as ex:
            res = list(ex.map(lambda i: one(args, i), range(p)))
        wall = max(r[2] for r in res) - t0
        per = [r[0] for r in res]
        print(f"p={p}: per-request decode {statistics.median(per):5.1f} t/s (min {min(per):.1f}), "
              f"TTFT max {max(r[1] for r in res):.2f}s, aggregate {p * args.tokens / wall:5.1f} t/s")


if __name__ == "__main__":
    main()
