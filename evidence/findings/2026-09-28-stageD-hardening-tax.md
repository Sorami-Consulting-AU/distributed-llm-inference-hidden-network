# Stage D: hardening layers and the performance tax

Date: 2026-09-28 (UTC). Cluster: `sorami-lab` (EKS, ap-southeast-2).
L0, L1, L2a and L3 use the Stage C topology (Ray PP=2, A10G head + T4 worker,
Qwen2.5-1.5B-Instruct, placement pinned identical across these layers). L2b (WireGuard) ran
later the same day on a different GPU pair (2 x g5.xlarge, A10G + A10G) with its own
same-session L0 bracket, so its absolute numbers are not comparable to the other layers
(see [L2b section](#l2b-cilium-wireguard-pod-to-pod-encryption-measured)). Cross-links: Stage A
[stageA-baseline](./2026-09-28-stageA-baseline.md), Stage B
[stageB-baseline](./2026-09-28-stageB-baseline.md), Stage C
[stageC-distributed](./2026-09-28-stageC-distributed.md), report [sorami.com.au](https://sorami.com.au/research/distributed-llm-inference-hidden-network/), charts [summary.html](../summary.html).

Audit corrections (2026-09-29). Two external audits were checked against the raw logs; the report's
Appendix D has the full accepted / partly / rejected table. Key corrections mirrored here:

- L3 is not authentication closure. The API key rejected ordinary requests on two `/v1` routes
  (`/v1/models`, `/v1/completions`). The other routes were not tested, and the engine
  `vllm/vllm-openai:v0.11.0` is in the affected range (>=0.3.0, <0.22.0) of CVE-2026-48746 /
  GHSA-94f4-hr76-p5j6 (CVSS 9.1, published 2026-06-02), a Host-header API-key bypass that does
  not affect deployments behind an RFC-conforming proxy such as nginx. Ours was exposed directly.
  The tested version was publicly known to be bypassable at experiment time. The bypass was not
  tested. Sources: https://github.com/advisories/GHSA-94f4-hr76-p5j6 ,
  https://osv.dev/vulnerability/CVE-2026-48746 .
- L1 is ingress-only: `manifests/stageD-L1-networkpolicy.yaml` line 22 `policyTypes: ["Ingress"]`,
  and line 11 records egress left open on purpose. It does not show containment of a compromised
  engine. The VPC CNI `NETWORK_POLICY_ENFORCING_MODE` value was not recorded (only the variable
  name is in `01-vpccni-encryption-options.log`), so a default-allow startup window under the
  default `standard` mode is unmeasured
  (https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html).
- L2a: the tested Linkerd configuration failed to carry the vLLM workload; the root cause was not
  isolated. The Linkerd version and proxy logs were not kept. This is not a demonstrated
  incompatibility.
- L0-after is not a proven Cilium-free baseline: `24-bracket-state.log` shows the Cilium agent
  running with encryption off (no `cilium_wg0`) during L0-after, the final uninstall
  (`30-cilium-uninstall-final.log`) was at 13:22:22Z, the head pod was not a Cilium endpoint, and
  the worker was not checked.
- Raw per-request samples were never persisted: `bench/bench.py` line 119 writes
  `{"summary","raw"}` in the pod, but `manifests/stageB-bench-job.yaml` line 49 prints only
  `['summary']`. No distributions or confidence intervals are possible.
- Ray token authentication (`RAY_AUTH_MODE=token`, from Ray 2.52.0, off by default) was available
  and not evaluated (https://docs.ray.io/en/latest/ray-security/token-auth.html).
- The stale-conflist incident was an incomplete removal procedure with the documented chart
  default `cni.uninstall=false`, not Cilium misbehaving.
- Harness paths are relative to the `test-harness/` folder of this repository.

## What each layer applied

| Layer | What | Manifest / mechanism | Status |
|---|---|---|---|
| L0 | Control: distributed baseline, no hardening | `manifests/stageC-ray-pp.yaml` | measured |
| L1 | NetworkPolicy default-deny ingress + explicit allows (ingress only, egress open) | `manifests/stageD-L1-networkpolicy.yaml` (VPC CNI netpol agent) | measured; steady-state ingress blocking shown from the neighbour |
| L2a | Pod-to-pod encryption (Linkerd mTLS) | Linkerd control plane + proxy inject | attempted; the tested configuration failed to carry the vLLM workload, root cause not isolated (see below) |
| L2b | Pod-to-pod encryption (Cilium 1.20.2 WireGuard, chained on AWS VPC CNI) | `manifests/stageD-L2b-cilium-values.yaml` (test-harness) | measured with same-session L0 bracket, encryption shown by interface counters |
| L3 | Engine `--api-key` auth on top of L1 | `manifests/stageC-ray-pp.yaml` (VLLM_API_KEY from secret) | measured; two `/v1` routes reject requests without the key; not authentication closure (CVE-2026-48746 range, other routes untested) |

Data-integrity correction (2026-09-28T13:30Z): all four `result-c*.json` in
`logs/2026-09-28-stageD-00-L0/` are byte-identical (`cmp`) to `logs/2026-09-28-stageC-06-bench/`.
So there was no same-session L0 for L1 and L3; their deltas are cross-session against Stage C.
L2b was measured with its own fresh L0 before and after, on the same nodes.

## Security observations (scoped to what was probed)

### L1 blocks cross-namespace ingress to the Ray control plane (ingress only)

Stage C proved the neighbor pod could reach Ray GCS 6379 and raylet 10002 to 10006 across
namespaces. After L1, the exact same probes from the same neighbor pod fail. Evidence:
`logs/2026-09-28-stageD-01-L1/01-reprobe-after-L1.log`.

| Target/port | Stage C (pre) | After L1 |
|---|---|---|
| head 6379 (GCS) | OPEN | BLOCKED |
| head 10002 to 10006 (raylet) | OPEN | BLOCKED |
| head 8000 (vLLM API, intended path) | OPEN | OPEN (kept, by design) |
| worker 10002 (raylet) | OPEN | BLOCKED |

Scope: ingress only, steady state, one neighbour pod. No egress policy and no egress test, so
this says nothing about containing a compromised engine.

Operational note: applying default-deny to the LIVE Ray cluster reset established
conntrack and forced a one-time pod restart; the cluster recovered and re-formed its Ray
connections under the policy, after which the benchmark ran clean. Program the policy
before or with a fresh engine to avoid the restart.

### L3 rejects unauthenticated requests on two `/v1` routes (not authentication closure)

Stage C proved `/v1/models` and `/v1/completions` returned 200 to the neighbor with no
credentials. After L3 (`--api-key`), unauthenticated and wrong-key calls return 401 and
only the correct bearer token returns 200. Evidence:
`logs/2026-09-28-stageD-03-L3/01-auth-proof.log`.

| Call | Stage C (pre) | After L3 |
|---|---|---|
| no key /v1/models | 200 | 401 |
| no key /v1/completions | 200 | 401 |
| wrong key /v1/models | 200 | 401 |
| correct key /v1/completions | n/a | 200 |

Not tested: the other 24 routes from `/openapi.json`, and the CVE-2026-48746 Host-header bypass,
which applies to v0.11.0. The key also travels in cleartext.

### L2a (Linkerd mTLS): the tested configuration failed to carry the workload

This is a configuration-specific negative result: the tested Linkerd configuration failed to
carry the vLLM workload. The root cause was not isolated, and the Linkerd version and proxy logs
were not kept, so it is not evidence that Linkerd is incompatible with vLLM or SSE.

Linkerd edge was installed cleanly: control plane Ready, trust anchor and issuer certs
minted, and both engine pods were meshed with an issued workload identity
(`default.sorami-lab-stack-vllm.serviceaccount.identity.linkerd.cluster.local`). Ray
stayed healthy with the Ray control ports (6379, 10002 to 10010) excluded from the proxy,
and in-pod generation worked. However, client traffic to the vLLM 8000 serving port could
not pass through the proxy: L7 HTTP routing returned 503 "route default.http: service
unavailable" and opaque L4 mode reset the connection before the inbound proxy saw it (both
from the outcome note, not captured proxy logs). Node-to-node WireGuard (VPC CNI or Cilium) was not installable in place
without CNI surgery on a running cluster in the main session; it was done later as a
separate, scoped experiment (L2b below). So L2a has a security mechanism demonstrated (mTLS
identity issued, pods meshed) but NO clean benchmark; its performance tax is not reported
rather than reported wrong. Evidence:
[05-l2-outcome.md](../logs/2026-09-28-stageD-02-L2/05-l2-outcome.md).

### L2b Cilium WireGuard pod-to-pod encryption (measured)

Why this path: the AWS VPC CNI addon (`v1.22.4-eksbuild.3`) has no encryption setting
([01-vpccni-encryption-options](../logs/2026-09-28-stageD-04-L2-wireguard/01-vpccni-encryption-options.log)).
Replacing the CNI on a live cluster was rejected as too invasive. Cilium in `aws-cni`
chaining mode keeps VPC CNI IPAM and pod IPs and only takes over pods created after install,
so the blast radius was the recreated engine pods.

Evidence dir: [stageD-04-L2-wireguard](../logs/2026-09-28-stageD-04-L2-wireguard/).
Decision record: [02-decision.md](../logs/2026-09-28-stageD-04-L2-wireguard/02-decision.md).

Setup. The AWS VPC CNI addon (`v1.22.4-eksbuild.3`) has no encryption option, so Cilium
1.20.2 was installed in CNI chaining mode (`cni.chainingMode=aws-cni`, native routing, no
masquerade, `kubeProxyReplacement=false`, `policyEnforcementMode=never`,
`encryption.type=wireguard`, `nodeEncryption=false`). VPC CNI keeps IPAM; only pods created
after install are Cilium-managed. The L1 NetworkPolicies were removed for this experiment
([06-remove-L1-netpol](../logs/2026-09-28-stageD-04-L2-wireguard/06-remove-L1-netpol.log))
and restored at the end
([32-restore-L1-netpol](../logs/2026-09-28-stageD-04-L2-wireguard/32-restore-L1-netpol.log)).
No API key in any of the three runs.

Hardware. On-demand capacity returned 2 x g5.xlarge (A10G + A10G), not the Stage C g5 +
g4dn (A10G + T4) pair. Head on `ip-10-99-17-131`, worker on `ip-10-99-38-120` in all three
runs (`00-target.log` in each bench dir). Absolute numbers here are NOT comparable to L0/L1/L3
above (for example c32 is about 1180 tok/s here against 429 tok/s on the T4 pair). Only the
within-session deltas below are meaningful.

Order and timing (UTC, one run each, 128 req per level, all 128/128 ok at every level):

| Run | Bench window | Engine pods | Result files |
|---|---|---|---|
| L0-before | 12:13:11 to 12:21:07 | plain VPC CNI, no encryption | [bench-L0-before](../logs/2026-09-28-stageD-04-L2-wireguard/bench-L0-before/) |
| L2b | 12:27:23 to 12:35:42 | Cilium chained + WireGuard | [bench-L2b](../logs/2026-09-28-stageD-04-L2-wireguard/bench-L2b/) |
| L0-after | 13:13:40 to 13:22:00 | Cilium present, encryption disabled, no `cilium_wg0` | [bench-L0-after](../logs/2026-09-28-stageD-04-L2-wireguard/bench-L0-after/) |

Note on L0-after: after the stale-conflist breakage (see operational finding below), Cilium
was reinstalled with `encryption.enabled=false` and `cni.uninstall=true`
([23-cilium-reinstall-noenc](../logs/2026-09-28-stageD-04-L2-wireguard/23-cilium-reinstall-noenc.log)).
The bracket-state check shows `Encryption: Disabled` and `no-cilium_wg0-interface`
([24-bracket-state](../logs/2026-09-28-stageD-04-L2-wireguard/24-bracket-state.log)), and the
L0-after head pod IP `10.99.29.161` is not in the Cilium endpoint list (grep returned only the
header row), consistent with the stale conflist having been renamed at 13:09Z so new pods
used plain `10-aws.conflist`. The worker pod was not checked the same way, and the Cilium agent
stayed installed and running through L0-after until the final uninstall at 13:22:22Z
([30-cilium-uninstall-final](../logs/2026-09-28-stageD-04-L2-wireguard/30-cilium-uninstall-final.log)).
So L0-after is a no-encryption control but not a proven Cilium-free baseline. If the worker was a
Cilium endpoint, the bracket mean understates the tax.

Provenance: the conflist rename (`22-remove-stale-cilium-conflist.log`, 13:09Z) and the GPU
scale-down (`23-tf-plan-gpu0.log`, `24-tf-apply-gpu0.log`, `25-gpu-zero-verify.log`, 13:22 to
13:24Z) were done by the same study team in a parallel control session, not the session
that ran the benches; see
[60-encryption-proof-and-outcome.md](../logs/2026-09-28-stageD-04-L2-wireguard/60-encryption-proof-and-outcome.md).
The L0-after sweep finished at 13:22:00Z, before GPU instances began draining.

L0-before (fresh same-session control, no NetworkPolicy, no encryption, no auth):

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.397 | 50.8 | 29.2 / 33.6 / 38.7 | 19.6 / 20.4 / 20.6 | 2522.0 / 2619.5 / 2655.0 |
| 4 | 128/128 | 1.458 | 186.7 | 40.5 / 56.1 / 105.0 | 21.2 / 22.0 / 22.2 | 2730.1 / 2830.7 / 2860.3 |
| 16 | 128/128 | 5.313 | 680.1 | 51.8 / 88.2 / 100.4 | 23.1 / 23.9 / 24.0 | 2984.8 / 3102.8 / 3104.9 |
| 32 | 128/128 | 9.217 | 1179.8 | 75.8 / 144.2 / 149.5 | 26.6 / 27.9 / 27.9 | 3434.3 / 3615.4 / 3617.3 |

L2b (Cilium chained on VPC CNI + WireGuard, no NetworkPolicy, no auth):

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.381 | 48.7 | 31.4 / 35.0 / 37.4 | 20.4 / 21.2 / 21.7 | 2618.4 / 2720.4 / 2783.1 |
| 4 | 128/128 | 1.400 | 179.2 | 43.4 / 65.8 / 117.5 | 22.1 / 23.0 / 23.2 | 2853.9 / 2967.0 / 2991.4 |
| 16 | 128/128 | 4.986 | 638.2 | 60.6 / 80.3 / 100.5 | 24.9 / 25.2 / 25.3 | 3216.2 / 3264.9 / 3270.0 |
| 32 | 128/128 | 8.726 | 1116.9 | 97.2 / 125.8 / 158.1 | 28.4 / 28.8 / 28.9 | 3665.8 / 3759.8 / 3763.1 |

L0-after (drift bracket, no WireGuard, same nodes):

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.392 | 50.1 | 28.8 / 33.3 / 36.0 | 19.8 / 20.7 / 21.0 | 2550.2 / 2659.0 / 2696.5 |
| 4 | 128/128 | 1.441 | 184.4 | 41.2 / 49.6 / 116.4 | 21.5 / 22.3 / 22.4 | 2766.7 / 2872.7 / 2880.1 |
| 16 | 128/128 | 5.131 | 656.8 | 57.3 / 90.9 / 100.0 | 24.2 / 24.9 / 24.9 | 3119.8 / 3210.1 / 3214.2 |
| 32 | 128/128 | 9.445 | 1209.0 | 57.5 / 150.7 / 178.7 | 25.8 / 27.1 / 27.2 | 3326.8 / 3596.7 / 3626.6 |

WireGuard tax (L2b versus the mean of L0-before and L0-after; drift is L0-after versus L0-before):

| conc | out tok/s L0 mean | L2b | tax | L0-to-L0 drift | e2e p50 L0 mean ms | L2b ms | tax | L0-to-L0 drift |
|---|---|---|---|---|---|---|---|---|
| 1 | 50.45 | 48.7 | -3.5% | -1.4% | 2536.1 | 2618.4 | +3.2% | +1.1% |
| 4 | 185.55 | 179.2 | -3.4% | -1.2% | 2748.4 | 2853.9 | +3.8% | +1.3% |
| 16 | 668.45 | 638.2 | -4.5% | -3.4% | 3052.3 | 3216.2 | +5.4% | +4.5% |
| 32 | 1194.4 | 1116.9 | -6.5% | +2.5% | 3380.6 | 3665.8 | +8.4% | -3.1% |

TPOT p50 tax (same method): +3.6% / +3.5% / +5.3% / +8.4% at c1/4/16/32.

Full metric-by-metric table (including ttft, e2e p95, and tax vs L0-before only):
[50-wireguard-tax.md](../logs/2026-09-28-stageD-04-L2-wireguard/50-wireguard-tax.md).

Reading the tax. The L0-to-L0 drift is up to about 3.4% on throughput (c16), so the c1/c4
tax (-3.5% / -3.4%) is within drift; c16/c32 (-4.5% / -6.5%) is outside it. (Per level, the
c1/c4 drift is smaller, 1.4% and 1.2%, but with n=1 the conservative bar is the largest drift
seen in the session.) On e2e p50 the
L0-to-L0 drift is larger at c16 (+4.5%), so the c16 e2e tax (+5.4%) is only marginally
outside drift, and c32 (+8.4%) is the one clearly outside it. Direction is consistent: L2b
is slower than both L0 runs at every level on throughput, e2e p50 and TPOT p50. Tail
latency does not show a clean signal (for example TTFT p95 at c32 is lower under L2b than
under either L0), so no tail-latency tax is claimed. n=1 per level, so no confidence
intervals.

Honest headline: pod-to-pod WireGuard (via Cilium chaining) carried the vLLM SSE streaming
path cleanly (512 of 512 ok), and cost about 3 to 8% on this topology, rising with
concurrency. At low concurrency the cost cannot be separated from session drift.

Confound: this is Cilium chaining + WireGuard combined, not WireGuard alone. L2b ran with
Cilium's eBPF datapath chained behind aws-cni plus WireGuard. A Cilium-no-encryption bench
was attempted but not completed: `helm upgrade --set encryption.enabled=false` did not
restart the agents, so `cilium-dbg` still reported WireGuard active and that revision was
discarded
([17-cilium-disable-wg](../logs/2026-09-28-stageD-04-L2-wireguard/17-cilium-disable-wg.log));
the engine pods were recreated
([18-recreate-engine-cilium-noenc](../logs/2026-09-28-stageD-04-L2-wireguard/18-recreate-engine-cilium-noenc.log))
but no bench directory exists for that state, and Cilium was then uninstalled
([19-cilium-uninstall](../logs/2026-09-28-stageD-04-L2-wireguard/19-cilium-uninstall.log)).
So the Cilium-chaining share of the tax was not isolated.

GPU utilisation (nvidia-smi every ~20 s, min / median / max, head A10G and worker A10G):

| Run | Samples | Head util % | Worker util % |
|---|---|---|---|
| L0-before | 22 | 0 / 18 / 20 | 0 / 23 / 27 |
| L2b | 23 | 0 / 18 / 20 | 0 / 22 / 26 |
| L0-after | 23 | 15 / 18 / 33 | 19 / 23 / 39 |

Neither GPU approaches saturation in any run, so the pipeline is not compute-bound and an
inter-node network cost can show up in TPOT.

#### L2b security proof: WireGuard is on the path (interface counters, not pcap)

Agent status on the head and worker nodes: `Encryption: Wireguard [NodeEncryption: Disabled,
cilium_wg0 ..., Port: 51871, Peers: 3]`, `CNI Chaining: aws-cni`, recent handshakes with all
three peers
([12-cilium-encryption-status](../logs/2026-09-28-stageD-04-L2-wireguard/12-cilium-encryption-status.log)).
UDP 51871 bound on the node
([16-wg-udp-socket-and-cni](../logs/2026-09-28-stageD-04-L2-wireguard/16-wg-udp-socket-and-cni.log)).

Counter proof: a 50 MiB transfer of a repeated ASCII marker from the head pod to the worker
pod (`10.99.33.127:45555`) at 12:26:48Z
([13-wg-counter-proof](../logs/2026-09-28-stageD-04-L2-wireguard/13-wg-counter-proof.log)):

| Head-node counter | Before | After | Delta |
|---|---|---|---|
| bytes sent by head pod / received by worker pod | n/a | 55,189,000 / 55,189,000 | 55.19 MB |
| `cilium_wg0` tx_bytes | 651,048 | 56,438,648 | +55.79 MB |
| `ens5` tx_bytes | 641,459,248 | 697,520,489 | +56.06 MB |

The pod-to-pod bytes went into the WireGuard interface (about 0.6 MB over payload, which fits
TCP/IP headers), and the ENI grew by a matching amount plus tunnel overhead. During the L2b
bench window the head `cilium_wg0` tx grew 572.5 MB and the worker `cilium_wg0` rx grew
546.7 MB
([14](../logs/2026-09-28-stageD-04-L2-wireguard/14-wg-counters-before-bench.log),
[15](../logs/2026-09-28-stageD-04-L2-wireguard/15-wg-counters-after-bench.log)), so the
inference pipeline traffic crossed the tunnel too.

Limitation: this is interface-counter evidence that traffic was routed into the WireGuard
device. It is NOT a packet capture showing ciphertext on the ENI (no tcpdump showing absence
of the marker string or the cleartext HTTP/2 SETTINGS preface). The claim is "routed through
`cilium_wg0`", which on a standard kernel WireGuard device implies encryption, but the
ciphertext itself was not observed. The Cilium agent image has no tcpdump and no privileged
node shell was available.

Scope: WireGuard encrypts the node-to-node wire only. It does NOT close the Stage C
cross-namespace reachability: a neighbor pod can still open Ray 6379 at the socket, because
WireGuard decrypts before delivery. L2b complements L1; it does not replace it.

Second operational note: `helm upgrade --set encryption.enabled=false` rewrote the
ConfigMap but did not restart the agents, so WireGuard stayed active
([17-cilium-disable-wg](../logs/2026-09-28-stageD-04-L2-wireguard/17-cilium-disable-wg.log)).
Toggle encryption by restarting the DaemonSet or reinstalling, and confirm with
`cilium-dbg status`.

#### Operational finding: an incomplete Cilium removal procedure breaks new pod sandboxes

This was a gap in the removal procedure, not Cilium misbehaving: Cilium was installed with the
documented chart default `cni.uninstall=false`. `helm uninstall cilium`
([19-cilium-uninstall](../logs/2026-09-28-stageD-04-L2-wireguard/19-cilium-uninstall.log),
12:41:16Z) removed the agents but left `/etc/cni/net.d/05-cilium.conflist` on ALL four nodes,
including the two CPU nodes that never ran an engine pod
([22-remove-stale-cilium-conflist](../logs/2026-09-28-stageD-04-L2-wireguard/22-remove-stale-cilium-conflist.log)).
It sorts before `10-aws.conflist`, so containerd kept calling `cilium-cni`, and every new pod
sandbox failed with:

`plugin type="cilium-cni" failed (add): unable to connect to Cilium agent ... dial unix /var/run/cilium/cilium.sock: connect: no such file or directory`

([22-stale-cni-conflist-breakage](../logs/2026-09-28-stageD-04-L2-wireguard/22-stale-cni-conflist-breakage.log)).
Window: from about 12:41Z (uninstall) to 13:09Z, when the file was renamed to
`05-cilium.conflist.disabled-after-uninstall` on each node. Existing pods kept running; only
new sandboxes were affected. The final uninstall at 13:22:22Z used a release with
`cni-uninstall=true`
([30-cilium-uninstall-final](../logs/2026-09-28-stageD-04-L2-wireguard/30-cilium-uninstall-final.log)),
and a sanity pod scheduled on a CPU node afterwards reached `cni-ok`
([31-cni-sanity-pod](../logs/2026-09-28-stageD-04-L2-wireguard/31-cni-sanity-pod.log)).

Takeaway: anyone trialling Cilium chaining on EKS needs an explicit CNI cleanup step. Either
install with `cni.uninstall=true` from the start (and confirm the agents restarted with it),
or remove `05-cilium.conflist` on every node after `helm uninstall`, then verify with a
throwaway pod on each node pool.

#### L2b teardown

GPU on-demand group scaled 2 to 0 (`desired_size = 2 -> 0`,
[23-tf-plan-gpu0](../logs/2026-09-28-stageD-04-L2-wireguard/23-tf-plan-gpu0.log),
[24-tf-apply-gpu0](../logs/2026-09-28-stageD-04-L2-wireguard/24-tf-apply-gpu0.log)); the
apply landed about 13:22Z and the instance poll went 2, 1, 0 between 13:24:13Z and
13:24:54Z, with zero GPU instances at 13:24:54Z
([25-gpu-zero-verify](../logs/2026-09-28-stageD-04-L2-wireguard/25-gpu-zero-verify.log)).
A follow-up plan showed no changes
([40-tf-plan-gpu0](../logs/2026-09-28-stageD-04-L2-wireguard/40-tf-plan-gpu0.log)) and both
GPU groups were at desired 0 with only two m6a.xlarge CPU instances running at 13:28:54Z
([41-gpu-zero-verify](../logs/2026-09-28-stageD-04-L2-wireguard/41-gpu-zero-verify.log)).
L1 NetworkPolicies restored at 13:23:06Z
([32-restore-L1-netpol](../logs/2026-09-28-stageD-04-L2-wireguard/32-restore-L1-netpol.log)).

## Per-layer benchmark tables

Client `bench/bench.py`, warmup then 128 requests per concurrency level, run from the
neighbor namespace. All measured layers had 0 failures across 512 requests.

### L0 distributed baseline (no NetworkPolicy, no mTLS, no TLS)

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.269 | 34.4 | 38.2 / 47.7 / 51.4 | 28.9 / 31.3 / 32.7 | 3712.4 / 4026.4 / 4186.3 |
| 4 | 128/128 | 0.927 | 118.7 | 59.7 / 386.4 / 7397.3 | 32.1 / 34.1 / 34.3 | 4138.9 / 4497.6 / 11748.2 |
| 16 | 128/128 | 3.198 | 409.4 | 81.5 / 798.5 / 800.8 | 37.3 / 41.7 / 41.7 | 4807.4 / 5795.4 / 5797.1 |
| 32 | 128/128 | 3.353 | 429.2 | 474.6 / 10024.8 / 10028.8 | 54.0 / 56.7 / 131.1 | 7330.0 / 16881.9 / 16899.2 |

### L1 NetworkPolicy (default-deny + allow 8000)

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.271 | 34.6 | 38.0 / 47.9 / 49.4 | 28.7 / 31.0 / 31.8 | 3685.8 / 3979.5 / 4074.5 |
| 4 | 128/128 | 1.011 | 129.5 | 60.4 / 91.9 / 405.4 | 30.7 / 32.4 / 32.8 | 3954.7 / 4176.5 / 4572.8 |
| 16 | 128/128 | 3.109 | 398.0 | 92.7 / 986.9 / 988.2 | 37.2 / 42.5 / 42.5 | 4801.9 / 6079.6 / 6082.1 |
| 32 | 128/128 | 4.444 | 568.8 | 165.1 / 837.0 / 839.3 | 54.1 / 54.5 / 57.4 | 7031.6 / 7760.3 / 7776.2 |

### L3 NetworkPolicy + engine api-key auth

| conc | ok/req | req/s | out tok/s | ttft p50/p95/p99 ms | tpot p50/p95/p99 ms | e2e p50/p95/p99 ms |
|---|---|---|---|---|---|---|
| 1 | 128/128 | 0.268 | 34.3 | 38.6 / 48.4 / 51.5 | 29.0 / 31.5 / 32.3 | 3717.9 / 4044.7 / 4138.7 |
| 4 | 128/128 | 0.952 | 121.9 | 61.1 / 385.8 / 7405.5 | 30.8 / 32.5 / 32.7 | 3970.0 / 4487.8 / 11537.1 |
| 16 | 128/128 | 2.555 | 327.0 | 73.4 / 10606.2 / 10624.3 | 37.0 / 40.3 / 41.8 | 4776.7 / 15584.5 / 15604.3 |
| 32 | 128/128 | 4.346 | 556.2 | 218.0 / 786.5 / 1028.2 | 54.0 / 61.5 / 61.5 | 7174.6 / 8597.5 / 8599.4 |

## Consolidated hardening tax (headline result)

Two baselines, not mixable:

- L1 and L3 are CROSS-SESSION against the Stage C run on A10G + T4 (the old L0 files are
  byte-identical copies of [stageC-06-bench](../logs/2026-09-28-stageC-06-bench/)). n=1 per
  level. Their deltas are observed differences, not layer effects.
- L2b is SAME-SESSION on 2 x A10G, measured against the MEAN of a fresh L0 before and an L0
  after (drift bracket). Its absolute values are not comparable to the L0 row of the other
  layers; only the percent delta is.
- L2a (Linkerd) has no benchmark: the proxy could not carry the serving port.

Positive on throughput means higher than baseline; positive on latency means slower.

| Layer | Baseline | c16 out tok/s | c16 e2e p50 | c32 out tok/s | c32 e2e p50 | Reading |
|---|---|---|---|---|---|---|
| L1 NetworkPolicy | Stage C L0, cross-session | -2.8% | -0.1% | +32.5% | -4.1% | no measurable penalty within cross-session variance, n=1 (the +32.5% is L0 stall variance, not a speedup) |
| L2a Linkerd mTLS | n/a | not measured | not measured | not measured | not measured | tested configuration failed, 0/128 ok (503), root cause not isolated |
| L2b Cilium chaining + WireGuard | mean of same-session L0 before/after | -4.5% | +5.4% | -6.5% | +8.4% | consistent cost; outside L0-to-L0 drift at c16/c32 on throughput |
| L3 NetPol + api-key | Stage C L0, cross-session | -20.1% | -0.6% | +29.6% | -2.1% | no measurable penalty within cross-session variance, n=1 |

L2b at all levels (vs mean of both L0 runs): throughput -3.5 / -3.4 / -4.5 / -6.5% and e2e
p50 +3.2 / +3.8 / +5.4 / +8.4% at c1 / c4 / c16 / c32. Largest L0-to-L0 drift: about 3.4% on
throughput (c16) and 4.5% on e2e p50 (c16).

Raw values for L1 and L3 against the Stage C L0:

| conc | Layer | out tok/s | e2e p50 ms | e2e p95 ms |
|---|---|---|---|---|
| 16 | L0 (Stage C) | 409.4 | 4807.4 | 5795.4 |
| 16 | L1 | 398.0 | 4801.9 | 6079.6 |
| 16 | L3 | 327.0 | 4776.7 | 15584.5 |
| 32 | L0 (Stage C) | 429.2 | 7330.0 | 16881.9 |
| 32 | L1 | 568.8 | 7031.6 | 7760.3 |
| 32 | L3 | 556.2 | 7174.6 | 8597.5 |

## Interpretation

For L1 and L3 the percent changes point in BOTH directions and are large (L1 is +32.5%
throughput at c32 but -2.8% at c16; p95 swings from -54% to +169%). These are cross-session
comparisons against the Stage C run, and the positive numbers are NOT a speedup: packet
filtering and a bearer-token compare cannot make inference faster. The swing is run-to-run
variance on a 2-GPU pipeline where the T4 (PP stage 1) is the bottleneck and tail latency is
set by a few multi-second TTFT stalls. The honest headline is:

- L1 NetworkPolicy: no measurable penalty within cross-session variance, n=1. Not a speedup.
  Its real cost is a one-time engine restart when applied to a live cluster.
- L3 api-key auth: no measurable penalty within cross-session variance, n=1 (median e2e
  within 2.1% of baseline at c16 and c32).
- L2a Linkerd mTLS: not quantifiable; the tested configuration failed to carry the vLLM
  workload. Root cause not isolated; not a demonstrated incompatibility.
- L2b Cilium chaining + WireGuard: carried SSE streaming cleanly (512/512 ok) and is the only
  layer with a same-session bracket. It is slower than both L0 runs at every level. The
  c1/c4 tax (about 3.5%) is within the largest L0-to-L0 drift (about 3.4% throughput, 4.5%
  e2e p50); the c16/c32 throughput tax (4.5% / 6.5%) is outside it. Overall cost about 3 to
  8%, rising with concurrency. This is Cilium chaining + WireGuard combined; the Cilium-only
  share was not isolated. n=1.

The security value is real but narrow: L1 blocks steady-state cross-namespace ingress to the
Ray control-plane ports from the tested neighbour (no egress containment), L3 rejects ordinary
unauthenticated requests on two `/v1` routes (not authentication closure; v0.11.0 is in the
CVE-2026-48746 bypass range), and L2b routes the Ray/NCCL inter-node pod traffic
through WireGuard (shown by interface counters, not a ciphertext pcap) for a
single-digit-percent cost. The chaining trial also surfaced a real operational hazard: a
plain `helm uninstall cilium` with the documented default `cni.uninstall=false` left a stale
CNI conflist on every node and broke new pod sandboxes for about 28 minutes (see the L2b operational finding above).

## Reproduction assets

- Bench runner: `scripts/stageC-bench-run.sh` (targets the Ray head OpenAI service, samples
  both GPUs, `MESH_BENCH=1` injects the Linkerd client proxy, `BENCH_AUTH=1` sends the key).
- L1 policy: `manifests/stageD-L1-networkpolicy.yaml`.
- L3 api-key: `VLLM_API_KEY` secretKeyRef in `manifests/stageC-ray-pp.yaml`, secret
  `sorami-lab-vllm-apikey`.
- L2b: `manifests/stageD-L2b-cilium-values.yaml` (Cilium chaining + WireGuard) and
  `manifests/stageD-L2b-ray-pp.yaml` (same engine, re-pinned, no api-key env).
- Logs: `logs/2026-09-28-stageD-00-L0` (copy of Stage C, see correction), `-01-L1`, `-02-L2`,
  `-03-L3`, `-04-L2-wireguard`.
