"""Stdlib-only streaming load generator for an OpenAI-compatible endpoint.

Stdlib only so it runs on python:slim with no pip install, which keeps the
client identical across every hardening layer in Stage D. Any difference in
numbers then comes from the network path, not the client.

Usage: python bench.py <base_url> <concurrency> <requests> <out.json>
"""
import json
import statistics
import sys
import threading
import time
import urllib.request

BASE, CONC, N, OUT = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
# Model tag must match the served model or vLLM returns 404. Stage B served the
# 7B model; Stage C serves 1.5B to fit the 16GB T4. Only the tag changes; the
# request shape, streaming, and token accounting stay byte-identical so the
# client is not a variable across stages or across the L0..L3 layers.
import os
MODEL = os.environ.get("BENCH_MODEL", "Qwen/Qwen2.5-7B-Instruct")
# L3 bearer token. Empty for L0..L2 so the request is unauthenticated as before.
API_KEY = os.environ.get("BENCH_API_KEY", "")
# Fixed prompt and max_tokens with temperature 0 so each request has the same
# prefill and decode work; variance then reflects the transport, not the load.
PROMPT = "Write a short paragraph about the history of distributed computing. " * 8
MAX_TOKENS = 128

results, lock = [], threading.Lock()
counter = iter(range(N))


def one():
    body = json.dumps({
        "model": MODEL, "prompt": PROMPT, "max_tokens": MAX_TOKENS,
        "temperature": 0, "stream": True, "ignore_eos": True,
        # Server-side token count: SSE chunks are not guaranteed 1:1 with
        # tokens (vLLM can coalesce chunks and appends a usage-only chunk),
        # so counting chunks would skew tpot and out_tok_per_s.
        "stream_options": {"include_usage": True},
    }).encode()
    headers = {"Content-Type": "application/json"}
    # L3 layer serves with --api-key, so the client must present the bearer
    # token. Unset for L0..L2 so the request shape is otherwise unchanged.
    if API_KEY:
        headers["Authorization"] = "Bearer " + API_KEY
    req = urllib.request.Request(BASE + "/v1/completions", body, headers)
    t0 = time.perf_counter()
    ttft, chunks, usage_toks = None, 0, None
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            for line in r:
                if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]":
                    continue
                ev = json.loads(line[6:])
                if ev.get("usage"):
                    usage_toks = ev["usage"].get("completion_tokens")
                if not any(c.get("text") for c in ev.get("choices") or []):
                    continue
                # TTFT is the first chunk carrying generated text, not the
                # usage-only or empty keepalive chunks.
                if ttft is None:
                    ttft = time.perf_counter() - t0
                chunks += 1
        e2e = time.perf_counter() - t0
        if ttft is None:
            raise RuntimeError("stream ended with no text chunks")
        toks = usage_toks if usage_toks is not None else chunks
        rec = {"ok": True, "ttft": ttft, "e2e": e2e, "tokens": toks,
               "tpot": (e2e - ttft) / max(toks - 1, 1)}
    except Exception as ex:  # record failures instead of aborting the run
        rec = {"ok": False, "err": repr(ex)[:200], "e2e": time.perf_counter() - t0}
    with lock:
        results.append(rec)


def worker():
    while True:
        with lock:
            i = next(counter, None)
        if i is None:
            return
        one()


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else None


start = time.perf_counter()
ts = [threading.Thread(target=worker) for _ in range(CONC)]
for t in ts:
    t.start()
for t in ts:
    t.join()
wall = time.perf_counter() - start

ok = [r for r in results if r["ok"]]
summary = {
    "base": BASE, "concurrency": CONC, "requests": N, "ok": len(ok),
    "failed": len(results) - len(ok), "wall_s": round(wall, 2),
    "max_tokens": MAX_TOKENS,
    "req_per_s": round(len(ok) / wall, 3),
    "out_tok_per_s": round(sum(r["tokens"] for r in ok) / wall, 1),
}
for k in ("ttft", "tpot", "e2e"):
    xs = [r[k] for r in ok if r.get(k) is not None]
    if xs:
        summary[k + "_ms"] = {
            "p50": round(pct(xs, 50) * 1000, 1),
            "p95": round(pct(xs, 95) * 1000, 1),
            "p99": round(pct(xs, 99) * 1000, 1),
            "mean": round(statistics.mean(xs) * 1000, 1),
        }
summary["errors"] = sorted({r["err"] for r in results if not r["ok"]})[:5]
with open(OUT, "w") as f:
    json.dump({"summary": summary, "raw": results}, f)
print(json.dumps(summary))
