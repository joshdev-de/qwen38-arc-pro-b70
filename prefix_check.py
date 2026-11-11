#!/usr/bin/env python3
"""Prefix-cache correctness check. A ~10k-token table of facts is the shared
prefix; each round asks about different rows, so every request after the first
reuses the cached prefix. Answers are compared to the known values. Also runs
the same question repeatedly to see whether cached runs drift from the cold one.
Prints the server's prefix-cache hit counters before/after when available."""
import argparse, json, os, random, re, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--url", default=None, help="full chat/completions URL (overrides --port), e.g. a gateway; /metrics is still read from vLLM on --port")
ap.add_argument("--metrics-key", default=None, help="key for vLLM /metrics (default: --key, or the vLLM key when --url is set)")
ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--rows", type=int, default=600)
ap.add_argument("--rounds", type=int, default=24)
a = ap.parse_args()
URL = a.url or f"http://localhost:{a.port}/v1/chat/completions"
MKEY = a.metrics_key or (open(os.path.expanduser("~/.config/vllm/api-key")).read().strip() if a.url else a.key)
r = random.Random(99)
first = ["Ana", "Ben", "Chen", "Dara", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun", "Kai", "Lea", "Mo", "Nia", "Omar", "Pia"]
last = ["Berg", "Cruz", "Dahl", "Ekko", "Funk", "Gray", "Holm", "Ito", "Juul", "Kern", "Lind", "Moss", "Nord", "Ortiz"]
depts = ["billing", "compilers", "storage", "network", "security", "payroll", "kernel", "graphics"]
rows, seen = [], set()
while len(rows) < a.rows:
    n = f"{r.choice(first)} {r.choice('ABCDEFGHJKLMNPRSTW')}. {r.choice(last)}"
    if n in seen:
        continue
    seen.add(n)
    rows.append((n, r.choice(depts), r.randint(10000, 99999)))
doc = "Staff directory (name | department | badge):\n" + "\n".join(f"{n} | {d} | {b}" for n, d, b in rows)


def ask(q):
    body = {"model": a.model, "temperature": 0, "max_tokens": 80, "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "system", "content": doc}, {"role": "user", "content": q}]}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {a.key}"})
    out = json.load(urllib.request.urlopen(req, timeout=600))
    return (out["choices"][0]["message"].get("content") or "").strip(), out["usage"]


def metrics():
    try:
        req = urllib.request.Request(f"http://localhost:{a.port}/metrics", headers={"Authorization": f"Bearer {MKEY}"})
        txt = urllib.request.urlopen(req, timeout=10).read().decode()
    except Exception:
        return {}
    m = {}
    for k in ("prefix_cache_queries_total", "prefix_cache_hits_total"):
        v = re.findall(rf"^vllm:{k}\{{[^}}]*\}} ([0-9.e+]+)", txt, re.M)
        if v:
            m[k] = float(v[0])
    return m


m0 = metrics()
ok = 0
for i in range(a.rounds):
    n, d, b = rows[r.randrange(len(rows))]
    got, u = ask(f"What is the badge number and department of {n}? Answer as: <badge> <department>")
    hit = str(b) in got and d in got.lower()
    ok += hit
    cached = (u.get("prompt_tokens_details") or {}).get("cached_tokens")
    print(f"{'OK  ' if hit else 'FAIL'} {n:12s} want {b} {d:10s} got {got[:60]!r}  prompt={u['prompt_tokens']} cached={cached}")
same = [ask("List the first five names in the directory, comma separated.")[0] for _ in range(4)]
m1 = metrics()
print(f"\nretrieval {ok}/{a.rounds}; repeated question identical across 4 runs: {len(set(same)) == 1}")
if len(set(same)) > 1:
    for s in same:
        print("   ", repr(s[:120]))
if m0 and m1 and m1["prefix_cache_queries_total"] > m0["prefix_cache_queries_total"]:
    q = m1["prefix_cache_queries_total"] - m0["prefix_cache_queries_total"]
    h = m1["prefix_cache_hits_total"] - m0["prefix_cache_hits_total"]
    print(f"prefix cache hit rate during test: {h / q:.1%}")
