#!/usr/bin/env python3
"""Concurrent correctness + stability test. Fires canary questions (thinking on,
temperature 0) from P parallel clients, mixed with long-prompt requests that
force chunked prefill while others decode. Reports wrong answers, errors and
per-request decode speed."""
import argparse, json, os, random, statistics, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

QS = [
    ("sum(i*i for i in range(4))", "14"), ("9*7-3", "60"), ('len("hello world")', "11"),
    ("sum(x for x in range(10) if x % 3 == 0)", "18"), ("2**10 - 24", "1000"),
    ('"abcdef"[1:4]', "bcd"), ("sum(range(1, 11))", "55"), ('int("101", 2) + 1', "6"),
    ("17 % 5 * 3", "6"), ("len([n for n in range(20) if n % 2])", "10"),
    ("max([3, 9, 4]) - min([3, 9, 4])", "6"), ('"-".join(["a", "b", "c"])', "a-b-c"),
]


def post(args, body):
    req = urllib.request.Request(args.url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {args.key}"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        out = json.load(r)
    return out, time.time() - t


def job(args, i):
    rnd = random.Random(i)
    if i % 4 == 3:  # long-prompt job: needle in ~N tokens of filler
        secret = rnd.randint(10000, 99999)
        words = " ".join(rnd.choice(["alpha", "bravo", "delta", "echo", "kilo", "lima"]) for _ in range(args.filler))
        half = len(words) // 2
        text = words[:half] + f" The secret number is {secret}. " + words[half:]
        body = {"model": args.model, "temperature": 0, "max_tokens": 8000,
                "messages": [{"role": "user", "content": text + "\n\nWhat is the secret number? Reply with only the number."}]}
        want, label = str(secret), f"needle@{args.filler}w"
    else:
        expr, want = QS[i % len(QS)]
        body = {"model": args.model, "temperature": 0, "max_tokens": 8000,
                "messages": [{"role": "user", "content": f"What does this Python expression evaluate to? {expr}\n"
                              "Reply with only the value, no quotes, no explanation."}]}
        label = expr
    try:
        out, dt = post(args, body)
    except Exception as e:
        return label, False, f"ERROR {e}", 0, 0
    got = (out["choices"][0]["message"].get("content") or "").strip().strip("`'\" .")
    ntok = out["usage"]["completion_tokens"]
    return label, got == want, got if got != want else "", ntok, dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
    ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("-n", type=int, default=24, help="total requests")
    ap.add_argument("-p", type=int, default=2, help="parallel clients")
    ap.add_argument("--filler", type=int, default=12000, help="filler words in long-prompt jobs")
    args = ap.parse_args()
    t0 = time.time()
    lock = threading.Lock()
    res = []
    with ThreadPoolExecutor(args.p) as ex:
        for r in ex.map(lambda i: job(args, i), range(args.n)):
            label, ok, info, ntok, dt = r
            res.append(r)
            with lock:
                print(f"{'OK  ' if ok else 'FAIL'} {label:42s} {ntok:5d} tok {dt:6.1f}s {info}", flush=True)
    wall = time.time() - t0
    ok = sum(r[1] for r in res)
    toks = sum(r[3] for r in res)
    print(f"\n{ok}/{len(res)} correct, {args.p} parallel, wall {wall:.0f}s, "
          f"aggregate {toks / wall:.1f} completion tok/s")


if __name__ == "__main__":
    main()
