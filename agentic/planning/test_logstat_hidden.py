"""Hidden acceptance tests for logstat, written before any model output was seen. Run from the repo root."""
import gzip, json, subprocess, sys
import pytest

L = [
 '203.0.113.9 - alice [12/Nov/2026:13:55:36 +0000] "GET /api/items?id=3 HTTP/1.1" 200 2326 "-" "curl/8.5" 0.123',
 '203.0.113.9 - - [12/Nov/2026:13:55:37 +0000] "GET /api/items?id=4 HTTP/1.1" 200 100 "-" "curl/8.5" 0.200',
 '198.51.100.7 - - [12/Nov/2026:14:56:00 +0100] "POST /login HTTP/2.0" 302 - "https://example.org/" "Mozilla/5.0 (X11; Linux)"',
 '198.51.100.7 - - [12/Nov/2026:13:57:00 +0000] "GET /static/app.js HTTP/1.1" 404 512 "-" "Mozilla/5.0" 0.010',
 '192.0.2.1 - - [12/Nov/2026:13:58:00 +0000] "GET /api/items HTTP/1.1" 500 0 "-" "probe/1" 1.500',
 'this is not a log line',
 '192.0.2.1 - - [12/Nov/2026:13:59:00 +0000] "DELETE /api/items/7 HTTP/1.1" 503 10 "-" "-" 0.300',
]
KEYS = {"lines_total", "lines_malformed", "lines_matched", "bytes_total", "status", "status_classes", "methods",
        "top_paths", "top_clients", "latency", "first_ts", "last_ts"}

@pytest.fixture
def log(tmp_path):
    p = tmp_path / "access.log"; p.write_text("\n".join(L) + "\n"); return p

def run(*args, stdin=None):
    return subprocess.run([sys.executable, "-m", "logstat", *map(str, args)], capture_output=True, text=True, input=stdin, timeout=60)

def js(*args, stdin=None):
    r = run("--format", "json", *args, stdin=stdin)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)

def test_json_keys_exact(log): assert set(js(log)) == KEYS
def test_counts(log):
    d = js(log); assert (d["lines_total"], d["lines_malformed"], d["lines_matched"], d["bytes_total"]) == (7, 1, 6, 2948)
def test_status(log):
    d = js(log); assert d["status"] == {"200": 2, "302": 1, "404": 1, "500": 1, "503": 1}
    assert {k: v for k, v in d["status_classes"].items() if v} == {"2xx": 2, "3xx": 1, "4xx": 1, "5xx": 2}
def test_methods(log): assert js(log)["methods"] == {"GET": 4, "POST": 1, "DELETE": 1}
def test_top_paths(log):
    assert js(log)["top_paths"] == [{"path": "/api/items", "count": 3, "bytes": 2426}, {"path": "/api/items/7", "count": 1, "bytes": 10},
                                    {"path": "/login", "count": 1, "bytes": 0}, {"path": "/static/app.js", "count": 1, "bytes": 512}]
def test_top_clients_tie_alpha(log):
    assert js(log)["top_clients"] == [{"client": "192.0.2.1", "count": 2}, {"client": "198.51.100.7", "count": 2}, {"client": "203.0.113.9", "count": 2}]
def test_top_n(log):
    d = js("--top", 1, log); assert d["top_paths"] == [{"path": "/api/items", "count": 3, "bytes": 2426}] and len(d["top_clients"]) == 1
def test_latency(log):
    la = js(log)["latency"]; assert la["count"] == 5
    assert la["min"] == pytest.approx(0.010) and la["max"] == pytest.approx(1.5) and la["mean"] == pytest.approx(0.4266)
    assert la["p50"] == pytest.approx(0.200) and la["p95"] == pytest.approx(1.5) and la["p99"] == pytest.approx(1.5)
def test_timestamps_utc(log):
    d = js(log); assert d["first_ts"] == "2026-11-12T13:55:36Z" and d["last_ts"] == "2026-11-12T13:59:00Z"
def test_filter_status_mixed(log): assert js("--status", "5xx,404", log)["lines_matched"] == 3
def test_filter_method(log): assert js("--method", "POST,DELETE", log)["lines_matched"] == 2
def test_filter_prefix(log): assert js("--path-prefix", "/api", log)["lines_matched"] == 4
def test_since_inclusive_naive_is_utc(log): assert js("--since", "2026-11-12T13:56:00", log)["lines_matched"] == 4
def test_until_exclusive(log): assert js("--until", "2026-11-12T13:56:00Z", log)["lines_matched"] == 2
def test_since_with_offset(log): assert js("--since", "2026-11-12T14:57:00+01:00", log)["lines_matched"] == 3
def test_latency_null(log):
    d = js("--method", "POST", log); assert d["latency"] is None and d["lines_matched"] == 1 and d["bytes_total"] == 0
def test_no_match_nulls(log):
    d = js("--status", "418", log); assert d["lines_matched"] == 0 and d["first_ts"] is None and d["last_ts"] is None and d["latency"] is None
def test_stdin(log): assert js("-", stdin=log.read_text())["lines_matched"] == 6
def test_gzip_and_multiple(log, tmp_path):
    g = tmp_path / "old.log.gz"
    with gzip.open(g, "wt") as f: f.write("\n".join(L[:2]) + "\n")
    d = js(g, log); assert d["lines_total"] == 9 and d["lines_matched"] == 8 and d["top_paths"][0]["count"] == 5
def test_strict(log):
    r = run("--strict", log); assert r.returncode == 2 and "6" in r.stderr and "access.log" in r.stderr
def test_missing_file(tmp_path): assert run(tmp_path / "nope.log").returncode == 1
def test_usage_error(log): assert run("--format", "xml", log).returncode == 2
def test_bad_timestamp_is_usage_error(log): assert run("--since", "yesterday-ish", log).returncode == 2
def test_text_output(log):
    r = run(log); assert r.returncode == 0 and "/api/items" in r.stdout and "503" in r.stdout
def test_escaped_quote_in_user_agent(tmp_path):
    p = tmp_path / "q.log"
    p.write_text('192.0.2.1 - - [12/Nov/2026:13:58:00 +0000] "GET /a HTTP/1.1" 200 5 "-" "x \\"quoted\\" agent" 0.5\n')
    d = js(p); assert d["lines_matched"] == 1 and d["lines_malformed"] == 0 and d["latency"]["count"] == 1
def test_empty_file(tmp_path):
    p = tmp_path / "e.log"; p.write_text(""); d = js(p); assert d["lines_total"] == 0 and d["top_paths"] == []
