#!/usr/bin/env python3
"""Streamed tool-call test: checks that tool calls arrive as structured
tool_calls deltas and do not leak into content/reasoning as raw XML."""
import argparse, json, os, re, time, urllib.request

TOOLS = [
    {"type": "function", "function": {"name": "get_weather", "description": "Get current weather for a city",
     "parameters": {"type": "object", "properties": {"city": {"type": "string"},
                    "unit": {"type": "string", "enum": ["c", "f"]}}, "required": ["city"]}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read a file from disk",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "run_shell", "description": "Run a shell command",
     "parameters": {"type": "object", "properties": {"cmd": {"type": "string"},
                    "timeout": {"type": "integer"}}, "required": ["cmd"]}}},
]
CASES = [
    ("single", "What's the weather in Berlin in celsius? Use the tool.", 1),
    ("parallel3", "In one turn, call get_weather for Paris, Tokyo and Lima (all at once, parallel calls).", 3),
    ("code-args", 'Run this exact shell command with a 30 second timeout: grep -rn "def main" src/ | head -n 5', 1),
    ("multi-tool", "Read the file /etc/hostname and also run `uname -a`. Do both now in parallel.", 2),
]
LEAK = re.compile(r"<tool_call>|</tool_call>|<function=|<parameter=")


def stream(args, messages, thinking):
    body = {"model": args.model, "stream": True, "temperature": 0.6, "max_tokens": 4000,
            "tools": TOOLS, "messages": messages,
            "chat_template_kwargs": {"enable_thinking": thinking}}
    req = urllib.request.Request(args.url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {args.key}"})
    content, reasoning, calls, finish = "", "", {}, None
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ch = json.loads(line[5:])["choices"]
            if not ch:
                continue
            d = ch[0].get("delta", {})
            finish = ch[0].get("finish_reason") or finish
            content += d.get("content") or ""
            reasoning += d.get("reasoning_content") or d.get("reasoning") or ""
            for tc in d.get("tool_calls") or []:
                c = calls.setdefault(tc["index"], {"name": "", "args": ""})
                f = tc.get("function") or {}
                c["name"] += f.get("name") or ""
                c["args"] += f.get("arguments") or ""
    return content, reasoning, calls, finish


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000/v1/chat/completions")
    ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--repeat", type=int, default=2)
    args = ap.parse_args()
    total = bad = 0
    for thinking in (True, False):
        for name, prompt, want in CASES:
            for i in range(args.repeat):
                total += 1
                t = time.time()
                content, reasoning, calls, finish = stream(args, [{"role": "user", "content": prompt}], thinking)
                problems = []
                if LEAK.search(content):
                    problems.append("XML leaked into content")
                if LEAK.search(reasoning):
                    problems.append("XML in reasoning")
                if len(calls) != want:
                    problems.append(f"{len(calls)} calls (want {want})")
                for c in calls.values():
                    try:
                        json.loads(c["args"])
                    except Exception:
                        problems.append(f"bad JSON args for {c['name']}: {c['args'][:80]!r}")
                if calls and finish != "tool_calls":
                    problems.append(f"finish_reason={finish}")
                bad += bool(problems)
                summary = "; ".join(f"{c['name']}({c['args']})" for c in calls.values())
                print(f"{'FAIL' if problems else 'OK  '} think={'on ' if thinking else 'off'} {name:10s} "
                      f"{time.time()-t:5.1f}s  {summary[:150]}")
                for p in problems:
                    print(f"       -> {p}")
                if problems and content:
                    print(f"       content: {content[:300]!r}")
    print(f"\n{total-bad}/{total} streamed cases clean")


if __name__ == "__main__":
    main()
