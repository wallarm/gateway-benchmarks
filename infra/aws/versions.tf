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

  # Cap RunInstances retries: the AWS SDK default is 25 attempts with
  # exponential backoff, which means an InsufficientInstanceCapacity
  # error in a single AZ keeps the operator waiting up to ~90 minutes
  # before tofu apply gives up (run aws-20260430T102216Z burned 1h23m
  # waiting on c7i.2xlarge in eu-central-1a before failing). 5
  # attempts × ~1-2 minutes per backoff caps the wait at ~5-10 min,
  # so a cold-AZ situation surfaces fast and the operator can either
  # rerun (capacity often appears within minutes) or pick a different
  # instance type / AZ.
  max_retries = 5

  # Default tags applied to every resource. Some AWS Organizations
  # enforce mandatory tags via SCP — Wallarm's qa account, for
  # example, requires `Product` and `Environment` on every resource
  # or `ec2:CreateVpc` / `ec2:RunInstances` is denied. Override
  # `product_tag` / `environment_tag` from terraform.tfvars to fit
  # your org's tag policy.
  default_tags {
    tags = {
      Product     = var.product_tag
      Project     = var.project_tag
      Environment = var.environment_tag
      Owner       = var.owner_tag
      ManagedBy   = "opentofu"
    }
  }
}
