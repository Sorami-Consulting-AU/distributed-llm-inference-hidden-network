locals {
  tags = {
    Project   = "test-harness"
    Owner     = "sorami-lab"
    ManagedBy = "terraform"
    Purpose   = "research-ephemeral"
  }
  azs = ["${var.region}a", "${var.region}b", "${var.region}c"]
}

# 10.99/16 is chosen so it does not overlap other VPCs; pick a CIDR that is
# unused in your own account so accidental peering or TGW routing is impossible.
resource "aws_vpc" "this" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# Public subnets with auto-assigned IPv4 instead of private subnets + NAT:
# a NAT gateway needs an Elastic IP, which a busy account may not have spare. Node SGs block all inbound from
# outside the VPC so a public IP only enables egress (image/model pulls).
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
