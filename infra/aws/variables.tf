# infra/aws/variables.tf
#
# Every knob that changes deploy behaviour lives here. Defaults
# match the canonical bench setup documented in TASK §8 and
# infra/README.md so a `tofu apply` with no -var flags produces
# the same topology as the reference run.

# -----------------------------------------------------------------------------
# Region + availability zone
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region. The cluster placement group lives in a single AZ inside this region; see availability_zone for the AZ pin."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Single AZ inside aws_region. Cluster placement groups REQUIRE all members in one AZ — that is the placement constraint that delivers ~10 µs intra-cluster latency. Pick an AZ with c6i.2xlarge capacity (us-east-1a/b/c/d/f all carry it as of 2026-04)."
  type        = string
  default     = "us-east-1a"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "VPC CIDR. /16 is overkill for 3 hosts but matches the AWS console default; reviewers can run multiple stacks side by side without colliding by overriding to a /24 each."
  type        = string
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR. Must be inside vpc_cidr. We use one subnet because cluster placement groups are AZ-scoped, so multi-subnet wouldn't buy us any redundancy here."
  type        = string
  default     = "10.50.1.0/24"
}

variable "loadgen_private_ip" {
  description = "Static private IP for the loadgen host. Pinning these makes the SSH helper outputs deterministic across `tofu apply` cycles."
  type        = string
  default     = "10.50.1.10"
}

variable "gateway_private_ip" {
  description = "Static private IP for the gateway host."
  type        = string
  default     = "10.50.1.20"
}

variable "backend_private_ip" {
  description = "Static private IP for the backend host."
  type        = string
  default     = "10.50.1.30"
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type for all 3 hosts. c6i.2xlarge = 8 vCPU, 16 GiB, up to 12.5 Gbps network — enough headroom that loadgen never becomes the bottleneck. Override to c6i.4xlarge for the 20k RPS HTTPS sweep if you see the gateway saturating CPU first."
  type        = string
  default     = "c6i.2xlarge"
}

variable "runner_count" {
  description = "Additional physically separate load-runner EC2 instances for sharded turbo sweeps. 0 preserves the canonical 3-host topology."
  type        = number
  default     = 0

  validation {
    condition     = var.runner_count >= 0 && var.runner_count <= 64
    error_message = "runner_count must be between 0 and 64."
  }
}

variable "cluster_count" {
  description = "Additional clean AWS benchmark clusters. Each cluster is 3 EC2 hosts: loadgen -> gateway -> backend."
  type        = number
  default     = 0

  validation {
    condition     = var.cluster_count >= 0 && var.cluster_count <= 64
    error_message = "cluster_count must be between 0 and 64."
  }
}

variable "ebs_size_gb" {
  description = "Root EBS volume size in GiB. 300 holds the OS, Docker layer cache, all gateway images, and ~50 GiB of raw k6 stream JSON before rotation."
  type        = number
  default     = 300
}

variable "ebs_iops" {
  description = "Provisioned IOPS for gp3. 3000 is the gp3 baseline (free); raise for the p4-stress sweeps that can sustain ~6k IOPS during k6 stream-export flushes."
  type        = number
  default     = 3000
}

variable "ebs_throughput_mbps" {
  description = "Provisioned throughput for gp3 (MB/s). 125 is the baseline; matches the k6 stream-JSON write bandwidth at 20k RPS."
  type        = number
  default     = 125
}

# -----------------------------------------------------------------------------
# AMI selection
# -----------------------------------------------------------------------------
variable "ubuntu_release" {
  description = "Ubuntu LTS release codename for AMI lookup. Pinned to noble (24.04) because TASK §8 requires Ubuntu 24.04 LTS as the canonical base image."
  type        = string
  default     = "noble"
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
variable "ssh_key_name" {
  description = "Name of an existing AWS EC2 key pair (in aws_region) whose private half lives at ssh_private_key_path on the operator's laptop. Required — the bootstrap path provisions Docker over SSH."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Absolute path to the private key half of ssh_key_name. Used by the Makefile SSH helpers; never read by Terraform itself."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH the 3 hosts. DEFAULT IS DELIBERATELY EMPTY — set it to your operator IP (e.g. [\"203.0.113.42/32\"]) before `tofu apply`. Setting [\"0.0.0.0/0\"] would expose the hosts to the entire internet; the rules deny by default unless you opt in."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "allowed_ssh_cidrs must contain at least one CIDR. Use [\"$(curl -s ifconfig.me)/32\"] for your current IP, or [\"0.0.0.0/0\"] only if you understand the exposure."
  }
}

# -----------------------------------------------------------------------------
# Tagging / ownership
# -----------------------------------------------------------------------------
# Some AWS Organizations enforce mandatory tags via SCP (e.g. Wallarm's
# qa account denies `ec2:CreateVpc` / `ec2:RunInstances` if Product /
# Environment are missing). The defaults below match an unrestricted
# account; override them in terraform.tfvars when targeting an Org
# with tag-policy enforcement.
variable "product_tag" {
  description = "Product tag — required by some AWS Organizations' tag-enforcement SCPs. Wallarm's qa account requires `Product=qa`. Free-form for unrestricted accounts."
  type        = string
  default     = "gateway-benchmarks"
}

variable "project_tag" {
  description = "Project tag — recommended for cost-explorer attribution."
  type        = string
  default     = "gateway-benchmarks"
}

variable "environment_tag" {
  description = "Environment tag — required by some AWS Organizations' tag-enforcement SCPs. Common values: `staging`, `dev`, `prod`."
  type        = string
  default     = "staging"
}

variable "owner_tag" {
  description = "Owner tag applied to every resource. Useful for AWS cost-explorer attribution when multiple operators share an account."
  type        = string
  default     = "gateway-benchmarks"
}

variable "name_prefix" {
  description = "Prefix for every resource Name tag. Override when running multiple benches in parallel in the same AWS account."
  type        = string
  default     = "gwb"
}
