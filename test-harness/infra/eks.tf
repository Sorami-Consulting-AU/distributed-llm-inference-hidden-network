resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = "1.35"
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = [var.operator_cidr]
  }

  # Control plane logs go to CloudWatch so every API call made during the
  # experiment (including by probe pods) is part of the evidence bundle.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# CNI network-policy agent is on from day one but inert until a
# NetworkPolicy object exists, so the "vendor defaults" baseline is still
# allow-all and Stage D can harden without a disruptive addon change.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
}

resource "aws_eks_addon" "core" {
  for_each                    = toset(["coredns", "kube-proxy"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.cpu]
}

# Spot CPU pool runs stack control planes, routers and the neighbor probe.
# Multiple families so a spot reclaim in one does not stall the run.
resource "aws_eks_node_group" "cpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-cpu-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  capacity_type   = "SPOT"
  instance_types  = ["m6i.xlarge", "m5.xlarge", "m6a.xlarge", "m7i.xlarge"]
  ami_type        = "AL2023_x86_64_STANDARD"
  disk_size       = 50

  scaling_config {
    min_size     = 0
    desired_size = 2
    max_size     = 3
  }

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]
}

# g6 (L4 24GB) is the preferred and cheapest 24GB spot GPU, but on 2026-09-28
# Sydney spot placement score was 1/10 for every g4dn/g5/g6 size and g6 alone
# hit UnfulfillableCapacity for 8+ minutes. A wide mix lets the ASG take
# whatever pool has capacity. g4dn (T4 16GB) is last resort and needs a
# quantized or smaller model. max 4 nodes keeps vCPU inside the spot quota.
resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-gpu-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  capacity_type   = "SPOT"
  instance_types  = ["g6.xlarge", "g6.2xlarge", "g5.xlarge", "g5.2xlarge", "g6.4xlarge", "g4dn.xlarge", "g4dn.2xlarge"]
  ami_type        = "AL2023_x86_64_NVIDIA"
  # Serving images (Triton/Dynamo) are 10-20 GB plus ~15 GB of weights.
  disk_size = 150

  scaling_config {
    min_size     = 0
    desired_size = var.gpu_desired
    max_size     = 4
  }

  taint {
    key    = "sorami-lab/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = { "sorami-lab/pool" = "gpu" }

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]
}

# On-demand fallback because Sydney spot GPU placement score was 1/10 and the
# spot group hit UnfulfillableCapacity, which stalls a benchmark run. A
# separate group (not a capacity_type flip) keeps the spot group intact and
# lets either node satisfy the same pool label and taint. max 1 caps spend at
# one GPU (g6.xlarge 1.0464 USD/hr in ap-southeast-2, 2026-09-28). EKS uses a
# prioritized strategy for on-demand, so list order is preference: g6 (L4
# 24GB) first, g5 (A10G 24GB) next; g4dn (T4 16GB) is last because the 7B fp16
# model does not fit at 8k context and would need a smaller or quantized model.
resource "aws_eks_node_group" "gpu_ondemand" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-gpu-ondemand"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  capacity_type   = "ON_DEMAND"
  instance_types  = ["g6.xlarge", "g5.xlarge", "g4dn.xlarge"]
  ami_type        = "AL2023_x86_64_NVIDIA"
  disk_size       = 150

  scaling_config {
    min_size     = 0
    desired_size = var.gpu_ondemand_desired
    # Raised to 2 because on 2026-09-28 Sydney spot GPU placement scored 2/10 and
    # the spot group returned UnfulfillableCapacity on every attempt, so the only
    # way to reach the two-node distributed topology is two on-demand GPUs.
    # Hard-capped at 2, never higher, so worst-case spend is two g6.xlarge
    # (2 x 1.0464 USD/hr) and the study cannot silently exceed its node ceiling.
    max_size = 2
  }

  taint {
    key    = "sorami-lab/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "sorami-lab/pool"     = "gpu"
    "sorami-lab/capacity" = "ondemand"
  }

  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.vpc_cni]
}

output "cluster_name" { value = aws_eks_cluster.this.name }
output "vpc_id" { value = aws_vpc.this.id }
