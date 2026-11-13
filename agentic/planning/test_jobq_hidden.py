"""Hidden acceptance tests for jobq, written before any model output was seen. Run from the repo root."""
import json, os, signal, socket, subprocess, sys, threading, time, urllib.error, urllib.request
import pytest

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

class Srv:
    def __init__(self, db): self.db, self.port, self.p = str(db), free_port(), None
    def start(self):
        self.p = subprocess.Popen([sys.executable, "-m", "jobq", "serve", "--db", self.db, "--port", str(self.port)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                if self.call("GET", "/healthz")[0] == 200: return self
            except Exception: time.sleep(0.1)
        raise RuntimeError("server did not start")
    def kill9(self): self.p.send_signal(signal.SIGKILL); self.p.wait()
    def stop(self):
        if self.p and self.p.poll() is None: self.p.terminate(); self.p.wait(timeout=10)
    def call(self, method, path, body=None, raw=None, timeout=30):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r: return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            b = e.read()
            try: return e.code, json.loads(b)
            except Exception: return e.code, None
    def enq(self, q="q", **kw): kw.setdefault("payload", {"n": 1}); return self.call("POST", f"/queues/{q}/jobs", kw)
    def lease(self, q="q", **kw): kw.setdefault("worker", "w"); return self.call("POST", f"/queues/{q}/lease", kw)[1]["jobs"]
    def state(self, i): return self.call("GET", f"/jobs/{i}")[1]["state"]

@pytest.fixture
def s(tmp_path):
    x = Srv(tmp_path / "q.db").start(); yield x; x.stop()

def test_health(s): assert s.call("GET", "/healthz") == (200, {"ok": True})
def test_enqueue_and_get(s):
    c, j = s.enq(payload={"a": [1, None, {"b": "x"}]}, priority=2)
    assert c == 201 and j["state"] == "ready"
    c, g = s.call("GET", f"/jobs/{j['id']}")
    assert c == 200 and g["payload"] == {"a": [1, None, {"b": "x"}]} and g["queue"] == "q" and g["priority"] == 2
    assert g["attempts"] == 0 and g["max_attempts"] == 3 and g["last_error"] is None and g["idempotency_key"] is None
def test_lease_ack(s):
    i = s.enq()[1]["id"]; (j,) = s.lease()
    assert j["id"] == i and j["attempt"] == 1 and j["payload"] == {"n": 1} and j["lease_token"] and j["lease_expires_at"]
    assert s.state(i) == "leased" and s.lease() == []
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": j["lease_token"]})[0] == 200
    assert s.state(i) == "done" and s.call("GET", "/queues/q/stats")[1] == {"ready": 0, "delayed": 0, "leased": 0, "done": 1, "dead": 0}
def test_priority_then_fifo(s):
    a = s.enq(payload=1)[1]["id"]; b = s.enq(payload=2, priority=5)[1]["id"]; c = s.enq(payload=3)[1]["id"]; d = s.enq(payload=4, priority=5)[1]["id"]
    assert [j["id"] for j in s.lease(max_jobs=4)] == [b, d, a, c]
def test_max_jobs(s):
    for _ in range(5): s.enq()
    assert len(s.lease(max_jobs=3)) == 3 and len(s.lease(max_jobs=10)) == 2
def test_idempotency(s):
    c1, j1 = s.enq(idempotency_key="k"); c2, j2 = s.enq(idempotency_key="k", payload="other"); c3, j3 = s.enq(q="other", idempotency_key="k")
    assert (c1, c2, c3) == (201, 200, 201) and j1["id"] == j2["id"] != j3["id"]
    assert s.call("GET", "/queues/q/stats")[1]["ready"] == 1
def test_delay(s):
    i = s.enq(delay_seconds=2)[1]["id"]
    assert s.state(i) == "delayed" and s.lease() == []
    time.sleep(2.3); assert [j["id"] for j in s.lease()] == [i]
def test_lease_expiry_releases_and_old_token_fails(s):
    i = s.enq()[1]["id"]; (j,) = s.lease(lease_seconds=1); time.sleep(1.4)
    assert s.state(i) == "ready"
    (j2,) = s.lease(); assert j2["id"] == i and j2["attempt"] == 2 and j2["lease_token"] != j["lease_token"]
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": j["lease_token"]})[0] == 409
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": j2["lease_token"]})[0] == 200
def test_ack_after_expiry_is_409(s):
    i = s.enq()[1]["id"]; (j,) = s.lease(lease_seconds=1); time.sleep(1.4)
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": j["lease_token"]})[0] == 409
def test_nack_until_dead(s):
    i = s.enq(max_attempts=2)[1]["id"]
    (j,) = s.lease(); assert s.call("POST", f"/jobs/{i}/nack", {"lease_token": j["lease_token"], "error": "boom"})[0] == 200
    g = s.call("GET", f"/jobs/{i}")[1]; assert g["state"] == "ready" and g["last_error"] == "boom" and g["attempts"] == 1
    (j,) = s.lease(); assert j["attempt"] == 2
    s.call("POST", f"/jobs/{i}/nack", {"lease_token": j["lease_token"], "error": "again"})
    assert s.state(i) == "dead" and s.lease() == [] and s.call("GET", "/queues/q/stats")[1]["dead"] == 1
def test_expiry_counts_as_attempt(s):
    i = s.enq(max_attempts=1)[1]["id"]; s.lease(lease_seconds=1); time.sleep(1.4)
    assert s.state(i) == "dead" and s.lease() == []
def test_nack_retry_delay(s):
    i = s.enq()[1]["id"]; (j,) = s.lease()
    s.call("POST", f"/jobs/{i}/nack", {"lease_token": j["lease_token"], "retry_delay_seconds": 2})
    assert s.state(i) == "delayed" and s.lease() == []
    time.sleep(2.3); assert len(s.lease()) == 1
def test_heartbeat_extends(s):
    i = s.enq()[1]["id"]; (j,) = s.lease(lease_seconds=1)
    assert s.call("POST", f"/jobs/{i}/heartbeat", {"lease_token": j["lease_token"], "lease_seconds": 5})[0] == 200
    time.sleep(1.5); assert s.state(i) == "leased" and s.lease() == []
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": j["lease_token"]})[0] == 200
def test_heartbeat_wrong_token(s):
    i = s.enq()[1]["id"]; s.lease()
    assert s.call("POST", f"/jobs/{i}/heartbeat", {"lease_token": "nope", "lease_seconds": 5})[0] == 409
def test_errors(s):
    i = s.enq()[1]["id"]
    for c, b in (s.call("POST", f"/jobs/{i}/ack", {"lease_token": "x"}), s.call("GET", "/jobs/does-not-exist-123456"), s.call("GET", "/nothing/here"),
                 s.call("POST", "/queues/q/jobs", raw=b"{not json"), s.call("POST", "/queues/q/jobs", {"payload": 1, "max_attempts": "many"}),
                 s.call("POST", "/queues/q/lease", {"worker": "w", "lease_seconds": -5})):
        assert isinstance(b, dict) and "error" in b
    assert s.call("POST", f"/jobs/{i}/ack", {"lease_token": "x"})[0] == 409
    assert s.call("GET", "/jobs/does-not-exist-123456")[0] == 404 and s.call("GET", "/nothing/here")[0] == 404
    assert s.call("POST", "/queues/q/jobs", raw=b"{not json")[0] == 400
    assert s.call("POST", "/queues/q/jobs", {"payload": 1, "max_attempts": "many"})[0] == 400
    assert s.call("POST", "/queues/q/lease", {"worker": "w", "lease_seconds": -5})[0] == 400
def test_missing_payload_is_400(s): assert s.call("POST", "/queues/q/jobs", {"priority": 1})[0] == 400
def test_queues_are_separate(s):
    s.enq(q="a"); assert s.lease(q="b") == [] and len(s.lease(q="a")) == 1
def test_concurrent_leases_never_duplicate(s):
    n = 120
    for k in range(n): s.enq(payload=k)
    got, lock = [], threading.Lock()
    def worker(w):
        while True:
            js = s.lease(worker=f"w{w}", max_jobs=3, lease_seconds=60)
            if not js: return
            with lock: got.extend(j["id"] for j in js)
    ts = [threading.Thread(target=worker, args=(w,)) for w in range(8)]
    [t.start() for t in ts]; [t.join(120) for t in ts]
    assert len(got) == n and len(set(got)) == n
def test_long_poll_wakes_on_enqueue(s):
    out = {}
    def waiter(): t = time.time(); out["jobs"] = s.lease(wait_seconds=6); out["dt"] = time.time() - t
    t = threading.Thread(target=waiter); t.start(); time.sleep(1.0); i = s.enq()[1]["id"]; t.join(15)
    assert [j["id"] for j in out["jobs"]] == [i] and 0.8 <= out["dt"] < 4.0
def test_long_poll_times_out_empty(s):
    t = time.time(); assert s.lease(wait_seconds=2) == []; assert 1.7 <= time.time() - t < 5
def test_survives_kill9(tmp_path):
    x = Srv(tmp_path / "p.db").start()
    try:
        a = x.enq(payload="a")[1]["id"]; b = x.enq(payload="b", priority=9)[1]["id"]; c = x.enq(payload="c", delay_seconds=3600)[1]["id"]
        d = x.enq(payload="d", priority=8)[1]["id"]
        (jb,) = x.lease(lease_seconds=120); assert jb["id"] == b
        (jd,) = x.lease(lease_seconds=2); assert jd["id"] == d
        x.kill9(); time.sleep(2.2); x.start()
        assert x.state(a) == "ready" and x.state(b) == "leased" and x.state(c) == "delayed"
        assert x.call("GET", f"/jobs/{b}")[1]["payload"] == "b"
        (again,) = x.lease(); assert again["id"] == d and again["attempt"] == 2          # its lease ran out while the server was down
        assert x.call("POST", f"/jobs/{b}/ack", {"lease_token": jb["lease_token"]})[0] == 200   # the old lease is still valid
        assert x.call("GET", "/queues/q/stats")[1] == {"ready": 1, "delayed": 1, "leased": 1, "done": 1, "dead": 0}
    finally: x.stop()
def test_cli_help():
    assert subprocess.run([sys.executable, "-m", "jobq", "--help"], capture_output=True, timeout=30).returncode == 0
