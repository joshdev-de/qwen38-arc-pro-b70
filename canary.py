#!/usr/bin/env python3
import argparse, json, urllib.request
QS = [
    ("sum(i*i for i in range(4))", "14"), ("9*7-3", "60"), ('len("hello world")', "11"),
    ("sum(x for x in range(10) if x % 3 == 0)", "18"), ("2**10 - 24", "1000"),
    ('"abcdef"[1:4]', "bcd"), ("sum(range(1, 11))", "55"), ('int("101", 2) + 1', "6"),
    ("17 % 5 * 3", "6"), ("len([n for n in range(20) if n % 2])", "10"),
    ("max([3, 9, 4]) - min([3, 9, 4])", "6"), ('"-".join(["a", "b", "c"])', "a-b-c"),
]
def ask(args, expr, thinking):
    kw = {"enable_thinking": thinking}
    if thinking and args.effort:
        kw["reasoning_effort"] = args.effort
    req = {"model": args.model, "temperature": 0, "max_tokens": 8000 if thinking else 50,
           "chat_template_kwargs": kw,
           "messages": [{"role": "user", "content": f"What does this Python expression evaluate to? {expr}\n"
                         "Reply with only the value, no quotes, no explanation."}]}
    r = urllib.request.Request(args.url, data=json.dumps(req).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {args.key}"})
    with urllib.request.urlopen(r, timeout=1200) as resp:
        msg = json.load(resp)["choices"][0]["message"]
    return (msg.get("content") or "").strip().strip("`'\" .")
ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
ap.add_argument("--key", default="change-me")
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--mode", default="both", choices=["off", "on", "both"])
ap.add_argument("--effort", choices=["low", "medium", "xhigh"],
                help="reasoning effort for thinking-on runs (default: the server's default)")
args = ap.parse_args()
for thinking in {"off": [False], "on": [True], "both": [False, True]}[args.mode]:
    ok = 0
    label = f"thinking {'on' if thinking else 'off'}" + (f", effort {args.effort}" if thinking and args.effort else "")
    print(f"--- {label} ---")
    for expr, want in QS:
        got = ask(args, expr, thinking); hit = got == want; ok += hit
        print(f"{'OK  ' if hit else 'FAIL'} {expr}  ->  {got!r}" + ("" if hit else f"  (want {want})"))
    print(f"score {ok}/{len(QS)}\n")
