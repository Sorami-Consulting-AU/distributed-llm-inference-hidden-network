#!/usr/bin/env python3
"""Write results.csv from the raw result-c*.json files. Stdlib only.

One row per run (layer x concurrency). Values are copied from the JSON summary
lines unchanged. Nothing is computed or rounded here.

Usage: python3 tools/build_results.py
"""
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "evidence" / "logs"
OUT = ROOT / "results.csv"

RUNS = [
    ("B", "single-GPU vLLM engine baseline (Stage B)", "2026-09-28-stageB-07-bench"),
    ("C", "two-node Ray pipeline-parallel baseline (Stage C)", "2026-09-28-stageC-06-bench"),
    ("L0", "Stage D L0 (byte-identical copy of the Stage C files)", "2026-09-28-stageD-00-L0"),
    ("L1", "ingress default-deny NetworkPolicy", "2026-09-28-stageD-01-L1"),
    ("L2a", "Linkerd mTLS (every request failed)", "2026-09-28-stageD-02-L2"),
    ("L3", "vLLM engine API key", "2026-09-28-stageD-03-L3"),
    ("L0-before", "L2b session, baseline before", "2026-09-28-stageD-04-L2-wireguard/bench-L0-before"),
    ("L2b", "Cilium chained on VPC CNI, WireGuard on", "2026-09-28-stageD-04-L2-wireguard/bench-L2b"),
    ("L0-after", "L2b session, baseline after", "2026-09-28-stageD-04-L2-wireguard/bench-L0-after"),
]
COLS = ["layer", "description", "concurrency", "requests", "ok", "failed", "wall_s", "req_per_s",
        "out_tok_per_s", "ttft_p50_ms", "ttft_p95_ms", "ttft_p99_ms", "tpot_p50_ms", "tpot_p95_ms",
        "tpot_p99_ms", "e2e_p50_ms", "e2e_p95_ms", "e2e_p99_ms", "source"]


def main():
    rows = []
    for layer, desc, folder in RUNS:
        for c in (1, 4, 16, 32):
            path = LOGS / folder / f"result-c{c}.json"
            d = json.loads(path.read_text())
            g = lambda k, p: d.get(k, {}).get(p, "")
            rows.append([layer, desc, d["concurrency"], d["requests"], d["ok"], d["failed"], d.get("wall_s", ""),
                         d.get("req_per_s", ""), d.get("out_tok_per_s", ""),
                         g("ttft_ms", "p50"), g("ttft_ms", "p95"), g("ttft_ms", "p99"),
                         g("tpot_ms", "p50"), g("tpot_ms", "p95"), g("tpot_ms", "p99"),
                         g("e2e_ms", "p50"), g("e2e_ms", "p95"), g("e2e_ms", "p99"),
                         f"evidence/logs/{folder}/result-c{c}.json"])
    with OUT.open("w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(COLS)
        w.writerows(rows)
    print(f"wrote {OUT} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
