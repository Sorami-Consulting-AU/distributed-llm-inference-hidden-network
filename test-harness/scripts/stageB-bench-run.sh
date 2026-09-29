#!/usr/bin/env bash
# Stage B baseline bench + GPU/metrics capture. Reuses stageB-resume.sh logic
# minus the node-group branch, which would recycle the only working GPU node.
set -uo pipefail
source test-harness/.aws-session.env
source test-harness/scripts/lib.sh
guard || exit 99
ROOT=test-harness
R=${LOGS:-logs}/2026-09-28-stageB-07-bench; mkdir -p "$R"
ENGSVC=http://sorami-lab-vllm-engine.sorami-lab-stack-vllm.svc.cluster.local:8000
M(){ $K -n sorami-lab-stack-vllm exec $POD -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())" | grep -E '^vllm:'; }
POD=$($K -n sorami-lab-stack-vllm get pod -l app=sorami-lab-vllm-engine -o jsonpath='{.items[0].metadata.name}')
log 00-target "echo pod=$POD svc=$ENGSVC; $K -n sorami-lab-stack-vllm get pod $POD -o wide; $K get node -l sorami-lab/pool=gpu -L node.kubernetes.io/instance-type,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone"
log 01-metrics-before "M"
log 02-nvidia-smi-idle "$K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi"
log 02b-vllm-kvcache "$K -n sorami-lab-stack-vllm logs $POD | grep -E 'KV cache|Maximum concurrency|max_model_len|Loading weights took|Model loading took|non-default args'"
$K -n sorami-lab-neighbor create configmap sorami-lab-bench --from-file=bench.py=$ROOT/bench/bench.py --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n sorami-lab-neighbor delete job sorami-lab-bench-baseline --ignore-not-found >/dev/null
log 03-apply-job "$K apply -f $ROOT/manifests/stageB-bench-job.yaml"
( while ! $K -n sorami-lab-neighbor get job sorami-lab-bench-baseline -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'; do
    echo "# UTC $(date -u +%FT%TZ)"
    $K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu --format=csv,noheader
    sleep 20; done ) > "$R/04-nvidia-smi-load.csv.log" 2>&1 &
SAMPLER=$!
sleep 90
log 05-metrics-during "M"
log 06-nvidia-smi-during "$K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi"
log 07-job-wait "$K -n sorami-lab-neighbor wait --for=condition=complete job/sorami-lab-bench-baseline --timeout=3600s"
wait $SAMPLER
log 08-job-logs "$K -n sorami-lab-neighbor logs job/sorami-lab-bench-baseline"
log 09-metrics-after "M"
grep '^RESULT' "$R/08-job-logs.log" | while read -r _ c json; do echo "$json" > "$R/result-c${c#c=}.json"; done
python3 - "$R" <<'EOF' > "$R/10-table.md"
import json, glob, sys, os
print("Label: baseline (no NetworkPolicy, no mTLS, no TLS)\n")
print("| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |")
print("|---|---|---|---|---|---|---|")
for f in sorted(glob.glob(os.path.join(sys.argv[1], "result-c*.json")), key=lambda p:int(p.rsplit("-c",1)[-1][:-5])):
    s=json.load(open(f)); g=lambda k:" / ".join(str(s.get(k+"_ms",{}).get(p,"-")) for p in ("p50","p95","p99"))
    print(f"| {s['concurrency']} | {s['ok']}/{s['requests']} | {s['req_per_s']} | {s['out_tok_per_s']} | {g('ttft')} | {g('tpot')} | {g('e2e')} |")
EOF
redact
echo BENCH_DONE
