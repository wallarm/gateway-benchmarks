# infra/aws/instances.tf
#
# 3 EC2 c6i.2xlarge in a single cluster placement group, single AZ,
# single subnet. Each one has a tightly-scoped role — see the
# user_data scripts under infra/aws/userdata/.
#
# Static private IPs (loadgen=10, gateway=20, backend=30) make the
# SSH helper outputs deterministic and let userdata reference peers
# by IP without needing a service-discovery layer.

# -----------------------------------------------------------------------------
# Loadgen — runs k6 against the gateway
# -----------------------------------------------------------------------------
resource "aws_instance" "loadgen" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.loadgen.id]
  placement_group             = aws_placement_group.bench.name
  associate_public_ip_address = true
  private_ip                  = var.loadgen_private_ip
  key_name                    = var.ssh_key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.ebs_size_gb
    iops        = var.ebs_iops
    throughput  = var.ebs_throughput_mbps
    encrypted   = true
    tags = {
      Name = "${var.name_prefix}-loadgen-root"
    }
  }

  # Bootstraps Docker + pulls the pinned k6 image so the first
  # `k6 run` invocation doesn't have to. Userdata runs once on the
  # initial boot; idempotent across reboots via cloud-init's
  # builtin cache (so manual `cloud-init clean && reboot` is the
  # way to re-run it).
  user_data = file("${path.module}/userdata/loadgen.sh")

  # Userdata changes invalidate the instance — we want a fresh boot
  # so the new bootstrap actually runs. Without this, modifying
  # userdata.sh and `tofu apply`-ing would silently no-op.
  user_data_replace_on_change = true

  tags = {
    Name = "${var.name_prefix}-loadgen"
    Role = "loadgen"
  }
}

# -----------------------------------------------------------------------------
# Gateway — the system under test
# -----------------------------------------------------------------------------
resource "aws_instance" "gateway" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.gateway.id]
  placement_group             = aws_placement_group.bench.name
  associate_public_ip_address = true
  private_ip                  = var.gateway_private_ip
  key_name                    = var.ssh_key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.ebs_size_gb
    iops        = var.ebs_iops
    throughput  = var.ebs_throughput_mbps
    encrypted   = true
    tags = {
      Name = "${var.name_prefix}-gateway-root"
    }
  }

  user_data                   = file("${path.module}/userdata/gateway.sh")
  user_data_replace_on_change = true

  tags = {
    Name = "${var.name_prefix}-gateway"
    Role = "gateway"
  }
}

# -----------------------------------------------------------------------------
# Backend — the upstream go-httpbin
# -----------------------------------------------------------------------------
resource "aws_instance" "backend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.backend.id]
  placement_group             = aws_placement_group.bench.name
  associate_public_ip_address = true
  private_ip                  = var.backend_private_ip
  key_name                    = var.ssh_key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.ebs_size_gb
    iops        = var.ebs_iops
    throughput  = var.ebs_throughput_mbps
    encrypted   = true
    tags = {
      Name = "${var.name_prefix}-backend-root"
    }
  }

  user_data                   = file("${path.module}/userdata/backend.sh")
  user_data_replace_on_change = true

  tags = {
    Name = "${var.name_prefix}-backend"
    Role = "backend"
  }
}
