# Stage C: distributed multi-node inference and its hidden network

Date: 2026-09-28 (UTC). Cluster: `sorami-lab` (EKS, ap-southeast-2).
Cross-links: Stage A `findings/2026-09-28-stageA-baseline.md`, Stage B `findings/2026-09-28-stageB-baseline.md`.

## Summary

When inference is split across two nodes, a distributed control plane appears that
single-node Stage B never exposed. On this cluster the Ray GCS (6379) and raylet RPC
(10002 to 10006) listen on the pod network in cleartext, with no authentication and no
TLS, and are reachable from an unrelated namespace. The vLLM OpenAI API (8000) is also
reachable cross-namespace with no api-key. The one vector that did NOT open is the Ray
Job HTTP API (8265): the minimal serving image does not run the Ray dashboard/job server,
so unauthenticated RCE via 8265 was not possible on this image. The deeper control-plane
exposure (GCS and raylet in plaintext) is the real distributed attack surface, and it is
what Stage D hardens.

## Topology and why

Preferred path (disaggregated prefill/decode with P2P KV transfer) was attempted first and
failed: the vLLM v0.11.0 `P2pNcclConnector` OOMed in `tensor_memory_pool` allocating pinned
host memory, on both nodes, even after shrinking the buffer and GPU memory utilization.
Evidence: `logs/2026-09-28-stageC-02-topology/06-p2p-oom-evidence.log` and the decision
note `07-topology-decision.md`.

Adopted the study plan's documented acceptable alternative: Ray-backed vLLM with pipeline
parallel PP=2 across the two nodes. Manifest: `manifests/stageC-ray-pp.yaml`.

- PP stage 0 (Ray head + vLLM driver): `ip-10-99-31-72` g5.xlarge, NVIDIA A10G 24 GB, AZ 2b.
- PP stage 1 (Ray worker): `ip-10-99-9-134` g4dn.xlarge, NVIDIA T4 16 GB, AZ 2a.

Placement is pinned by `kubernetes.io/hostname` and kept identical for every Stage D layer,
so the only variable across L0 to L3 is the hardening being applied.

### Heterogeneity and model, so numbers are within-stage only

The two GPUs are different models (A10G 24 GB vs T4 16 GB, compute capability 8.6 vs 7.5).
The model is `Qwen/Qwen2.5-1.5B-Instruct` at `--dtype half`, chosen to fit the 16 GB T4,
and it is a different, smaller model than Stage B (7B). Therefore Stage C absolute numbers
are NOT comparable to Stage B. Only the within-Stage-D L0 to L3 deltas are meaningful, and
they are measured against the L0 row below.

### Engine stabilization notes (WHY these settings)

- `VLLM_USE_FLASHINFER_SAMPLER=0`: flashinfer `check_cuda_arch()` calls `minor.isdigit()`,
  which throws on the T4 where the CUDA minor version is an int, crashing worker startup.
- `VLLM_ATTENTION_BACKEND=TORCH_SDPA`: the xformers backend has no registered
  `memory_efficient_attention_forward` op for the T4 head/dtype config under PP and threw
  `NotImplementedError` at the first forward pass. PyTorch SDPA is supported on every CUDA
  arch in eager mode and is the safe cross-GPU backend for this heterogeneous pipeline.
- `--enforce-eager`: avoids CUDA graph capture differences across the two GPU archs.

Generation verified end to end across the pipeline (A10G to T4): prompt "The capital of
France is" returned "Paris.", confirming both stages execute.

## Distributed port and channel inventory (cross-namespace, allowlist-only)

Source: unprivileged neighbor pod `sorami-lab-neighbor` in namespace `sorami-lab-neighbor`
(uid 1000, no service-account token), probing only the two discovered engine pod IPs.
Evidence: `logs/2026-09-28-stageC-07-reinventory/01-portscan.log`.

| Target | Port | Purpose | Cross-ns result |
|---|---|---|---|
| head (A10G) 10.99.17.121 | 6379 | Ray GCS (control plane) | OPEN, unauth |
| head (A10G) | 8000 | vLLM OpenAI API | OPEN, unauth |
| head (A10G) | 10002 to 10006 | raylet / worker RPC, object manager | OPEN, unauth |
| head (A10G) | 8265 | Ray Job / dashboard HTTP API | closed (not running on this image) |
| head (A10G) | 10001 | Ray Client server | closed (needs ray[client]) |
| worker (T4) 10.99.13.46 | 10002 | raylet RPC | OPEN, unauth |

The head also listens on several high ephemeral ports (for example in the 33000 to 60000
range) that are NOT declared as `containerPort`; these are Ray worker/agent RPC sockets.
Evidence: `logs/2026-09-28-stageC-03-inventory/02-head-listen-sockets.log`.

## Ray Job API RCE test (the ONE safe synthetic submission)

Attempted the single synthetic marker-only job submission from the neighbor pod to
`POST http://<head>:8265/api/jobs/` with entrypoint
`python -c "import socket; print('sorami-lab-marker', socket.gethostname())"`.

Result: TCP connect to 8265 was REFUSED, and the submission failed with
`URLError [Errno 111] Connection refused`. Evidence:
`logs/2026-09-28-stageC-07-reinventory/02-rayjob-8265.log`.

Interpretation: the minimal `vllm/vllm-openai:v0.11.0` image starts Ray via `ray start`
without `ray[default]`, so the dashboard/job HTTP server (8265) never binds. Unauthenticated
RCE via the Ray Job API is therefore NOT reachable on this image. This is a positive,
image-specific result, not a sign that the control plane is safe: GCS (6379) and raylet
(10002 to 10006) remain open and unauthenticated cross-namespace, which is the more
fundamental exposure. An image that ships `ray[default]` (common in Ray Serve / KubeRay
tutorials) would expose 8265 and make the RCE path live.

## Plaintext control-plane evidence (passive)

From the neighbor pod, connecting to GCS 6379 and raylet 10002 on both the head and the
worker returns a 46-byte HTTP/2 SETTINGS frame immediately on TCP connect (byte prefix
`00 00 18 04 ...`, the cleartext gRPC transport preface). A TLS handshake attempt against
the same ports fails with `SSL: WRONG_VERSION_NUMBER`, proving the listeners are plaintext
with no TLS. Evidence: `logs/2026-09-28-stageC-07-reinventory/03-plaintext.log`.

This is the "hidden network": the inter-node control and coordination traffic of the
distributed engine crosses the pod network unencrypted and unauthenticated, readable by
any pod that can route to those IPs.

## Unauthenticated inference cross-namespace

From the neighbor pod, `GET /v1/models` and `POST /v1/completions` on the head 8000 both
return HTTP 200 with no credentials. Evidence:
`logs/2026-09-28-stageC-07-reinventory/04-vllm-unauth.log`. This is the finding that L3
(engine `--api-key`) later closes.

## Distributed benchmark: L0 baseline (no NetworkPolicy, no mTLS, no TLS)

Client: `bench/bench.py` (stdlib streaming, server-reported token counts), run from the
neighbor namespace, warmup then 128 requests per concurrency level, 0 failures across all
512 requests. Evidence: `logs/2026-09-28-stageC-06-bench/` (per-level JSON + `10-table.md`).

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.269 | 34.4 | 38.2 / 47.7 / 51.4 | 28.9 / 31.3 / 32.7 | 3712.4 / 4026.4 / 4186.3 |
| 4 | 128/128 | 0.927 | 118.7 | 59.7 / 386.4 / 7397.3 | 32.1 / 34.1 / 34.3 | 4138.9 / 4497.6 / 11748.2 |
| 16 | 128/128 | 3.198 | 409.4 | 81.5 / 798.5 / 800.8 | 37.3 / 41.7 / 41.7 | 4807.4 / 5795.4 / 5797.1 |
| 32 | 128/128 | 3.353 | 429.2 | 474.6 / 10024.8 / 10028.8 | 54.0 / 56.7 / 131.1 | 7330.0 / 16881.9 / 16899.2 |

GPU under load (peak observed): head A10G ~13% util, ~14.1 GiB used; worker T4 ~68% util,
~8.6 GiB used. The T4 (PP stage 1, decode-heavy) is the pipeline bottleneck, as expected
for PP where the slower GPU gates throughput. Evidence:
`logs/2026-09-28-stageC-06-bench/04-nvidia-smi-load.csv.log`.

This L0 row is the pre-hardening distributed baseline that Stage D compares against.
