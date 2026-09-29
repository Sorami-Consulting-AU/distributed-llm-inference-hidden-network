#!/usr/bin/env bash
# Stage B baseline resume: GPU node group convergence, in-cluster bench sweep,
# GPU + /metrics capture under load, and neighbor re-probe incl /v1/completions.
# Only touches sorami-lab resources. Needs valid AWS credentials for account
# 111122223333 (aws sts get-caller-identity must succeed first).
set -uo pipefail
source test-harness/scripts/lib.sh
aws sts get-caller-identity --query Account --output text | grep -qx 111122223333 || { echo "AWS CREDS INVALID OR WRONG ACCOUNT"; exit 98; }
guard || exit 99
BASE_LOGS=${LOGS:-logs}
ROOT=test-harness
NG="--cluster-name sorami-lab --nodegroup-name sorami-lab-gpu-spot"
ENGSVC=http://sorami-lab-vllm-engine.sorami-lab-stack-vllm.svc.cluster.local:8000

# ---- 1. GPU node group --------------------------------------------------
R=$BASE_LOGS/2026-09-28-stageB-06-gpu-nodegroup; mkdir -p "$R"
st(){ aws eks describe-nodegroup $NG --query nodegroup.status --output text; }
for i in $(seq 1 30); do s=$(st); echo "$(date -u +%FT%TZ) status=$s" >> "$R/00-poll.log"; case $s in ACTIVE|DEGRADED|CREATE_FAILED) break;; esac; sleep 30; done
log 01-describe "aws eks describe-nodegroup $NG --output json"
log 02-nodes-before "$K get nodes -L sorami-lab/pool,node.kubernetes.io/instance-type,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone"
if [ "$(st)" = CREATE_FAILED ]; then
  # A CREATE_FAILED managed node group rejects UpdateNodegroupConfig (409), so
  # terraform can only converge by replacement. That recycles the g6 node and
  # vLLM must re-pull weights; accepted because the group is otherwise stuck.
  # gpu_desired is passed explicitly because the variable defaults to 0.
  ( cd $ROOT/infra && log 03-tf-plan "terraform plan -input=false -var gpu_desired=1 -out=gpu-recreate.tfplan -no-color" \
    && log 04-tf-apply "terraform apply -input=false -no-color gpu-recreate.tfplan" )
elif [ "$(aws eks describe-nodegroup $NG --query nodegroup.scalingConfig.desiredSize --output text)" != 1 ]; then
  ( cd $ROOT/infra && log 03-tf-apply-desired1 "terraform apply -input=false -auto-approve -no-color -var gpu_desired=1" )
fi
log 05-describe-after "aws eks describe-nodegroup $NG --query 'nodegroup.{s:status,sc:scalingConfig,ct:capacityType,it:instanceTypes,h:health}' --output json"
log 06-nodes-after "$K get nodes -L sorami-lab/pool,node.kubernetes.io/instance-type,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone"
log 07-vllm-wait "$K -n sorami-lab-stack-vllm rollout status deploy/sorami-lab-vllm-engine --timeout=1800s"
log 08-vllm-kvcache "$K -n sorami-lab-stack-vllm logs deploy/sorami-lab-vllm-engine | grep -E 'KV cache|Maximum concurrency|max_model_len|gpu_memory_utilization|Loading weights took|Model loading took'"
redact

# ---- 2+3. bench sweep with GPU + metrics capture ------------------------
R=$BASE_LOGS/2026-09-28-stageB-06-bench; mkdir -p "$R"
POD=$($K -n sorami-lab-stack-vllm get pod -l app=sorami-lab-vllm-engine -o jsonpath='{.items[0].metadata.name}')
log 00-target "echo pod=$POD svc=$ENGSVC; $K -n sorami-lab-stack-vllm get pod $POD -o wide"
log 01-metrics-before "$K -n sorami-lab-stack-vllm exec $POD -- python3 -c \"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())\" | grep -E '^vllm:'"
log 02-nvidia-smi-idle "$K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi"
$K -n sorami-lab-neighbor create configmap sorami-lab-bench --from-file=bench.py=$ROOT/bench/bench.py --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n sorami-lab-neighbor delete job sorami-lab-bench-baseline --ignore-not-found >/dev/null
log 03-apply-job "$K apply -f $ROOT/manifests/stageB-bench-job.yaml"
# Sample GPU every 20s for the life of the job.
( while ! $K -n sorami-lab-neighbor get job sorami-lab-bench-baseline -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'; do
    echo "# UTC $(date -u +%FT%TZ)"
    $K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu --format=csv,noheader
    sleep 20; done ) > "$R/04-nvidia-smi-load.csv.log" 2>&1 &
SAMPLER=$!
sleep 90
log 05-metrics-during "$K -n sorami-lab-stack-vllm exec $POD -- python3 -c \"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())\" | grep -E '^vllm:'"
log 06-nvidia-smi-during "$K -n sorami-lab-stack-vllm exec $POD -- nvidia-smi"
log 07-job-wait "$K -n sorami-lab-neighbor wait --for=condition=complete job/sorami-lab-bench-baseline --timeout=3600s"
wait $SAMPLER
log 08-job-logs "$K -n sorami-lab-neighbor logs job/sorami-lab-bench-baseline"
log 09-metrics-after "$K -n sorami-lab-stack-vllm exec $POD -- python3 -c \"import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())\" | grep -E '^vllm:'"
grep '^RESULT' "$R/08-job-logs.log" | while read -r _ c json; do echo "$json" > "$R/result-${c#c=}.json"; done
python3 - "$R" <<'EOF' > "$R/10-table.md"
import json, glob, sys, os
print("| label | conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |")
print("|---|---|---|---|---|---|---|---|")
for f in sorted(glob.glob(os.path.join(sys.argv[1], "result-c*.json")) , key=lambda p:int(p.split("-c")[-1][:-5])):
    s=json.load(open(f)); g=lambda k:"/".join(str(s.get(k+"_ms",{}).get(p,"-")) for p in ("p50","p95","p99"))
    print(f"| baseline (no NetPol, no mTLS) | {s['concurrency']} | {s['ok']}/{s['requests']} | {s['req_per_s']} | {s['out_tok_per_s']} | {g('ttft')} | {g('tpot')} | {g('e2e')} |")
EOF
cat "$R/10-table.md"
redact

# ---- 4. neighbor re-probe ----------------------------------------------
R=$BASE_LOGS/2026-09-28-stageB-07-neighbor-reprobe; mkdir -p "$R"
bash $ROOT/scripts/probe-gpu.sh "$R" > "$R/00-summary.txt" 2>&1
ENG=$(cut -d= -f2 "$R/target.txt")
X(){ $K -n sorami-lab-neighbor exec deploy/sorami-lab-neighbor -- "$@"; }
log 08-completions "X curl -s --max-time 60 -H 'Content-Type: application/json' -d '{\"model\":\"Qwen/Qwen2.5-7B-Instruct\",\"prompt\":\"The capital of France is\",\"max_tokens\":8,\"temperature\":0}' http://$ENG:8000/v1/completions"
log 09-metrics-privacy "X sh -c \"curl -s --max-time 10 http://$ENG:8000/metrics | grep -E '^vllm:(request_success_total|prompt_tokens_total|generation_tokens_total|num_requests_running|num_requests_waiting|e2e_request_latency_seconds_(sum|count)|time_to_first_token_seconds_(sum|count)|request_prompt_tokens_(sum|count)|request_params_max_tokens_(sum|count))'\""
log 10-detokenize "X curl -s --max-time 20 -H 'Content-Type: application/json' -d '{\"model\":\"Qwen/Qwen2.5-7B-Instruct\",\"tokens\":[785,6722,315,9625,374]}' http://$ENG:8000/detokenize"
log 11-netpol "$K get networkpolicy -A"
redact
echo DONE
