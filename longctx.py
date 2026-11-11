#!/usr/bin/env python3
"""Long-context retrieval check: hides 3 facts at different depths in ~N tokens
of varied filler and asks for all of them (thinking off, temperature 0)."""
import argparse, json, os, random, time, urllib.request
ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--tokens", type=int, default=150000)
ap.add_argument("--seed", type=int, default=7)
a = ap.parse_args()
rnd = random.Random(a.seed)
subj = ["The server", "A compiler", "The scheduler", "Our parser", "The cache", "Each worker", "The router"]
verb = ["flushes", "rebuilds", "validates", "compresses", "logs", "retries", "serializes"]
obj = ["the index", "every packet", "stale entries", "the manifest", "pending jobs", "the config", "user sessions"]
tail = ["at midnight.", "after a timeout.", "on startup.", "when idle.", "under load.", "before shutdown."]
sents = [f"{rnd.choice(subj)} {rnd.choice(verb)} {rnd.choice(obj)} {rnd.choice(tail)}" for _ in range(a.tokens // 7)]
facts = {"Rotterdam": f"The vault code for Rotterdam is {rnd.randint(1000,9999)}.",
         "Quito": f"The vault code for Quito is {rnd.randint(1000,9999)}.",
         "Osaka": f"The vault code for Osaka is {rnd.randint(1000,9999)}."}
for frac, f in zip((0.1, 0.5, 0.9), facts.values()):
    sents.insert(int(len(sents) * frac), f)
q = "\n\nList the vault codes for Rotterdam, Quito and Osaka as city=code, comma separated, nothing else."
body = {"model": a.model, "temperature": 0, "max_tokens": 60, "chat_template_kwargs": {"enable_thinking": False},
        "messages": [{"role": "user", "content": " ".join(sents) + q}]}
req = urllib.request.Request(a.url, data=json.dumps(body).encode(), method="POST",
                             headers={"Content-Type": "application/json", "Authorization": f"Bearer {a.key}"})
t = time.time()
out = json.load(urllib.request.urlopen(req, timeout=3600))
got = out["choices"][0]["message"]["content"]
want = {c: f.split()[-1].rstrip(".") for c, f in facts.items()}
hits = sum(f"{c}={v}" in got.replace(" ", "") for c, v in want.items())
print(f"prompt {out['usage']['prompt_tokens']} tok, {time.time()-t:.0f}s, got {got!r}, want {want}, {hits}/3")
