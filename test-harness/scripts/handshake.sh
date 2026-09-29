#!/bin/sh
# Runs inside the neighbor pod. Read-only by design: GET on documented read
# endpoints, TLS negotiation attempts and Redis PING/INFO server.
# No POST/PUT, no job submission, no Redis writes.
T=4

probe_http() {
  echo "=== HTTP $1:$2$3"
  timeout $T curl -sS -o /tmp/body -w 'http_code=%{http_code} size=%{size_download}\n' "http://$1:$2$3" 2>&1
  head -c 400 /tmp/body 2>/dev/null; echo
}

probe_tls() {
  echo "=== TLS $1:$2"
  echo Q | timeout $T openssl s_client -connect "$1:$2" -brief 2>&1 | head -6
}

probe_redis() {
  echo "=== REDIS $1:$2 (PING + INFO server only)"
  printf 'PING\r\nINFO server\r\nQUIT\r\n' | timeout $T nc "$1" "$2" 2>&1 | head -20
}

probe_banner() {
  echo "=== BANNER $1:$2"
  timeout $T nc -v -w 3 "$1" "$2" </dev/null 2>&1 | head -5
}

RAY_HEAD="$1"; RAY_WORKER="$2"; KUBERAY_OP="$3"; VLLM_ROUTER="$4"

echo "##### Ray head dashboard / job API (8265)"
probe_http "$RAY_HEAD" 8265 /
probe_http "$RAY_HEAD" 8265 /api/version
probe_http "$RAY_HEAD" 8265 /api/jobs/
probe_http "$RAY_HEAD" 8265 /nodes?view=summary
probe_tls  "$RAY_HEAD" 8265

echo "##### Ray GCS (6379) and client server (10001)"
probe_redis  "$RAY_HEAD" 6379
probe_tls    "$RAY_HEAD" 6379
probe_banner "$RAY_HEAD" 10001
probe_tls    "$RAY_HEAD" 10001

echo "##### Ray metrics (8080) head and worker"
probe_http "$RAY_HEAD" 8080 /metrics
probe_http "$RAY_WORKER" 8080 /metrics

echo "##### Ray ephemeral worker RPC ports"
for p in 52365 44217 36087; do probe_banner "$RAY_HEAD" $p; probe_tls "$RAY_HEAD" $p; done

echo "##### KubeRay operator (8080 metrics, 8082 probes)"
probe_http "$KUBERAY_OP" 8080 /metrics
probe_http "$KUBERAY_OP" 8082 /readyz

echo "##### vLLM router (8000)"
probe_http "$VLLM_ROUTER" 8000 /health
probe_http "$VLLM_ROUTER" 8000 /v1/models
probe_http "$VLLM_ROUTER" 8000 /metrics
probe_tls  "$VLLM_ROUTER" 8000