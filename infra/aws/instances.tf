# infra/aws/instances.tf
#
# 3 EC2 c6i.2xlarge in a single cluster placement group, single AZ,
# single subnet. Each one has a tightly-scoped role — see the
# user_data scripts under infra/aws/userdata/ (referenced from the
# corresponding launch template in launch_templates.tf).
#
# Almost everything about the instance lives in launch_templates.tf
# (AMI, type, user_data, networking, EBS, tag_specifications). This
# file just attaches the instance to the cluster placement group +
# carries the public-facing instance tags. See launch_templates.tf
# header for why this split exists.

# -----------------------------------------------------------------------------
# Loadgen — runs k6 against the gateway
# -----------------------------------------------------------------------------
resource "aws_instance" "loadgen" {
  launch_template {
    id      = aws_launch_template.loadgen.id
    version = "$Latest"
  }

  placement_group = aws_placement_group.bench.name

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
  launch_template {
    id      = aws_launch_template.gateway.id
    version = "$Latest"
  }

  placement_group             = aws_placement_group.bench.name
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
  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  placement_group             = aws_placement_group.bench.name
  user_data_replace_on_change = true

  tags = {
    Name = "${var.name_prefix}-backend"
    Role = "backend"
  }
}
