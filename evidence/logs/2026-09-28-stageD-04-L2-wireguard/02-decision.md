# L2b decision: how to get WireGuard on sorami-lab (UTC 2026-09-28T12:03Z)

## Evidence gathered

| Check | Result | Log |
|---|---|---|
| CNI in use | AWS VPC CNI `v1.22.4-eksbuild.3` + network-policy agent `v1.4.0` | `00-preflight.log` |
| VPC CNI addon schema: any `wireguard`, `ipsec`, `encrypt*` key | none (empty grep over 5860-byte schema) | `01-vpccni-encryption-options.log` |
| aws-node env: any encryption env var | none | `01-vpccni-encryption-options.log` |
| Node SG allows UDP 51871 node to node | yes: cluster SG self-reference, protocol -1 (all) | `05-node-sg.log` |
| Node kernel | 6.12.103 AL2023 (WireGuard in-tree since 5.6) | `00-preflight.log` |
| Cilium chart | 1.20.2 (kubeVersion >= 1.21) | helm search |

## Options

- Option B (VPC CNI native encryption): not available. The addon has no encryption setting.
  EKS relies on Nitro instance-level encryption for in-VPC traffic between supported
  instance types, which is transparent, not configurable, and not observable from the
  node, so it cannot be toggled for an A/B measurement.
- Option A replace mode: rejected. Replacing VPC CNI on a live cluster reassigns every pod
  IP and breaks the existing NetworkPolicy agent path. Too invasive.
- Option A chaining mode (`cni.chainingMode=aws-cni`, `routingMode=native`,
  `enableIPv4Masquerade=false`, `encryption.type=wireguard`): CHOSEN, scoped. VPC CNI
  keeps IPAM and pod IPs; Cilium only attaches eBPF to the veths of pods created after
  install. Existing pods are untouched until restarted, so the blast radius is limited to
  the pods we deliberately recreate (the two Ray engine pods and the bench Job).
- Option C (separate cluster): not needed because chaining is scoped and reversible
  (`helm uninstall cilium` then restart the engine pods restores plain VPC CNI).

## Scoping controls

- Cilium agent DaemonSet runs on all nodes (needed for WireGuard peers), but no existing
  pod is restarted except `sorami-lab-stack-vllm` Ray pods and the bench Job.
- `policyEnforcementMode=never`: Cilium enforces no policy, so the L1 NetworkPolicies stay
  enforced by the VPC CNI agent only and there is no double enforcement.
- `kubeProxyReplacement=false`, Hubble off, `cni.enableRouteMTUForCNIChaining=true` (per
  Cilium docs so WireGuard overhead does not fragment pod traffic).
- `encryption.nodeEncryption=false`: pod-to-pod only, which covers Ray GCS, raylet, and
  NCCL traffic between the head and worker pods (the Stage C plaintext channel).

## Topology deviation to note

On-demand capacity returned 2 x g5.xlarge (A10G) instead of Stage C's g5 + g4dn pair. So
Stage C absolute numbers are not comparable; a fresh same-session L0 is run on these exact
nodes first, then L2b, then an L0 bracket after removing encryption.

## Order

1. Deploy Ray PP=2 engine pinned to the 2 new nodes, plain VPC CNI. Fresh L0 sweep.
2. Install Cilium chaining + WireGuard, recreate engine pods, prove encryption, L2b sweep.
3. Uninstall Cilium, recreate engine pods, L0-after sweep (drift bracket).
4. Scale both GPU groups to 0.
