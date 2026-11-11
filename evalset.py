#!/usr/bin/env python3
"""Harder exact-answer eval for comparing quants. Generates a fixed, seeded set
of Python expressions (answers computed by eval), asks the model for the value,
runs with thinking off and/or on, P requests in parallel.

  python3 evalset.py --url http://localhost:8001/v1/chat/completions --tag q4km
Results go to results/<tag>.json."""
import argparse, json, os, random, time, urllib.request
from concurrent.futures import ThreadPoolExecutor


def gen(n=80, seed=1234, hard=False):
    r = random.Random(seed)
    words = ["apple", "kiwi", "banana", "fig", "cherry", "date", "grape", "lemon", "mango", "pear"]
    T = [
        lambda: f"sum(i*i for i in range({r.randint(5, 15)}) if i % {r.randint(2, 4)} == {r.randint(0, 1)})",
        lambda: f"len([x for x in range({r.randint(20, 80)}) if x % {r.randint(3, 7)} == 0 or x % {r.randint(5, 11)} == 0])",
        lambda: f"sorted({r.sample(words, 5)}, key=len)[{r.randint(0, 4)}]",
        lambda: f"'{r.choice(words)}{r.choice(words)}'[::{r.choice([-1, 2, -2, 3])}]",
        lambda: f"sum(map(int, str({r.randint(10**6, 10**8)})))",
        lambda: f"{r.randint(100, 999)} // {r.randint(7, 31)} + {r.randint(100, 999)} % {r.randint(7, 31)}",
        lambda: f"bin({r.randint(50, 500)}).count('1')",
        lambda: f"{r.randint(3, 12)} ** {r.randint(2, 4)} - {r.randint(10, 99)} * {r.randint(2, 9)}",
        lambda: f"len(set('{''.join(r.choice('abcdefgh') for _ in range(r.randint(10, 18)))}'))",
        lambda: f"max({r.sample(range(1, 60), 6)}, key=lambda v: v % {r.randint(5, 13)})",
        lambda: f"[x * {r.randint(2, 5)} for x in range({r.randint(3, 6)}) if x != {r.randint(1, 3)}][-{r.randint(1, 2)}]",
        lambda: f"{{k: len(k) for k in {r.sample(words, 4)}}}['{{}}']".format(""),  # placeholder, replaced below
        lambda: f"'{r.choice(words)}'.upper().replace('{r.choice('AEIOU')}', '{r.choice('xyz')}')",
        lambda: f"sum(range({r.randint(1, 20)}, {r.randint(30, 90)}, {r.randint(2, 7)}))",
        lambda: f"int('{r.randint(100, 777):o}', 8) - {r.randint(10, 99)}",
        lambda: f"({r.randint(10, 99)} ^ {r.randint(10, 99)}) & {r.randint(30, 127)}",
        lambda: f"'-'.join(sorted('{''.join(r.sample('qwertyuiop', 6))}'))",
        lambda: f"len('{' '.join(r.choices(words, k=r.randint(3, 6)))}'.split('a'))",
        lambda: f"sum(1 for c in '{' '.join(r.choices(words, k=4))}' if c in 'aeiou')",
        lambda: f"[1, 1, 2, 3, 5, 8, 13, 21, 34][{r.randint(1, 4)}:{r.randint(5, 8)}][{r.randint(0, 2)}]",
    ]
    out, seen = [], set()
    while len(out) < n:
        i = r.randrange(len(T))
        if i == 11:
            ks = r.sample(words, 4)
            e = f"sum({{k: len(k) for k in {ks}}}.values()) - len('{r.choice(ks)}')"
        else:
            e = T[i]()
        if e in seen:
            continue
        try:
            v = eval(e)
        except Exception:
            continue
        seen.add(e)
        out.append((e, str(v)))
    if hard:   # chain three integer-valued questions into one expression
        nums = [e for e, v in out if v.lstrip('-').isdigit()]
        out = []
        for j in range(0, len(nums) - 2, 3):
            e = f"({nums[j]}) + ({nums[j + 1]}) * ({nums[j + 2]})"
            out.append((e, str(eval(e))))
    return out


def ask(args, expr, thinking):
    kw = {"enable_thinking": thinking}
    if thinking:
        kw["reasoning_effort"] = args.effort
    body = {"model": args.model, "temperature": 0, "max_tokens": 12000 if thinking else 60,
            "chat_template_kwargs": kw,
            "messages": [{"role": "user", "content": f"What does this Python expression evaluate to? {expr}\n"
                          "Reply with only the value (as Python would print it), no quotes around the whole answer, no explanation."}]}
    req = urllib.request.Request(args.url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {args.key}"})
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            out = json.load(r)
    except Exception as e:
        return f"ERROR {e}", 0
    got = (out["choices"][0]["message"].get("content") or "").strip().strip("`").strip()
    if len(got) >= 2 and got[0] == got[-1] and got[0] in "'\"":
        got = got[1:-1]
    return got, out["usage"]["completion_tokens"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
    ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--mode", default="both", choices=["off", "on", "both"])
    ap.add_argument("--effort", default="low", choices=["low", "medium", "xhigh"])
    ap.add_argument("-p", type=int, default=4)
    ap.add_argument("-n", type=int, default=80)
    ap.add_argument("--hard", action="store_true", help="chained three-part expressions")
    args = ap.parse_args()
    qs = gen(args.n * 5 if args.hard else args.n, hard=args.hard)[:args.n]
    os.makedirs("results", exist_ok=True)
    report = {"tag": args.tag}
    for thinking in {"off": [False], "on": [True], "both": [False, True]}[args.mode]:
        t = time.time()
        with ThreadPoolExecutor(args.p) as ex:
            res = list(ex.map(lambda q: ask(args, q[0], thinking), qs))
        rows = [{"expr": e, "want": w, "got": g, "ok": g == w, "tokens": n} for (e, w), (g, n) in zip(qs, res)]
        ok = sum(x["ok"] for x in rows)
        key = "think_on" if thinking else "think_off"
        report[key] = {"score": ok, "n": len(rows), "secs": round(time.time() - t),
                       "tokens": sum(x["tokens"] for x in rows), "rows": rows}
        print(f"{args.tag} {key}: {ok}/{len(rows)}  ({time.time() - t:.0f}s, {report[key]['tokens']} completion tokens)")
    json.dump(report, open(f"results/{args.tag}.json", "w"), indent=1)


if __name__ == "__main__":
    main()
