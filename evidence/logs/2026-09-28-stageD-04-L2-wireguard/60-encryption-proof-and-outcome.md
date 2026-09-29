# L2b Cilium WireGuard: encryption proof and outcome (UTC 2026-09-28)

## Session timeline

| UTC | Event | Log |
|---|---|---|
| 11:54 | Preflight: VPC CNI v1.22.4 has no encryption knob | `00-preflight.log`, `01-vpccni-encryption-options.log` |
| 12:01 | Terraform `gpu_desired=0 gpu_ondemand_desired=2` (1 in-place change, ondemand desired 0 -> 2) | `03-tf-plan-gpu2.log`, `04-tf-apply-gpu2.log` |
| 12:02 | 2 x g5.xlarge Ready (ap-southeast-2b, 2c) | poll output |
| 12:04 | L1 NetworkPolicies removed so L0 and L2b are both unhardened; engine re-pinned to new nodes, api-key env removed | `06-*`, `07-*`, `08-*` |
| 12:13 to 12:21 | Fresh L0 sweep | `bench-L0-before/` |
| 12:21 | Cilium 1.20.2 installed, chained on aws-cni, WireGuard on | `10-cilium-install.log` |
| 12:25 | Engine pods recreated as Cilium endpoints; encryption proven | `11-*`, `12-*`, `13-*` |
| 12:27 to 12:35 | L2b WireGuard sweep | `bench-L2b/`, `14-*`, `15-*` |
| 12:37 | helm upgrade `encryption.enabled=false` did NOT disable WG (agents not restarted) | `17-cilium-disable-wg.log` |
| 12:41 | helm uninstall left a stale cilium conflist; new engine pods failed sandbox creation | `19-*`, `22-stale-cni-conflist-breakage.log` |
| 13:09 | Cilium reinstalled with `encryption.enabled=false cni.uninstall=true`; L0-after head pod not a Cilium endpoint (worker not checked); agent stays running through L0-after | `23-*`, `24-bracket-state.log` |
| 13:13 to 13:21 | L0-after drift bracket sweep | `bench-L0-after/` |
| 13:22 | Cilium uninstalled cleanly (cni-uninstall=true); busybox sanity pod networked OK; L1 policies restored | `30-*`, `31-*`, `32-*` |
| 13:28 | Both GPU groups at desired 0, zero GPU instances | `40-tf-plan-gpu0.log`, `41-gpu-zero-verify.log` |

## Parallel control session (recorded for provenance)

Two actions in this dir were taken by the same study team in a parallel control
session, not in the session that ran the benchmarks:
- `22-remove-stale-cilium-conflist.log` (13:09Z): a node-debugger pod renamed the stale
  `05-cilium.conflist` to `.disabled-after-uninstall` on every node. This is consistent with
  the L0-after head pod being on the plain VPC CNI path (`24-bracket-state.log`: head pod IP
  not in the Cilium endpoint list, no `cilium_wg0`). The worker pod was NOT checked, and the
  Cilium agent (encryption disabled) stayed installed and running for the whole L0-after
  window, until the final uninstall at 13:22:22Z (`30-cilium-uninstall-final.log`). So the
  bracket is a no-encryption L0, but not a proven Cilium-free baseline. The final uninstall
  had `cni-uninstall=true`, and a busybox pod on a CPU node networked fine afterwards
  (`31-cni-sanity-pod.log`).
  Correction 2026-09-29: an earlier version of this note misattributed these two actions and
  called the bracket "still a valid no-encryption L0" on "the plain VPC CNI path"; the logs
  do not support either statement.
- `23-tf-plan-gpu0.log`, `24-tf-apply-gpu0.log`, `25-gpu-zero-verify.log` (13:22Z):
  on-demand desired 2 -> 0. The L0-after sweep finished at 13:22:00Z (`bench-L0-after/08-job-logs.log`),
  so no benchmark data overlaps the scale-down. The benchmark session's own plan (`40-*`) then showed
  No changes, and `41-gpu-zero-verify.log` confirmed zero GPU instances at 13:28:54Z.

## Encryption proof

1. Agent status on both GPU nodes (`12-cilium-encryption-status.log`):
   `Encryption: Wireguard [NodeEncryption: Disabled, cilium_wg0 (... Port: 51871, Peers: 3)]`,
   `CNI Chaining: aws-cni`. Each node's peer list names the other GPU node with the remote
   engine pod IP in `allowed-ips` (head 10.99.19.25 on 10.99.17.131, worker 10.99.33.127
   on 10.99.38.120) and a fresh `last-handshake`.
2. Byte-counter proof (`13-wg-counter-proof.log`): 55,189,000 bytes of ASCII marker sent
   head pod -> worker pod over TCP. On the head node, `cilium_wg0` TX grew from 651,048 to
   56,438,648 bytes (+55.79 MB, within 1.1% of payload plus TCP/IP headers). So the
   inter-node pod traffic was routed into the WireGuard device, not sent in cleartext on
   `ens5`. `ens5` TX grew by 56.06 MB, which is the encrypted UDP 51871 carriage of the same flow.
3. Under benchmark load (`14-*`, `15-*`): head `cilium_wg0` TX +572 MB and worker
   `cilium_wg0` RX +546 MB over the L2b sweep. That is the Ray/NCCL PP activation and
   control traffic, all of which Stage C showed as cleartext
   (`logs/2026-09-28-stageC-05-plaintext/`: raw HTTP/2 SETTINGS frames returned by GCS 6379
   and raylet 10002 to an unauthenticated neighbor connect).

Limit, stated honestly: no pcap of the ciphertext on `ens5`. The Cilium agent image has
no tcpdump, and no privileged node shell was already available. The proof rests on Cilium
status, WireGuard peer and handshake state, and the byte-for-byte counter match.
Scope note: WireGuard encrypts the node-to-node wire. It does NOT close Stage C's
cross-namespace reachability: a neighbor pod can still open 6379 in cleartext at the
socket level, because WireGuard decrypts before delivery. L1 NetworkPolicy closes that.

## Result

| Label | conc 16 out tok/s | conc 16 e2e p50 ms | conc 32 out tok/s | conc 32 e2e p50 ms |
|---|---|---|---|---|
| L0 fresh before | 680.1 | 2984.8 | 1179.8 | 3434.3 |
| L2b Cilium WireGuard node-to-node encryption | 638.2 | 3216.2 | 1116.9 | 3665.8 |
| L0 after (bracket) | 656.8 | 3119.8 | 1209.0 | 3326.8 |

Full table with all levels and drift: `50-wireguard-tax.md`.

## Operational lessons

- `helm upgrade` flipping `encryption.enabled` rewrites the ConfigMap but does not
  restart agents, so WireGuard stays active. Restart the DaemonSet or reinstall.
- In chaining mode the documented chart default `cni.uninstall=false` leaves `05-cilium.conflist` on the
  node after `helm uninstall`. Every new pod on that node then fails sandbox creation
  (`cilium-cni ... cilium.sock: no such file`). Set `cni.uninstall=true` and restart the
  agents BEFORE uninstalling.
