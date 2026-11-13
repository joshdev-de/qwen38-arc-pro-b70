#!/usr/bin/env python3
"""usage.py <tag>: per-job gateway usage (requests, input, output, reasoning tokens, model time) from the agentgateway log."""
import sqlite3, subprocess, sys, re
vol = subprocess.run(["podman","volume","inspect","agentgateway-data","--format","{{.Mountpoint}}"],capture_output=True,text=True).stdout.strip()
c = sqlite3.connect(f"file:{vol}/agentgateway.db?mode=ro", uri=True)
for line in open(f"/home/fedora/bench/delegate/{sys.argv[1]}/summary.txt"):
    m = dict(x.split("=",1) for x in line.split() if "=" in x); n = line.split()[0]
    r = c.execute("""select count(*), sum(input_tokens), sum(output_tokens), sum(coalesce(reasoning_tokens,0)), sum(reasoning_tokens is not null),
        round(sum(duration_ms)/1000.0), sum(http_status != 200), sum(coalesce(cache_read_input_tokens,0)) from request_logs
        where agentgateway_user=? and started_at >= ? and started_at <= ?""", (m["agent"], m["start"], m["end"]+"Z")).fetchone()
    print(f"{n:11s} secs={m['secs']:>4s} requests={r[0]} in={r[1]} out={r[2]} reasoning={r[3]} (rows with value {r[4]}) model_time={r[5]}s errors={r[6]} cache_read={r[7]}")
