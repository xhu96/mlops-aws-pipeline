terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Bucket name is passed at init: terraform init -backend-config="bucket=churn-tfstate-<account>"
  backend "s3" {
    key          = "global/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "churn-mlops", ManagedBy = "terraform", Stack = "global" }
  }
}
