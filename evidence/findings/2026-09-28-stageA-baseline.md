# Stage A baseline: vendor defaults, neighbor-pod view (2026-09-28)

Cluster `sorami-lab` (dedicated VPC `10.99.0.0/16`), CPU spot nodes only, GPU pool at 0.
No NetworkPolicy objects exist (vendor-default baseline). Every target IP came from the
API allowlist, never a CIDR: [allowlist.txt](../logs/2026-09-28-stageA-06-neighbor/allowlist.txt).

## Versions under test

| Component | Version |
|---|---|
| KubeRay operator + ray-cluster chart | 1.7.1 |
| Ray in default image | 2.52.0 (reported by `/api/version`) |
| vLLM production-stack chart | 0.1.12 |
| Pending (GPU needed) | vLLM engine, SGLang 0.5.20, Triton 2.72.0 |

Logs: [versions](../logs/2026-09-28-stageA-02-versions/), [rendered defaults](../logs/2026-09-28-stageA-03-render/), [install](../logs/2026-09-28-stageA-04-install-defaults/).

## Probe identity

Namespace `sorami-lab-neighbor`, uid 1000, no SA token, all capabilities dropped
(`CapBnd 0`). Log: [probe-identity](../logs/2026-09-28-stageA-06-neighbor/probe-identity.log).

## Reachability (full TCP connect scan, 7.6 s, 4 hosts)

Log: [nmap-full-tcp](../logs/2026-09-28-stageA-06-neighbor/nmap-full-tcp.log).

| Target | Open ports seen by the neighbor |
|---|---|
| Ray head | 6379 (GCS), 8080, 8265 (dashboard/jobs), 10001 (client), plus 7 ephemeral RPC ports |
| Ray worker | 8080, plus 5 ephemeral ports (incl. 52365 agent) |
| KubeRay operator | 8080 (metrics), 8082 (probes) |
| vLLM router | 8000 |

Only 1 of 7 Ray head ports and 1 of 6 worker ports is declared in the pod spec
(`containerPort 8080`). The rest are undeclared, so declared-port NetworkPolicy
reviews and static scanners never see them.

## Handshakes (read-only)

Log: [handshakes](../logs/2026-09-28-stageA-06-neighbor/handshakes.log). No POST, no job submission.

| Surface | Result | Auth | TLS |
|---|---|---|---|
| Ray dashboard `8265 /api/version` | 200, returns Ray version, commit, session name | none | no (plaintext HTTP) |
| Ray `8265 /api/jobs/` | 200, empty list | none | no |
| Ray `8265 /nodes?view=summary` | 200, 17 KB: hostnames, IPs, CPU and memory of every node | none | no |
| Ray GCS 6379 | TCP accepted, not Redis protocol (no PONG), plaintext | unverified | no |
| Ray client 10001 | TCP accepted | unverified | no |
| Ray ephemeral RPC ports | TCP accepted | unverified | no |
| Ray metrics 8080 head/worker | 200, 143 KB / 42 KB Prometheus | none | no |
| KubeRay operator 8080 / 8082 | 200 | none | no |
| vLLM router `/health`, `/v1/models`, `/metrics` | 200 (no engines yet, list empty) | none | no |

"TLS no" means `openssl s_client` got a non-TLS reply (`wrong version number` or `packet length too long`).

## Configuration

| Check | Result | Log |
|---|---|---|
| NetworkPolicy shipped by any chart | none | [netpol](../logs/2026-09-28-stageA-05-inventory/netpol.log) |
| SA token automount | default (true) on all 4 pods | [sa-automount](../logs/2026-09-28-stageA-05-inventory/sa-automount.log) |
| `runAsNonRoot` set | none of 4 pods | same |
| Ray pods ServiceAccount | `default` | same |

## Interpretation (so far)

The Ray dashboard on 8265 is also the Job Submission API. A GET without credentials worked,
so a neighbor pod can very likely submit a job too, which means running code on the cluster.
That is **inferred, not tested**: we did not POST, by design. Ray's docs say the dashboard
must not be exposed to untrusted networks; the default chart does nothing to restrict it
inside the cluster.

## Not yet done

- Static scanners (trivy, checkov, kubescape, kube-linter) as in-cluster Jobs.
- vLLM engine, SGLang, Triton: need the GPU pool (Stage B).

## RBAC (read-only `auth can-i`)

Logs: [stageA-07-rbac](../logs/2026-09-28-stageA-07-rbac/).

| ServiceAccount | Finding |
|---|---|
| `kuberay-operator` | ClusterRole grants `secrets` create/delete/get/list/update/watch **cluster-wide**. `can-i list secrets -A` = yes |
| `vllm-router-service-account` | `pods` get/watch/list/**patch** in its namespace (used for engine discovery) |
| Ray `default` SA | no resource permissions beyond discovery; token still mounted |

Combined with the unauthenticated job API: a job runs in Ray pods (default SA, little RBAC),
not in the operator, so the job path does not directly inherit the operator's Secret access.
Unverified whether any path reaches the operator token.
