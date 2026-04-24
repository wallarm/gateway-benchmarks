# infra/aws/launch_templates.tf
#
# Launch templates exist so the RunInstances API call carries explicit
# TagSpecifications for the instance, volume, AND network-interface
# sub-resources. Without this, the AWS Provider's `default_tags`
# propagate to the instance and (since v5.39) to the root volume,
# but NOT to the network interface auto-created during RunInstances —
# see hashicorp/terraform-provider-aws#45887. Some AWS Organization
# SCPs (notably Wallarm's qa account) deny RunInstances when
# `aws:RequestTag/Product` or `aws:RequestTag/Owner` are missing on
# any of the three sub-resources.
#
# To make the network-interface tag_specifications take effect, the
# launch template MUST also create the ENI itself (via the
# network_interfaces block). When `aws_instance` attaches a
# pre-created ENI via its own network_interface block, the launch
# template's network-interface tag_specifications are silently
# ignored (because no new ENI is being created).
#
# Therefore: this file owns AMI selection, instance type, key pair,
# user_data, network configuration, root volume, and tag specs. The
# aws_instance resources just reference the launch template + pin
# placement_group + carry the public-facing tags.

# -----------------------------------------------------------------------------
# Loadgen
# -----------------------------------------------------------------------------
resource "aws_launch_template" "loadgen" {
  name_prefix   = "${var.name_prefix}-loadgen-"
  description   = "Loadgen template — see launch_templates.tf header."
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  user_data = base64encode(file("${path.module}/userdata/loadgen.sh"))

  network_interfaces {
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.loadgen.id]
    private_ip_address          = var.loadgen_private_ip
    associate_public_ip_address = true
    delete_on_termination       = true
    device_index                = 0
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.ebs_size_gb
      iops                  = var.ebs_iops
      throughput            = var.ebs_throughput_mbps
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-loadgen"
      Role = "loadgen"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-loadgen-root"
      Role = "loadgen"
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-loadgen-eni"
      Role = "loadgen"
    })
  }

  tags = {
    Name = "${var.name_prefix}-loadgen-lt"
    Role = "loadgen"
  }
}

# -----------------------------------------------------------------------------
# Gateway
# -----------------------------------------------------------------------------
resource "aws_launch_template" "gateway" {
  name_prefix   = "${var.name_prefix}-gateway-"
  description   = "Gateway template — see launch_templates.tf header."
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  user_data = base64encode(file("${path.module}/userdata/gateway.sh"))

  network_interfaces {
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.gateway.id]
    private_ip_address          = var.gateway_private_ip
    associate_public_ip_address = true
    delete_on_termination       = true
    device_index                = 0
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.ebs_size_gb
      iops                  = var.ebs_iops
      throughput            = var.ebs_throughput_mbps
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-gateway"
      Role = "gateway"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-gateway-root"
      Role = "gateway"
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-gateway-eni"
      Role = "gateway"
    })
  }

  tags = {
    Name = "${var.name_prefix}-gateway-lt"
    Role = "gateway"
  }
}

# -----------------------------------------------------------------------------
# Backend
# -----------------------------------------------------------------------------
resource "aws_launch_template" "backend" {
  name_prefix   = "${var.name_prefix}-backend-"
  description   = "Backend template — see launch_templates.tf header."
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  user_data = base64encode(file("${path.module}/userdata/backend.sh"))

  network_interfaces {
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.backend.id]
    private_ip_address          = var.backend_private_ip
    associate_public_ip_address = true
    delete_on_termination       = true
    device_index                = 0
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.ebs_size_gb
      iops                  = var.ebs_iops
      throughput            = var.ebs_throughput_mbps
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-backend"
      Role = "backend"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-backend-root"
      Role = "backend"
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(local.required_tags, {
      Name = "${var.name_prefix}-backend-eni"
      Role = "backend"
    })
  }

  tags = {
    Name = "${var.name_prefix}-backend-lt"
    Role = "backend"
  }
}
