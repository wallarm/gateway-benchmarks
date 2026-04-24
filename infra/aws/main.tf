# infra/aws/main.tf
#
# Phase 5 — AWS infrastructure: a 3-host benchmark cluster in a
# single VPC, single AZ, single cluster placement group.
#
# Topology:
#
#   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
#   │   loadgen    │──9080─►│   gateway    │──8080─►│   backend    │
#   │  10.50.1.10  │  9443  │  10.50.1.20  │        │  10.50.1.30  │
#   │  c6i.2xlarge │        │  c6i.2xlarge │        │  c6i.2xlarge │
#   └──────────────┘        └──────────────┘        └──────────────┘
#         │                       │                       │
#         └───────── all in one cluster placement group ──┘
#                  (same AZ, ~10 µs intra-cluster RTT)
#
# This file owns the *foundation* — VPC, subnet, IGW, route table,
# placement group, AMI lookup. Compute lives in instances.tf,
# firewalls in security.tf, exposed values in outputs.tf.
#
# State is local (versions.tf). Apply with:
#
#   cd infra/aws/
#   tofu init
#   tofu apply -var='ssh_key_name=…' -var='allowed_ssh_cidrs=["A.B.C.D/32"]'

# -----------------------------------------------------------------------------
# AMI lookup — Canonical's official Ubuntu 24.04 LTS (HVM, gp3, amd64)
# -----------------------------------------------------------------------------
# Pinning to a fixed AMI ID would lock the bench to a 6-month-old
# kernel that gradually drifts off Ubuntu's security patch path.
# Looking up the latest "noble-amd64-server" instead keeps us on the
# current-stable kernel without baking in a moving target — the
# AMI ID is recorded in the Terraform state at apply time, so a
# repro is always possible by running with -var ami_id=ami-….
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-${var.ubuntu_release}-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# VPC + IGW + subnet + route table
# -----------------------------------------------------------------------------
# Single public subnet — the cluster placement group is AZ-scoped, so
# a multi-subnet design buys nothing here. Public IPs let the operator
# SSH from their laptop without setting up a bastion (acceptable for
# a benchmark that runs for ~6 hours total and then `tofu destroy`s).
resource "aws_vpc" "bench" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-subnet-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Cluster placement group — the secret sauce of canonical bench numbers
# -----------------------------------------------------------------------------
# Strategy = "cluster" packs all 3 instances onto the same physical
# rack within the AZ. Latency between members drops from ~250 µs
# (default placement) to ~10–30 µs (cluster), which is what TASK §8
# demands so the gateway's processing overhead is the dominant
# component of the measured p95 — not network jitter between
# loadgen and gateway.
resource "aws_placement_group" "bench" {
  name     = "${var.name_prefix}-cluster"
  strategy = "cluster"

  tags = {
    Name = "${var.name_prefix}-cluster-pg"
  }
}
