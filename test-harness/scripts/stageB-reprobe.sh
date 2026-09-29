#!/usr/bin/env bash
# Stage B neighbor re-probe against the live vLLM GPU engine. Every call is a
# read of the already-deployed model (no weights, config or cluster state are
# changed), run from an unprivileged pod in another namespace so the result is
# what a compromised neighbor workload would see.
set -uo pipefail
source test-harness/.aws-session.env
source test-harness/scripts/lib.sh
guard || exit 99
R=${LOGS:-logs}/2026-09-28-stageB-08-neighbor-reprobe
mkdir -p "$R"
ENG=$($K -n sorami-lab-stack-vllm get pod -l app=sorami-lab-vllm-engine -o jsonpath='{.items[0].status.podIP}')
SVC=sorami-lab-vllm-engine.sorami-lab-stack-vllm.svc.cluster.local
echo "engine_pod_ip=$ENG svc=$SVC" > "$R/target.txt"
M=Qwen/Qwen2.5-7B-Instruct
X(){ $K -n sorami-lab-neighbor exec deploy/sorami-lab-neighbor -- "$@"; }

log 01-identity "X sh -c 'id; grep CapBnd /proc/self/status; ls /var/run/secrets/kubernetes.io 2>&1 || echo NO_SA_TOKEN'"
log 02-portscan "X nmap -Pn -sT -p 8000,8001,8080,5678,9090,29500,51216 --reason $ENG"
# A plaintext HTTP server answers a TLS ClientHello with an HTTP 400 or a
# framing error, so this is how "no TLS on 8000" is evidenced.
log 03-tls-podip "X sh -c 'echo | timeout 8 openssl s_client -connect $ENG:8000 2>&1 | head -8'"
log 04-tls-svcdns "X sh -c 'echo | timeout 8 openssl s_client -connect $SVC:8000 2>&1 | head -8'"
log 05-models "X curl -s --max-time 15 http://$SVC:8000/v1/models"
log 06-chat "X curl -s --max-time 90 -H 'Content-Type: application/json' -d '{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: reachable\"}],\"max_tokens\":8,\"temperature\":0}' http://$SVC:8000/v1/chat/completions"
log 07-completions "X curl -s --max-time 90 -H 'Content-Type: application/json' -d '{\"model\":\"$M\",\"prompt\":\"The capital of France is\",\"max_tokens\":8,\"temperature\":0}' http://$SVC:8000/v1/completions"
log 08-tokenize "X curl -s --max-time 20 -H 'Content-Type: application/json' -d '{\"model\":\"$M\",\"prompt\":\"patient MRN 123456 has a penicillin allergy\"}' http://$SVC:8000/tokenize"
# Round-tripping tokens back to text shows the endpoint pair is enough to read
# another tenant's prompt content if token ids ever leak (logs, traces, KV).
log 09-detokenize "X curl -s --max-time 20 -H 'Content-Type: application/json' -d '{\"model\":\"$M\",\"tokens\":[785,6722,315,9625,374]}' http://$SVC:8000/detokenize"
log 10-metrics-head "X sh -c 'curl -s --max-time 15 http://$SVC:8000/metrics | head -40'"
log 11-metrics-counters "X sh -c \"curl -s --max-time 15 http://$SVC:8000/metrics | grep -E '^vllm:(request_success_total|prompt_tokens_total|generation_tokens_total|num_requests_running|num_requests_waiting|gpu_cache_usage_perc|kv_cache_usage_perc|e2e_request_latency_seconds_(sum|count)|time_to_first_token_seconds_(sum|count)|time_per_output_token_seconds_(sum|count)|request_prompt_tokens_(sum|count)|request_generation_tokens_(sum|count)|request_params_max_tokens_(sum|count)|iteration_tokens_total_(sum|count)|prefix_cache_(queries|hits)_total)'\""
log 12-metrics-names "X sh -c \"curl -s --max-time 15 http://$SVC:8000/metrics | grep '^# HELP' | wc -l; curl -s --max-time 15 http://$SVC:8000/metrics | grep '^# HELP'\""
log 13-openapi-routes "X sh -c \"curl -s --max-time 15 http://$SVC:8000/openapi.json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d[\\\"paths\\\"]));[print(p, ','.join(m.upper() for m in v)) for p,v in sorted(d[\\\"paths\\\"].items())]' 2>/dev/null || curl -s --max-time 15 http://$SVC:8000/openapi.json | head -c 600\""
log 14-netpol "$K get networkpolicy -A"
log 15-netpol-agent "$K -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[*].args}'; echo; $K -n kube-system get ds aws-node -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{\" \"}{.args}{\"\\n\"}{end}'"
redact
echo REPROBE_DONE
