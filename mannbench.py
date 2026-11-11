#!/usr/bin/env python3
"""Replica of Jonathan Mann's B70 benchmark shape: ~512-token prompt, 128
generated tokens, single streamed request, 1 warm-up + 5 measured runs,
client-side decode rate after the first token, median reported. His prompt is
not published, so three prompt kinds are run: 'count' (fully predictable, the
MTP best case), 'code' and 'prose'. Thinking off, temperature 0."""
import argparse, json, os, statistics, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--key", default=os.environ.get("VLLM_API_KEY") or open(os.path.expanduser("~/.config/vllm/api-key")).read().strip())
ap.add_argument("--model", default="qwen3.8-27b")
ap.add_argument("--tokens", type=int, default=128)
ap.add_argument("-r", type=int, default=5)
ap.add_argument("--tag", default="")
a = ap.parse_args()

CODE = '''import heapq, time, threading
from dataclasses import dataclass, field
from typing import Any, Callable, Optional


@dataclass(order=True)
class Job:
    run_at: float
    seq: int
    fn: Callable[..., Any] = field(compare=False)
    args: tuple = field(compare=False, default=())
    interval: Optional[float] = field(compare=False, default=None)
    cancelled: bool = field(compare=False, default=False)


class Scheduler:
    """A small thread-safe job scheduler with one-shot and periodic jobs."""

    def __init__(self) -> None:
        self._heap: list[Job] = []
        self._lock = threading.Lock()
        self._wake = threading.Condition(self._lock)
        self._seq = 0
        self._stop = False
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        with self._wake:
            self._stop = True
            self._wake.notify()
        self._thread.join()

    def call_later(self, delay: float, fn: Callable[..., Any], *args: Any) -> Job:
        return self._push(Job(time.monotonic() + delay, self._next_seq(), fn, args))

    def call_every(self, interval: float, fn: Callable[..., Any], *args: Any) -> Job:
        return self._push(Job(time.monotonic() + interval, self._next_seq(), fn, args, interval))

    def cancel(self, job: Job) -> None:
        with self._lock:
            job.cancelled = True

    def _next_seq(self) -> int:
        with self._lock:
            self._seq += 1
            return self._seq

    def _push(self, job: Job) -> Job:
        with self._wake:
            heapq.heappush(self._heap, job)
            self._wake.notify()
        return job

    def _loop(self) -> None:
        while True:
            with self._wake:
                while not self._stop and (not self._heap or self._heap[0].run_at > time.monotonic()):
                    timeout = self._heap[0].run_at - time.monotonic() if self._heap else None
                    self._wake.wait(timeout)
                if self._stop:
                    return
                job = heapq.heappop(self._heap)
            if job.cancelled:
                continue
            try:
                job.fn(*job.args)
            except Exception as exc:  # keep the loop alive
                print(f"job failed: {exc!r}")
            if job.interval is not None and not job.cancelled:
                job.run_at = time.monotonic() + job.interval
                self._push(job)
'''
PROSE = ("The history of container shipping begins in 1956, when a converted tanker carried fifty-eight metal "
         "boxes from Newark to Houston. Before that voyage, cargo was handled piece by piece: sacks, barrels and "
         "crates were lifted by gangs of longshoremen, stowed by hand, and unloaded the same way at the far end. "
         "A ship could spend as long in port as at sea, and theft and breakage were treated as ordinary costs. "
         "The container changed the economics rather than the physics. Loading cost fell from several dollars a "
         "ton to a few cents, ships turned around in hours, and ports that could not offer deep water, wide "
         "quays and rail links lost their trade to those that could. ") * 3
PROMPTS = {
    "count": "Here are the integers from 1 to 140, one per line:\n" + "\n".join(str(i) for i in range(1, 141))
             + "\n\nContinue this list from 141 upward, one integer per line, with no other text.",
    "code": "Here is a Python module:\n\n```python\n" + CODE + "```\n\nWrite a pytest test suite for it.",
    "prose": PROSE + "\n\nWrite a detailed essay continuing this account up to the present day.",
}


def run(prompt):
    body = {"model": a.model, "stream": True, "temperature": 0, "max_tokens": a.tokens, "ignore_eos": True,
            "stream_options": {"include_usage": True}, "chat_template_kwargs": {"enable_thinking": False},
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(f"http://localhost:{a.port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 method="POST", headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {a.key}"})
    t0 = time.time(); first = None; n = pt = 0
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            d = json.loads(line[5:])
            if d.get("usage"):
                n = d["usage"]["completion_tokens"]; pt = d["usage"]["prompt_tokens"]
            if d["choices"] and first is None and d["choices"][0]["delta"].get("content"):
                first = time.time()
    return (n - 1) / (time.time() - first), first - t0, pt


out = []
for k, p in PROMPTS.items():
    run(p)  # warm-up
    rs = [run(p) for _ in range(a.r)]
    v = [x[0] for x in rs]
    out.append(f"{k} {statistics.median(v):5.1f} (min {min(v):.1f} max {max(v):.1f}, {rs[0][2]} tok in, TTFT {statistics.median(x[1] for x in rs):.2f}s)")
print(f"mann {a.tag:14s} " + " | ".join(out))
