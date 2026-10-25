terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial configuration: supply envs/<env>.backend.hcl at `terraform init`.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "HomeScope"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "homescope-sg"
    }
  }
}
