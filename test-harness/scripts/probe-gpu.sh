#!/usr/bin/env bash
# Stage B unauthenticated neighbor probe against the live vLLM GPU engine.
# Read-only: identity, TCP connect scan on an allowlist, then OpenAI-protocol
# handshakes (models list, one chat completion, tokenizer) that only read the
# already-deployed model. No mutation of cluster state.
set -euo pipefail
source test-harness/scripts/lib.sh
guard >/dev/null || exit 99
R="$1"; mkdir -p "$R"
ENG=$($K -n sorami-lab-stack-vllm get pod -l app=sorami-lab-vllm-engine -o jsonpath='{.items[0].status.podIP}')
echo "engine=$ENG" | tee "$R/target.txt"
X() { $K -n sorami-lab-neighbor exec deploy/sorami-lab-neighbor -- "$@"; }

log() { local n="$1"; shift; { echo "# UTC $(date -u +%FT%TZ)"; echo "# $*"; "$@" 2>&1; echo "# EXIT: $?"; } > "$R/$n.log"; }

log 01-identity X sh -c 'id; grep CapBnd /proc/self/status; ls /var/run/secrets/kubernetes.io 2>&1 || echo NO_SA_TOKEN'
log 02-portscan X nmap -Pn -sT -p 8000,8001,8080,5678,9090,29500,51216 --reason "$ENG"
log 03-tls X sh -c "echo | timeout 8 openssl s_client -connect $ENG:8000 2>&1 | head -6"
log 04-models X curl -s --max-time 10 "http://$ENG:8000/v1/models"
log 05-chat X curl -s --max-time 90 -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"Reply with the single word: reachable"}],"max_tokens":8,"temperature":0}' \
  "http://$ENG:8000/v1/chat/completions"
log 06-tokenize X curl -s --max-time 20 -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","prompt":"secret data"}' \
  "http://$ENG:8000/tokenize"
log 07-metrics X sh -c "curl -s --max-time 10 http://$ENG:8000/metrics | head -30"
redact
echo "=== identity";   sed -n '3,6p'  "$R/01-identity.log"
echo "=== portscan";   grep -aE 'open|closed|filtered' "$R/02-portscan.log" | head
echo "=== tls";        sed -n '3,6p'  "$R/03-tls.log"
echo "=== models";     cat "$R/04-models.log" | head -4
echo "=== chat";       cat "$R/05-chat.log" | head -6
echo "=== tokenize";   head -c 400 "$R/06-tokenize.log"; echo
echo "=== metrics";    sed -n '3,10p' "$R/07-metrics.log"
