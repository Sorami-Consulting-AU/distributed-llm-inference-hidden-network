#!/usr/bin/env bash
# Stage C distributed benchmark. Same client and sweep as Stage B so the method
# is identical, but the target is the Ray-backed PP=2 engine served on the head
# pod (A10G, PP stage 0) with the T4 worker as PP stage 1. GPU sampling runs on
# BOTH nodes because load is split across the pipeline. Output feeds the Stage D
# hardening-tax deltas; only within-stage numbers are comparable.
set -uo pipefail
source test-harness/.aws-session.env
source test-harness/scripts/lib.sh
guard || exit 99
ROOT=test-harness
# Caller passes the log dir + label so the same script serves L0..L3.
R="${1:?log dir}"; LABEL="${2:?label}"; mkdir -p "$R"
NS=sorami-lab-stack-vllm
# The Ray head OpenAI service is the stable in-cluster endpoint for the engine.
ENGSVC=http://sorami-lab-vllm-ray-openai.${NS}.svc.cluster.local:8000
HEAD=$($K -n $NS get pod -l ray-role=head -o jsonpath='{.items[0].metadata.name}')
WORKER=$($K -n $NS get pod -l ray-role=worker -o jsonpath='{.items[0].metadata.name}')
M(){ $K -n $NS exec "$HEAD" -c ray-head -- python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())" 2>/dev/null | grep -E '^vllm:'; }
log 00-target "echo label='$LABEL' svc=$ENGSVC head=$HEAD worker=$WORKER; $K -n $NS get pod $HEAD $WORKER -o wide"
log 01-metrics-before "M"
# Bench client runs from the neighbor namespace: same cross-namespace path a
# real caller or attacker takes, and what NetworkPolicy in L1 must still allow.
$K -n sorami-lab-neighbor create configmap sorami-lab-bench --from-file=bench.py=$ROOT/bench/bench.py --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n sorami-lab-neighbor delete job sorami-lab-bench-stagec --ignore-not-found >/dev/null
# Render a Stage C job from the Stage B manifest by swapping name + target svc,
# and inject BENCH_MODEL so the client asks for the 1.5B model this stage serves
# (vLLM 404s on a mismatched model tag). The env block is added right after the
# BASE env var so it lands inside the container env list.
sed -e 's#sorami-lab-bench-baseline#sorami-lab-bench-stagec#' \
    -e "s#http://sorami-lab-vllm-engine.sorami-lab-stack-vllm.svc.cluster.local:8000#$ENGSVC#" \
    -e '/value: http/a\
            - name: BENCH_MODEL\
              value: Qwen/Qwen2.5-1.5B-Instruct' \
    $ROOT/manifests/stageB-bench-job.yaml > /tmp/stagec-bench-job.yaml
# For L3 only: pass the api-key to the client via BENCH_API_KEY sourced from the
# same secret the engine uses, so the benchmark path is authenticated. The key
# is injected as a secretKeyRef so it is never written into the manifest or log.
if [ "${BENCH_AUTH:-0}" = "1" ]; then
  sed -i.bak2 -e '/- name: BENCH_MODEL/i\
            - name: BENCH_API_KEY\
              valueFrom:\
                secretKeyRef:\
                  name: sorami-lab-vllm-apikey\
                  key: apikey' /tmp/stagec-bench-job.yaml
fi
# For L2 only: mesh the bench client so the client->8000 path is real mTLS end
# to end, not just a server-side proxy hop. MESH_BENCH=1 injects the Linkerd
# proxy into the Job pod. The proxy is a native sidecar init container, so the
# Job pod still completes when the bench container exits.
if [ "${MESH_BENCH:-0}" = "1" ]; then
  # proxy-await holds the bench container until the proxy is ready, otherwise the
  # first requests race the proxy and 503. The proxy is a native sidecar, so the
  # Job pod still terminates cleanly when the bench container exits.
  sed -i.bak -e '/^    metadata:/,/^    spec:/ s#^      labels:#      annotations:\n        linkerd.io/inject: enabled\n        config.linkerd.io/proxy-await: enabled\n      labels:#' /tmp/stagec-bench-job.yaml
fi
log 03-apply-job "$K apply -f /tmp/stagec-bench-job.yaml"
# Sample GPU on both PP stages for the duration of the run.
( while ! $K -n sorami-lab-neighbor get job sorami-lab-bench-stagec -o jsonpath='{.status.conditions[*].type}' 2>/dev/null | grep -qE 'Complete|Failed'; do
    echo "# UTC $(date -u +%FT%TZ)"
    echo -n "head(A10G) "; $K -n $NS exec "$HEAD" -c ray-head -- nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader 2>/dev/null
    echo -n "worker(T4) "; $K -n $NS exec "$WORKER" -c ray-worker -- nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader 2>/dev/null
    sleep 20; done ) > "$R/04-nvidia-smi-load.csv.log" 2>&1 &
SAMPLER=$!
sleep 60
log 05-metrics-during "M"
log 07-job-wait "$K -n sorami-lab-neighbor wait --for=condition=complete job/sorami-lab-bench-stagec --timeout=3600s"
wait $SAMPLER
log 08-job-logs "$K -n sorami-lab-neighbor logs job/sorami-lab-bench-stagec"
log 09-metrics-after "M"
grep '^RESULT' "$R/08-job-logs.log" | while read -r _ c json; do echo "$json" > "$R/result-c${c#c=}.json"; done
python3 - "$R" "$LABEL" <<'EOF' > "$R/10-table.md"
import json, glob, sys, os
print(f"Label: {sys.argv[2]}\n")
print("| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |")
print("|---|---|---|---|---|---|---|")
for f in sorted(glob.glob(os.path.join(sys.argv[1], "result-c*.json")), key=lambda p:int(p.rsplit("-c",1)[-1][:-5])):
    s=json.load(open(f)); g=lambda k:" / ".join(str(s.get(k+"_ms",{}).get(p,"-")) for p in ("p50","p95","p99"))
    print(f"| {s['concurrency']} | {s['ok']}/{s['requests']} | {s['req_per_s']} | {s['out_tok_per_s']} | {g('ttft')} | {g('tpot')} | {g('e2e')} |")
EOF
cat "$R/10-table.md"
redact
echo BENCH_DONE
