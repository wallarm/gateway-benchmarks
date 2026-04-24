# infra/aws/outputs.tf
#
# Surface the values the operator + Makefile actually need:
#   - public IPs (for SSH from operator's laptop)
#   - private IPs (for verifying / debugging the topology)
#   - ready-to-paste SSH commands
#   - one-shot helpers for the canonical bench flow

output "loadgen_public_ip" {
  description = "Public IPv4 of the loadgen host. SSH from operator: ssh -i ~/.ssh/<key> ubuntu@<this-ip>"
  value       = aws_instance.loadgen.public_ip
}

output "loadgen_private_ip" {
  description = "Private IPv4 of the loadgen host inside the VPC."
  value       = aws_instance.loadgen.private_ip
}

output "gateway_public_ip" {
  description = "Public IPv4 of the gateway host."
  value       = aws_instance.gateway.public_ip
}

output "gateway_private_ip" {
  description = "Private IPv4 of the gateway host (k6 will hit this on :9080 / :9443)."
  value       = aws_instance.gateway.private_ip
}

output "backend_public_ip" {
  description = "Public IPv4 of the backend host."
  value       = aws_instance.backend.public_ip
}

output "backend_private_ip" {
  description = "Private IPv4 of the backend host (only the gateway should connect here)."
  value       = aws_instance.backend.private_ip
}

output "ssh_loadgen" {
  description = "Ready-to-paste SSH command for the loadgen host."
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.loadgen.public_ip}"
}

output "ssh_gateway" {
  description = "Ready-to-paste SSH command for the gateway host."
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.gateway.public_ip}"
}

output "ssh_backend" {
  description = "Ready-to-paste SSH command for the backend host."
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.backend.public_ip}"
}

output "summary" {
  description = "Human-readable summary of the cluster — printed after `tofu apply` to remind the operator of the topology and ready-to-use SSH commands."
  value = <<-EOT
    Cluster: ${var.name_prefix}-cluster (placement_group=cluster, az=${var.availability_zone})
    Region:  ${var.aws_region}

    loadgen  ${aws_instance.loadgen.public_ip}  (private ${aws_instance.loadgen.private_ip})
    gateway  ${aws_instance.gateway.public_ip}  (private ${aws_instance.gateway.private_ip})
    backend  ${aws_instance.backend.public_ip}  (private ${aws_instance.backend.private_ip})

    Loadgen  to Gateway   :9080 + :9443  (allowed by SG)
    Gateway  to Backend   :8080          (allowed by SG)
    Loadgen  to Backend   :8080          (DENIED by SG — must transit gateway)

    Wait ~2 min for cloud-init / Docker bootstrap to finish, then:

      ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.gateway.public_ip}
        sudo docker ps        # verify Docker is up
        cd /opt/gateway-benchmarks
        bash scripts/parity-gateway.sh --gateway nginx --profile p01-vanilla --target http://localhost:9080

      ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.loadgen.public_ip}
        BENCH_TARGET_URL=http://${aws_instance.gateway.private_ip}:9080 \
        BENCH_TARGET_URL_HTTPS=https://${aws_instance.gateway.private_ip}:9443 \
        bash /opt/gateway-benchmarks/scripts/load-gateway.sh \
          --gateway nginx --policy p01-vanilla \
          --scenario s01-vanilla-http --load p1-baseline

    Tear down with:  make perf-aws-destroy
  EOT
}

output "bench_target_url_http" {
  description = "BENCH_TARGET_URL value to pass to scripts/load-gateway.sh from the loadgen host."
  value       = "http://${aws_instance.gateway.private_ip}:9080"
}

output "bench_target_url_https" {
  description = "BENCH_TARGET_URL_HTTPS value to pass to scripts/load-gateway.sh from the loadgen host."
  value       = "https://${aws_instance.gateway.private_ip}:9443"
}
