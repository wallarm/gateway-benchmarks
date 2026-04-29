# infra/aws/security.tf
#
# Security groups — the AWS-side enforcement of the same network
# isolation guarantee that infra/local/docker-compose.yaml provides
# locally. Three logical perimeters:
#
#   loadgen to gateway     :9080 / :9443  (HTTP + TLS data plane)
#   gateway to backend     :8080          (upstream HTTP/1.1)
#   loadgen ⇸ backend     DENY           (must transit the gateway)
#
# Plus per-host SSH:22 from var.allowed_ssh_cidrs only.
# Plus egress 443/80 from each host for `apt update` + image pulls.
#
# Note: the rules use `source_security_group_id` rather than CIDR
# so adding/removing/repinning hosts within the SG doesn't require
# rule changes — the SG-id reference auto-includes new ENIs.

# -----------------------------------------------------------------------------
# Loadgen
# -----------------------------------------------------------------------------
resource "aws_security_group" "loadgen" {
  name        = "${var.name_prefix}-loadgen"
  description = "loadgen host: SSH from operator, egress to gateway only"
  vpc_id      = aws_vpc.bench.id

  tags = {
    Name = "${var.name_prefix}-sg-loadgen"
  }
}

resource "aws_security_group_rule" "loadgen_ssh_in" {
  type              = "ingress"
  security_group_id = aws_security_group.loadgen.id
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = var.allowed_ssh_cidrs
  description       = "operator SSH"
}

# loadgen needs OS package + container image pulls during cloud-init.
# After bootstrap is done the operator can flip this rule off if they
# want strict no-egress-from-loadgen during the bench window itself
# — k6 only talks to gateway over the SG-to-SG rule below.
resource "aws_security_group_rule" "loadgen_egress_internet" {
  type              = "egress"
  security_group_id = aws_security_group.loadgen.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "image + package pulls (HTTPS)"
}

resource "aws_security_group_rule" "loadgen_egress_internet_http" {
  type              = "egress"
  security_group_id = aws_security_group.loadgen.id
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "package pulls (HTTP)"
}

resource "aws_security_group_rule" "loadgen_egress_dns_udp" {
  type              = "egress"
  security_group_id = aws_security_group.loadgen.id
  protocol          = "udp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS"
}

resource "aws_security_group_rule" "loadgen_egress_dns_tcp" {
  type              = "egress"
  security_group_id = aws_security_group.loadgen.id
  protocol          = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS (TCP fallback)"
}

resource "aws_security_group_rule" "loadgen_to_gateway_http" {
  type                     = "egress"
  security_group_id        = aws_security_group.loadgen.id
  protocol                 = "tcp"
  from_port                = 9080
  to_port                  = 9080
  source_security_group_id = aws_security_group.gateway.id
  description              = "k6 to gateway HTTP/1.1"
}

resource "aws_security_group_rule" "loadgen_to_gateway_ssh" {
  type                     = "egress"
  security_group_id        = aws_security_group.loadgen.id
  protocol                 = "tcp"
  from_port                = 22
  to_port                  = 22
  source_security_group_id = aws_security_group.gateway.id
  description              = "loadgen controls its paired gateway during clean shard runs"
}

resource "aws_security_group_rule" "loadgen_to_gateway_https" {
  type                     = "egress"
  security_group_id        = aws_security_group.loadgen.id
  protocol                 = "tcp"
  from_port                = 9443
  to_port                  = 9443
  source_security_group_id = aws_security_group.gateway.id
  description              = "k6 to gateway TLS"
}

# -----------------------------------------------------------------------------
# Gateway
# -----------------------------------------------------------------------------
resource "aws_security_group" "gateway" {
  name        = "${var.name_prefix}-gateway"
  description = "gateway host: ingress from loadgen on :9080/:9443, egress to backend on :8080"
  vpc_id      = aws_vpc.bench.id

  tags = {
    Name = "${var.name_prefix}-sg-gateway"
  }
}

resource "aws_security_group_rule" "gateway_ssh_in" {
  type              = "ingress"
  security_group_id = aws_security_group.gateway.id
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = var.allowed_ssh_cidrs
  description       = "operator SSH"
}

resource "aws_security_group_rule" "gateway_ssh_from_loadgen" {
  type                     = "ingress"
  security_group_id        = aws_security_group.gateway.id
  protocol                 = "tcp"
  from_port                = 22
  to_port                  = 22
  source_security_group_id = aws_security_group.loadgen.id
  description              = "loadgen controls its paired gateway during clean shard runs"
}

resource "aws_security_group_rule" "gateway_from_loadgen_http" {
  type                     = "ingress"
  security_group_id        = aws_security_group.gateway.id
  protocol                 = "tcp"
  from_port                = 9080
  to_port                  = 9080
  source_security_group_id = aws_security_group.loadgen.id
  description              = "loadgen HTTP traffic"
}

resource "aws_security_group_rule" "gateway_from_loadgen_https" {
  type                     = "ingress"
  security_group_id        = aws_security_group.gateway.id
  protocol                 = "tcp"
  from_port                = 9443
  to_port                  = 9443
  source_security_group_id = aws_security_group.loadgen.id
  description              = "loadgen TLS traffic"
}

resource "aws_security_group_rule" "gateway_egress_internet" {
  type              = "egress"
  security_group_id = aws_security_group.gateway.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "image + package pulls (HTTPS)"
}

resource "aws_security_group_rule" "gateway_egress_internet_http" {
  type              = "egress"
  security_group_id = aws_security_group.gateway.id
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "package pulls (HTTP)"
}

resource "aws_security_group_rule" "gateway_egress_dns_udp" {
  type              = "egress"
  security_group_id = aws_security_group.gateway.id
  protocol          = "udp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS"
}

resource "aws_security_group_rule" "gateway_egress_dns_tcp" {
  type              = "egress"
  security_group_id = aws_security_group.gateway.id
  protocol          = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS (TCP fallback)"
}

resource "aws_security_group_rule" "gateway_to_backend" {
  type                     = "egress"
  security_group_id        = aws_security_group.gateway.id
  protocol                 = "tcp"
  from_port                = 8080
  to_port                  = 8080
  source_security_group_id = aws_security_group.backend.id
  description              = "gateway to backend HTTP/1.1"
}

# -----------------------------------------------------------------------------
# Backend
# -----------------------------------------------------------------------------
resource "aws_security_group" "backend" {
  name        = "${var.name_prefix}-backend"
  description = "backend host: ingress from gateway on :8080 only (loadgen is denied by default)"
  vpc_id      = aws_vpc.bench.id

  tags = {
    Name = "${var.name_prefix}-sg-backend"
  }
}

resource "aws_security_group_rule" "backend_ssh_in" {
  type              = "ingress"
  security_group_id = aws_security_group.backend.id
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = var.allowed_ssh_cidrs
  description       = "operator SSH"
}

resource "aws_security_group_rule" "backend_from_gateway" {
  type                     = "ingress"
  security_group_id        = aws_security_group.backend.id
  protocol                 = "tcp"
  from_port                = 8080
  to_port                  = 8080
  source_security_group_id = aws_security_group.gateway.id
  description              = "gateway HTTP/1.1 upstream"
}

resource "aws_security_group_rule" "backend_egress_internet" {
  type              = "egress"
  security_group_id = aws_security_group.backend.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "image + package pulls (HTTPS)"
}

resource "aws_security_group_rule" "backend_egress_internet_http" {
  type              = "egress"
  security_group_id = aws_security_group.backend.id
  protocol          = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "package pulls (HTTP)"
}

resource "aws_security_group_rule" "backend_egress_dns_udp" {
  type              = "egress"
  security_group_id = aws_security_group.backend.id
  protocol          = "udp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS"
}

resource "aws_security_group_rule" "backend_egress_dns_tcp" {
  type              = "egress"
  security_group_id = aws_security_group.backend.id
  protocol          = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS (TCP fallback)"
}

# -----------------------------------------------------------------------------
# NOTE — what is INTENTIONALLY NOT here
# -----------------------------------------------------------------------------
# There is NO rule allowing loadgen to backend on :8080. That edge is
# the network-level enforcement of the 3-host topology promise: a k6
# request MUST transit the gateway. Try it after `tofu apply`:
#
#   ssh ubuntu@<loadgen> curl --connect-timeout 2 http://10.50.1.30:8080/status/200
#
# to "connection refused" (SG-deny). This mirrors the behaviour of
# loadgen to backend in the local Docker stack, where loadgen is not
# a member of bench-upstream-net.
