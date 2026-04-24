# infra/aws/versions.tf
#
# Terraform / OpenTofu version constraints + provider pins.
#
# We target OpenTofu ≥ 1.6 because that's the first release with
# stable provider plugin caching and the public registry mirror at
# registry.opentofu.org. Terraform ≥ 1.5 also works (the language
# subset we use is the OSS-licensed pre-fork core); see infra/aws/README.md.
#
# AWS provider pinned to ~> 5.x for the AWS SDK v2 codepaths and
# stable resource schemas. 6.x was a major bump; we'll cross that
# bridge when AWS deprecates the v5 plan format, not before.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  # State is intentionally local. Reviewers `tofu apply` from their
  # own laptop with their own AWS credentials and tear down at the
  # end of the run; nobody collaborates on the same state file. If
  # someone needs S3+DynamoDB locking, override via:
  #
  #   tofu init -backend-config="bucket=…" -backend-config="key=…" …
  #
  # but the default is zero-setup so a fresh `git clone` works.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "gateway-benchmarks"
      ManagedBy = "tofu"
      Phase     = "5"
      Owner     = var.owner_tag
    }
  }
}
