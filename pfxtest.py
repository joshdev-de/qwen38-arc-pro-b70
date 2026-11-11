#!/usr/bin/env python3
"""Prefix-cache probe: long shared system prompt, different user turns, then a growing conversation.
Prints total latency and usage.cached_tokens per request."""
import argparse, json, os, random, time, urllib.request
ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8001)
ap.add_argument("--words", type=int, default=12000)
ap.add_argument("--model", default="qwen3.8-27b")
a = ap.parse_args()
key = os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip()
random.seed(int(time.time()))   # new prefix each run so the first request is always cold
W = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa".split()
sysmsg = "Reference notes (ignore unless asked): " + " ".join(random.choice(W) for _ in range(a.words))
def ask(msgs, label):
    body = {"model": a.model, "messages": msgs, "max_tokens": 8, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(f"http://localhost:{a.port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t = time.time(); r = json.load(urllib.request.urlopen(req, timeout=900)); dt = time.time() - t
    u = r["usage"]; c = (u.get("prompt_tokens_details") or {}).get("cached_tokens")
    print(f"{label:28s} {dt:6.2f}s  prompt {u['prompt_tokens']:6d}  cached {c}")
    return r["choices"][0]["message"].get("content") or ""
base = [{"role": "system", "content": sysmsg}]
ask(base + [{"role": "user", "content": "Reply with the word one."}], "cold")
ask(base + [{"role": "user", "content": "Reply with the word one."}], "identical repeat")
ask(base + [{"role": "user", "content": "Reply with the word two."}], "same prefix, new question")
conv = base + [{"role": "user", "content": "Reply with the word three."}]
ans = ask(conv, "conversation turn 1")
conv += [{"role": "assistant", "content": ans.strip() or "three"}, {"role": "user", "content": "Reply with the word four."}]
ask(conv, "conversation turn 2")
