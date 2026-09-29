# The Hidden Network: Ray control-plane exposure in distributed LLM inference on Kubernetes (evidence)

This repository holds the data and evidence behind the Sorami technical report **"The Hidden Network: Ray Control-Plane Exposure in Distributed LLM Inference on Kubernetes"**.

**Read the report here:** https://sorami.com.au/research/distributed-llm-inference-hidden-network/

The method, findings, limitations and hardening advice are in the report. This repository does not repeat them. It holds the data files the report cites, so readers can check each claim. The page on sorami.com.au is the canonical version.

## Software tested

Vendor defaults on a dedicated Amazon EKS 1.35 cluster in AWS (ap-southeast-2), created for this study and used for nothing else. Experiments ran on 28 September 2026 (UTC).

| Component | Version |
|---|---|
| Amazon EKS | 1.35 (`v1.35.8-eks`), Amazon VPC CNI with network policy agent enabled |
| KubeRay operator, `ray-cluster` chart | 1.7.1 |
| Ray | 2.52.0 |
| vLLM production-stack chart | 0.1.12 |
| vLLM engine image | `vllm/vllm-openai:v0.11.0` |
| Cilium chaining plus WireGuard combined (L2b) | 1.20.2, chained on the VPC CNI, WireGuard on. WireGuard alone was not isolated |
| Scanners | Trivy 0.67.0, Checkov (version not logged), Kubescape v3.0.40, kube-linter 0.8.3 |

## Files

- `results.csv`: one row per run (layer and concurrency level), with the throughput and latency values copied from the raw `result-c*.json` files and the path of each source file.
- `tools.tsv`: software under test, with pinned versions.
- `evidence/logs/`: raw command output for every stage. Each `.log` file starts with the UTC time and the exact command.
- `evidence/logs/*/result-c*.json`: benchmark summaries per concurrency level (1, 4, 16, 32; 128 requests each).
- `evidence/findings/`: per-stage summaries (A: defaults and scanners, B: single-GPU baseline, C: distributed topology, D: hardening layers).
- `evidence/summary.html`: evidence-graded summary with SVG charts. Self-contained, loads no external resources.
- `figures/`: the figures used in the report.
- `test-harness/infra/`: Terraform for the dedicated VPC and EKS cluster.
- `test-harness/manifests/`: every manifest applied, including the rendered chart defaults, NetworkPolicies and Cilium values.
- `test-harness/bench/bench.py`: the stdlib-only streaming benchmark client.
- `test-harness/scripts/`: the probe and benchmark runners.
- `tools/build_results.py`: rebuilds `results.csv` from the raw `result-c*.json` files.

## How to read the data

- Resource names use the prefix `sorami-lab` (cluster, namespaces, node groups, labels, Service DNS).
- The AWS account ID is replaced with `111122223333`. Public node IP addresses are replaced with `<public-ip-redacted>`. EKS node group and Auto Scaling group ID suffixes are replaced with `<id-redacted>`. The Terraform plan shows the API allowlist as `<operator-ip-redacted>/32`.
- Pod, Service and node IP addresses inside the study VPC (`10.99.0.0/16`) are left as captured.
- Nothing else in any log, measurement or timestamp was changed. The benchmark JSON files are byte-identical to the originals except for the Service hostname in the `base` field.
- `ca.crt` and `issuer.crt` under `evidence/logs/2026-09-28-stageD-02-L2/` are the public Linkerd trust anchors from the study cluster. They are valid only until 30 September 2026, and no private keys are included.

## Reproduce

```bash
python3 tools/build_results.py         # rebuild results.csv from the raw logs
cd test-harness/infra
cp terraform.tfvars.example terraform.tfvars   # set operator_cidr to your own /32
terraform init && terraform apply
```

Appendix A of the report lists every stage in order, with the method fixes this study did not have (same-session baselines, repeated blocks, persisted per-request samples). Run the neighbour probe only in a cluster you own and that runs nothing else. GPU node groups default to 0 and must be scaled up per run. `terraform destroy` removes everything.

## Disclosure

The behaviours reported (Ray's trusted-network assumption, vLLM's optional authentication, charts shipping no NetworkPolicy) are documented vendor defaults, not new vulnerabilities. The vLLM API-key bypass relevant to the tested version (CVE-2026-48746) was already public and fixed upstream. Only our own pods were probed. Every probe target came from an allowlist of our own pod IPs, and no CIDR ranges were scanned. Vendors with a question about a finding can write to hello@sorami.com.au.

## Licence

The data, evidence files, logs and figures in this repository are released under CC BY 4.0. The harness code and the build scripts in `tools/` may be reused under the same licence. Copyright 2026 Sorami Consulting Pty Ltd. See `LICENSE`.

Rendered chart defaults under `test-harness/manifests/rendered-defaults/` are output of the upstream Apache-2.0 charts and remain under their original licence.

Cite as: Sorami (2026). *The Hidden Network: Ray Control-Plane Exposure in Distributed LLM Inference on Kubernetes.* Sorami Technical Report. https://sorami.com.au/research/distributed-llm-inference-hidden-network/

Contact: hello@sorami.com.au
