terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# AWS Provider
provider "aws" {
  region = var.aws_region
}

locals {
  eks_enabled = var.enable_eks && !var.enable_ec2
}
