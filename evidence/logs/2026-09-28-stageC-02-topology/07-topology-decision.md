# Stage C topology decision (UTC 2026-09-28T07:47Z)

Preferred topology C1 (disaggregated prefill/decode, vLLM P2pNcclConnector) was
attempted first and proved unstable on vLLM v0.11.0 in this container:
`P2pNcclEngine` -> `tensor_memory_pool._allocate_pinned_memory` ->
`torch.empty(max_block_size//4, ...)` raised `CUDA error: out of memory` on BOTH
the A10G 24GB producer and the T4 16GB consumer, at kv_buffer_size 2e9, 1e9, 5e8
and 1e8, with gpu_memory_utilization 0.85 down to 0.4 and enforce_eager. The
allocation that fails is the connector's pinned staging pool, not the model, so
shrinking the model or the KV buffer did not help. PyNcclConnector (the older
name in the study plan) does not exist in v0.11.0; only P2pNcclConnector does.

Decision: fall back to the study plan's documented acceptable alternative, Ray-backed
vLLM with pipeline parallel across the two GPU nodes (PP=2, 1 GPU per node). This
still exercises the multi-node data plane the study cares about: Ray GCS/object
store plus NCCL activations between the two nodes over plaintext TCP.
Evidence: 06-p2p-oom-evidence.log.
