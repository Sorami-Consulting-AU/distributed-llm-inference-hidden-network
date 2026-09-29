# Stage B baseline: single vLLM GPU engine on vendor defaults (2026-09-28)

Cluster `sorami-lab` (dedicated VPC `10.99.0.0/16`, `ap-southeast-2`), one spot GPU node,
one vLLM engine. No NetworkPolicy, no mTLS, no TLS, no API key: this is the un-hardened
reference that the Stage D hardening layers are measured against.
Prior stage: [stageA-baseline](./2026-09-28-stageA-baseline.md).

Logs: [stageB-07-bench](../logs/2026-09-28-stageB-07-bench/),
[stageB-08-neighbor-reprobe](../logs/2026-09-28-stageB-08-neighbor-reprobe/),
[stageB-06-ondemand-nodegroup](../logs/2026-09-28-stageB-06-ondemand-nodegroup/),
[stageB-02-gpu-diagnose](../logs/2026-09-28-stageB-02-gpu-diagnose/),
[stageB-05-neighbor-gpu](../logs/2026-09-28-stageB-05-neighbor-gpu/).

## Node under test

| Field | Value | Evidence |
|---|---|---|
| Node | `ip-10-99-23-211.ap-southeast-2.compute.internal` | [00-target](../logs/2026-09-28-stageB-07-bench/00-target.log) |
| Instance | `g6.xlarge`, 1x NVIDIA L4 24GB (23,034 MiB), 4 vCPU, 16 GiB | [06-nvidia-smi-during](../logs/2026-09-28-stageB-07-bench/06-nvidia-smi-during.log) |
| Capacity type | **SPOT**, `i-000cfb01a7937def2`, AZ `ap-southeast-2b`, launched 2026-09-28T04:54:54Z | [00-target](../logs/2026-09-28-stageB-07-bench/00-target.log) |
| Node group | `sorami-lab-gpu-spot` (status `CREATE_FAILED`, health `AsgInstanceLaunchFailures`) | [05-describe-ondemand](../logs/2026-09-28-stageB-06-ondemand-nodegroup/05-describe-ondemand.log) |
| Label / taint | `sorami-lab/pool=gpu`, `sorami-lab/gpu=true:NoSchedule` | [00-target](../logs/2026-09-28-stageB-07-bench/00-target.log) |
| GPU advertised | `nvidia.com/gpu=1` via helm release `nvdp` in `sorami-lab-gpu-system` | [stageB-03-device-plugin](../logs/2026-09-28-stageB-03-device-plugin/) |

The node group is `CREATE_FAILED` yet the one instance it did launch is `Ready` and serving.
EKS marks the group failed because the ASG never reached desired capacity, but it does not
terminate the instance that succeeded. That is why the baseline could still run.

## Spot capacity incident (UTC, 2026-09-28)

| Time | Event | Evidence |
|---|---|---|
| 04:38:54 to 04:39:53 | Terraform apply, GPU spot group desired 0 to 2 (`1 changed`) | [00-plan](../logs/2026-09-28-stageB-01-gpu-scaleup/00-plan.log), [01-apply](../logs/2026-09-28-stageB-01-gpu-scaleup/01-apply.log) |
| 04:43:26 to 04:50:25 | GPU ASG: repeated `Could not launch Spot Instances. UnfulfillableCapacity` (g6 only mix), no instance placed | [asg-gpu-activity](../logs/2026-09-28-stageB-02-gpu-diagnose/asg-gpu-activity.log) |
| 04:47:20 | Same hour on the **CPU** spot ASG: spot interruption of `i-0ad450bcf204f8169` (after a 04:23 rebalance replacement), replaced at 04:47:28 | [asg-cpu-activity](../logs/2026-09-28-stageB-02-gpu-diagnose/asg-cpu-activity.log) |
| 04:50:29 | Spot placement score **1 of 10** for every g4dn/g5/g6/g6.4xlarge size in all 3 AZs; `g6e.xlarge` not offered at all | [spot-placement-scores](../logs/2026-09-28-stageB-02-gpu-diagnose/spot-placement-scores.log) |
| 04:52:39 to 04:53:04 | Instance mix widened to 7 types (g6, g6.2xl, g5, g5.2xl, g6.4xl, g4dn, g4dn.2xl); `instance_types` forces replacement, old group destroyed, new group creating | [02-plan-mix](../logs/2026-09-28-stageB-01-gpu-scaleup/02-plan-mix.log), [03-apply-mix](../logs/2026-09-28-stageB-01-gpu-scaleup/03-apply-mix.log) |
| 04:54:54 | `i-000cfb01a7937def2` launched and stayed: the node used for this baseline | [00-target](../logs/2026-09-28-stageB-07-bench/00-target.log) |
| 04:58 to 05:23 | `UnfulfillableCapacity` continued for the second node, roughly every 2 to 4 min for 25 min | [04-asg-activity-mix](../logs/2026-09-28-stageB-01-gpu-scaleup/04-asg-activity-mix.log) |
| 05:26:30 | Terraform: node group reached `CREATE_FAILED`; `UpdateNodegroupConfig` then returns **409 ResourceInUseException** | [gpu-nodes](../logs/2026-09-28-stageB-01-gpu-scaleup/gpu-nodes.log), [07-apply-gpu1](../logs/2026-09-28-stageB-01-gpu-scaleup/07-apply-gpu1.log) |
| 06:02 to 06:04 | On-demand fallback node group created at desired 0 | [04-tf-apply-ondemand](../logs/2026-09-28-stageB-06-ondemand-nodegroup/04-tf-apply-ondemand.log) |

Two spot failure modes in one hour: GPU capacity that could not be fulfilled at all, and a
live interruption on the CPU spot pool. Widening the GPU group to 7 instance types got one
node but not a second, so in this region the practical ceiling was **one** spot GPU node.
The spot g6 node survived the whole benchmark window, so the on-demand fallback was created
but never scaled up.

## On-demand fallback node group

Added `aws_eks_node_group.gpu_ondemand` in `infra/eks.tf` (`sorami-lab-gpu-ondemand`),
own variable `gpu_ondemand_desired` (default 0), min 0, **max 1**, `capacity_type = ON_DEMAND`,
`AL2023_x86_64_NVIDIA`, disk 150, same taint and `sorami-lab/pool=gpu` label plus
`sorami-lab/capacity=ondemand`. Applied `ACTIVE` at desired 0, which bills nothing.

| Type | GPU | On-demand USD/h | Spot USD/h seen | AZs offered |
|---|---|---|---|---|
| `g6.xlarge` | 1x L4 24GB | **1.0464** | 0.5457 to 0.6091 | a, b, c |
| `g5.xlarge` | 1x A10G 24GB | **1.3080** | 0.6646 to 0.6933 | b, c |
| `g4dn.xlarge` | 1x T4 16GB | **0.6840** | 0.3079 to 0.3204 | a, b, c |

Prices from the AWS pricing API and `describe-spot-price-history` on 2026-09-28T06:02Z:
[01-pricing](../logs/2026-09-28-stageB-06-ondemand-nodegroup/01-pricing.log). On-demand
`g6.xlarge` is about 1.8x the spot price, so the fallback costs roughly 0.46 USD/h more than
spot while it runs. g4dn is listed last because 7B fp16 weights plus KV cache do not fit in
16 GB at 8k context.

Plan review before apply: the untargeted plan wanted to change the `CREATE_FAILED` spot
group in place (`desired_size 2 -> 1`), which the EKS API rejects with 409, so the apply was
scoped with `-target=aws_eks_node_group.gpu_ondemand` and `Plan: 1 to add, 0 to change, 0 to
destroy`, only `sorami-lab*` resources:
[02-tf-plan-full-readonly](../logs/2026-09-28-stageB-06-ondemand-nodegroup/02-tf-plan-full-readonly.log),
[03-tf-plan-ondemand](../logs/2026-09-28-stageB-06-ondemand-nodegroup/03-tf-plan-ondemand.log).

## Model and KV cache configuration

Manifest: `test-harness/manifests/stageB-vllm-engine.yaml`. Image `vllm/vllm-openai:v0.11.0`.

| Setting | Value | Evidence |
|---|---|---|
| Model | `Qwen/Qwen2.5-7B-Instruct`, bf16 weights, `cache_dtype=auto` | [01-metrics-before](../logs/2026-09-28-stageB-07-bench/01-metrics-before.log) |
| Args | `--max-model-len=8192 --gpu-memory-utilization=0.90 --port=8000`, no `--api-key`, no `--ssl-*` | [02b-vllm-kvcache](../logs/2026-09-28-stageB-07-bench/02b-vllm-kvcache.log) |
| Available KV cache memory | **5.01 GiB** | [02b-vllm-kvcache](../logs/2026-09-28-stageB-07-bench/02b-vllm-kvcache.log) |
| GPU KV cache size | **93,840 tokens** (5,865 blocks x 16) | same, plus `cache_config_info` in [01-metrics-before](../logs/2026-09-28-stageB-07-bench/01-metrics-before.log) |
| Max concurrency at 8,192 tokens/request | **11.46x** | [02b-vllm-kvcache](../logs/2026-09-28-stageB-07-bench/02b-vllm-kvcache.log) |
| Prefix caching | on (`enable_prefix_caching=True`, sha256) | [01-metrics-before](../logs/2026-09-28-stageB-07-bench/01-metrics-before.log) |
| GPU memory held by engine | 21,196 of 23,034 MiB, constant idle and under load | [04-nvidia-smi-load](../logs/2026-09-28-stageB-07-bench/04-nvidia-smi-load.csv.log) |

## Benchmark: baseline (no NetworkPolicy, no mTLS, no TLS)

Client: Job `sorami-lab-bench-baseline` in `sorami-lab-neighbor` (python:3.12-slim,
stdlib-only `bench/bench.py`), target the Service DNS on port 8000, streaming
`/v1/completions`, fixed prompt (~89 tokens), `max_tokens=128`, `ignore_eos`, temperature 0.
Warmup 8 requests, then 128 requests per level. Token counts come from server `usage`.
Run 2026-09-28T06:04:39Z to 06:26:46Z. Per-level JSON: [result-c1](../logs/2026-09-28-stageB-07-bench/result-c1.json),
[result-c4](../logs/2026-09-28-stageB-07-bench/result-c4.json), [result-c16](../logs/2026-09-28-stageB-07-bench/result-c16.json), [result-c32](../logs/2026-09-28-stageB-07-bench/result-c32.json);
table: [10-table.md](../logs/2026-09-28-stageB-07-bench/10-table.md); raw: [08-job-logs](../logs/2026-09-28-stageB-07-bench/08-job-logs.log).

| conc | ok/req | req/s | out tok/s | ttft p50 / p95 / p99 ms | tpot p50 / p95 / p99 ms | e2e p50 / p95 / p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.136 | 17.4 | 69.2 / 71.8 / 78.8 | 57.3 / 57.3 / 57.4 | 7344.9 / 7352.3 / 7354.6 |
| 4 | 128/128 | 0.531 | 67.9 | 121.9 / 122.9 / 153.3 | 58.4 / 58.5 / 58.5 | 7538.4 / 7546.8 / 7567.2 |
| 16 | 128/128 | 2.07 | 264.9 | 135.3 / 152.4 / 175.5 | 59.8 / 59.9 / 59.9 | 7725.3 / 7744.8 / 7765.4 |
| 32 | 128/128 | 3.807 | 487.2 | 173.9 / 192.6 / 217.5 | 64.7 / 64.9 / 65.1 | 8393.2 / 8430.3 / 8451.5 |

Reading: 0 failures. Decode is memory-bandwidth bound on the L4 (~57 ms/token single stream,
~17 tok/s). Batching scales throughput 28x from c=1 to c=32 while tpot rises only 13%, so
the engine was far from saturated at c=32 (the KV cache allows about 11x 8k-token requests,
and these requests use ~217 tokens each). Tail spread is tight (p99 within 3% of p50 for tpot
and e2e), which gives a low-noise baseline for measuring the network overhead of Stage D
layers. TTFT includes the pod-to-Service hop.

## GPU utilization evidence

64 `nvidia-smi` samples every ~20 s from inside the vLLM pod, 06:04:40Z to 06:26:46Z:
[04-nvidia-smi-load](../logs/2026-09-28-stageB-07-bench/04-nvidia-smi-load.csv.log). Snapshots:
[02-nvidia-smi-idle](../logs/2026-09-28-stageB-07-bench/02-nvidia-smi-idle.log), [06-nvidia-smi-during](../logs/2026-09-28-stageB-07-bench/06-nvidia-smi-during.log).

| Metric | Idle (06:04:40Z) | Under load, 63 samples (min / median / max) |
|---|---|---|
| GPU util | 0 % | 98 / 99 / 99 % |
| Memory util | 0 % | 100 / 100 / 100 % |
| Memory used | 21,196 MiB | 21,196 MiB (preallocated at 0.90) |
| Power | 27.98 W | 70.43 / 71.95 / 73.09 W (cap 72 W) |
| Temperature | 50 C | 59 / 82 / 83 C |

The L4 ran at its 72 W power cap and ~99 % utilization even at concurrency 1, which fits a
bandwidth-bound decode. `/metrics` snapshots: [before](../logs/2026-09-28-stageB-07-bench/01-metrics-before.log),
[during](../logs/2026-09-28-stageB-07-bench/05-metrics-during.log) (`num_requests_running 1`, `kv_cache_usage_perc 0.0015`
at c=1), [after](../logs/2026-09-28-stageB-07-bench/09-metrics-after.log).

## Security findings (neighbor re-probe, 2026-09-28T06:27Z)

Probe: `sorami-lab-neighbor` pod, uid 1000, `CapBnd 0000000000000000`, no SA token
([01-identity](../logs/2026-09-28-stageB-08-neighbor-reprobe/01-identity.log)). Target: engine pod `10.99.22.12` and Service DNS
`sorami-lab-vllm-engine.sorami-lab-stack-vllm.svc.cluster.local:8000` ([target](../logs/2026-09-28-stageB-08-neighbor-reprobe/target.txt)).
All calls are reads of the deployed model; nothing was changed.

| # | Finding | Evidence |
|---|---|---|
| B1 | **Unauthenticated OpenAI-compatible API reachable cluster-wide.** Cross-namespace, unprivileged, no token: `/v1/models` 200 lists the model; `/v1/chat/completions` returned "Reachable"; `/v1/completions` returned " Paris. Which of the following statements about" | [05-models](../logs/2026-09-28-stageB-08-neighbor-reprobe/05-models.log), [06-chat](../logs/2026-09-28-stageB-08-neighbor-reprobe/06-chat.log), [07-completions](../logs/2026-09-28-stageB-08-neighbor-reprobe/07-completions.log) |
| B2 | **Only 8000 is open, and it is everything.** nmap on the pod IP: 8000 open, 5678/8001/8080/9090/29500/51216 refused. `/openapi.json` lists **26 routes** on that one port, including `/v1/embeddings`, `/v1/responses`, `/v1/responses/{response_id}` (GET), `/v1/responses/{response_id}/cancel`, `/score`, `/rerank`, `/pooling`, `/classify`, `/invocations`, `/v1/audio/*`, `/scale_elastic_ep`, `/load`, `/version` | [02-portscan](../logs/2026-09-28-stageB-08-neighbor-reprobe/02-portscan.log), [13b-openapi-routes-parsed](../logs/2026-09-28-stageB-08-neighbor-reprobe/13b-openapi-routes-parsed.txt) |
| B3 | **`/tokenize` and `/detokenize` exposed.** A prompt with a fake MRN became 16 token ids; ids `[785,6722,315,9625,374]` detokenize to "The capital of France is". Anyone who obtains token ids (logs, traces, a KV transfer stream) can read the text back with no credentials | [08-tokenize](../logs/2026-09-28-stageB-08-neighbor-reprobe/08-tokenize.log), [09-detokenize](../logs/2026-09-28-stageB-08-neighbor-reprobe/09-detokenize.log) |
| B4 | **`/metrics` leaks workload telemetry** (66 metric families, no auth) | [11-metrics-counters](../logs/2026-09-28-stageB-08-neighbor-reprobe/11-metrics-counters.log), [12-metrics-names](../logs/2026-09-28-stageB-08-neighbor-reprobe/12-metrics-names.log) |
| B5 | **Plaintext on 8000**, pod IP and ClusterIP alike: `openssl s_client` gets `packet length too long`, `no peer certificate available` | [03-tls-podip](../logs/2026-09-28-stageB-08-neighbor-reprobe/03-tls-podip.log), [04-tls-svcdns](../logs/2026-09-28-stageB-08-neighbor-reprobe/04-tls-svcdns.log) |
| B6 | **No NetworkPolicy exists**, although the enforcing agent is on (`aws-eks-nodeagent --enable-network-policy=true`): `kubectl get networkpolicy -A` = `No resources found` | [14-netpol](../logs/2026-09-28-stageB-08-neighbor-reprobe/14-netpol.log), [15-netpol-agent](../logs/2026-09-28-stageB-08-neighbor-reprobe/15-netpol-agent.log) |

### B4 detail: what `/metrics` gives a neighbor

Values read by the neighbor right after the benchmark:

| Leaks | Counter(s) | Value seen |
|---|---|---|
| Total request volume and outcome | `request_success_total{finished_reason=stop,length,abort}` | 2 / 521 / 0 |
| Prompt and output token volume | `prompt_tokens_total`, `generation_tokens_total`, `request_prompt_tokens_sum/count`, `request_generation_tokens_sum/count` | 46,357 prompt / 66,574 generated over 523 requests |
| Requested max_tokens (client parameter) | `request_params_max_tokens_sum/count` | 66,584 / 523 |
| Live load (real-time activity signal) | `num_requests_running`, `num_requests_waiting`, `kv_cache_usage_perc` | 0 / 0 / 0.0 (1 running at c=1 during load) |
| Latency profile | `time_to_first_token_seconds_*`, `time_per_output_token_seconds_*`, `e2e_request_latency_seconds_*` | e2e sum 4,018 s over 523 |
| **Prefix cache hit ratio** (cross-tenant side channel) | `prefix_cache_queries_total`, `prefix_cache_hits_total` | 41,552 hits of 46,357 queries |
| Engine config | `cache_config_info` labels: block size, GPU blocks, gpu_memory_utilization, prefix-cache hash algo | 16, 5,865, 0.9, sha256 |

The prefix cache counters matter most: a neighbor who can both send prompts (B1) and read
`prefix_cache_hits_total` (B4) can test whether a guessed prompt prefix was recently served
for someone else, by watching the hit counter (or TTFT) move. That is **inferred, not
tested** here; it is a candidate Stage C/D experiment.

## Interpretation

Out of the box, a single vLLM engine is an open inference, tokenizer and telemetry service
to an ordinary pod in an unrelated namespace. The network is the only boundary, and in this baseline it has
no policy, no transport encryption and no authentication. The NetworkPolicy agent being on
changes nothing until a policy object exists, which matches Stage A for Ray and the router.

## Not done in Stage B

- No POST to `/v1/responses`, `/scale_elastic_ep` or `/v1/responses/{id}/cancel` (state
  changing or disruptive routes were only enumerated, not called).
- Prefix-cache side channel is inferred, not measured.
- Multi-node paths (KV transfer, NCCL, Ray between GPU workers) need a second GPU node: Stage C.

## Cleanup and end state (2026-09-28T06:37Z to 06:49Z)

| Step | Result | Evidence |
|---|---|---|
| Plan with `-var gpu_desired=0 -var gpu_ondemand_desired=0` | In-place `desired_size 2 -> 0` only, which the API rejects with 409 on a `CREATE_FAILED` group | [01-tf-plan](../logs/2026-09-28-stageB-09-gpu-cleanup/01-tf-plan.log) |
| Plan with `-replace=aws_eks_node_group.gpu` | `1 to add, 0 to change, 1 to destroy`, only `sorami-lab/sorami-lab-gpu-spot` | [02-tf-plan-replace](../logs/2026-09-28-stageB-09-gpu-cleanup/02-tf-plan-replace.log) |
| Apply | Destroy 10m12s (drained and terminated the g6 spot node), create 47s at desired 0 | [03-tf-apply](../logs/2026-09-28-stageB-09-gpu-cleanup/03-tf-apply.log) |
| End state | `gpu-spot` ACTIVE 0/4, `gpu-ondemand` ACTIVE 0/1, `cpu-spot` ACTIVE 2/3; **no GPU instances pending or running**; follow-up plan `No changes` | [04-state-after](../logs/2026-09-28-stageB-09-gpu-cleanup/04-state-after.log), [05-tf-plan-drift](../logs/2026-09-28-stageB-09-gpu-cleanup/05-tf-plan-drift.log) |

The `sorami-lab-vllm-engine` Deployment stays in place but its pod is `Pending` (no GPU
node). That costs nothing: managed node groups do not scale from pending pods without a
cluster autoscaler, and none is installed. The next GPU run is `terraform apply -var
gpu_desired=1` (or `-var gpu_ondemand_desired=1`), and the pod will schedule itself.

## Operational notes

- A managed node group in `CREATE_FAILED` keeps its one successful instance, but every
  `UpdateNodegroupConfig` returns 409. The only way to converge is `terraform apply
  -replace=...`; a plain plan shows a misleading in-place update.
- In the bench Job manifest, `env: - name: N` failed: YAML 1.1 parses a bare `N` as boolean
  false (`cannot unmarshal bool into ... EnvVar.name`). Quoting it as `"N"` fixed it.
