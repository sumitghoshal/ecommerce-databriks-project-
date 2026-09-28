terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Create this bucket MANUALLY before `terraform init` (see scripts/bootstrap_backend.sh).
  # Terraform cannot create the bucket that stores its own state.
  backend "s3" {
    bucket  = "ecommerce-devops-tfstate-CHANGE-ME"
    key     = "global/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ecommerce-devops"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
