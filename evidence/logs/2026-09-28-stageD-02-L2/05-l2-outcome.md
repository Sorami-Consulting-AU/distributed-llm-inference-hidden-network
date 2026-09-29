# L2 Linkerd mTLS evidence  (UTC 2026-09-28T09:54:14Z)
## control plane
linkerd-destination-7c55987cbc-kz8hx     4/4   Running   0     18m
linkerd-identity-78cb546675-pgh55        2/2   Running   0     18m
linkerd-proxy-injector-854f7bb5f-5cjbv   2/2   Running   0     18m
## engine meshed while active (identity certified, ray stable, gen worked)
- head proxy issued identity: default.sorami-lab-stack-vllm.serviceaccount.identity.linkerd.cluster.local
- ray status showed both nodes Active under mesh; /v1/completions worked from inside head pod
## blocker: vLLM 8000 stream reset through proxy
- meshed client -> svc 8000 returned HTTP 503 (L7 route unavailable) then Connection reset (opaque L4)
- head inbound proxy logged zero 8000 traffic in opaque mode: connection reset before inbound
- conclusion: Linkerd data path is incompatible with this KubeRay+vLLM SSE serving port on this build
