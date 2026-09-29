variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "name" {
  type    = string
  default = "sorami-lab"
}

# /32 of the workstation that runs Terraform and kubectl. The API endpoint is public so no bastion is
# needed, but it must not be reachable from the internet at large.
variable "operator_cidr" {
  type = string
}

# GPU group starts at 0 and is scaled up per benchmark batch, so an idle
# research cluster never bills for GPUs.
variable "gpu_desired" {
  type    = number
  default = 0
}

# On-demand fallback stays at 0 unless spot GPU capacity is unavailable, so it
# never double-bills alongside a working spot node.
variable "gpu_ondemand_desired" {
  type    = number
  default = 0
}
