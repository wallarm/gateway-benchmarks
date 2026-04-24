# infra/aws/locals.tf
#
# Single source of truth for the SCP-mandated tags. The provider's
# default_tags block applies these to standalone resources, but for
# RunInstances sub-resources (instance/volume/network-interface) they
# must be present in the API call's TagSpecifications — see
# launch_templates.tf for the propagation pattern.

locals {
  required_tags = {
    Product     = var.product_tag
    Project     = var.project_tag
    Environment = var.environment_tag
    Owner       = var.owner_tag
    ManagedBy   = "opentofu"
  }
}
