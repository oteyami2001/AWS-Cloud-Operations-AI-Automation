terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Local state by default. For team use copy backend.tf.example -> backend.tf after
  # applying terraform/bootstrap.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
      Repository  = "AWS-Cloud-Operations-AI-Automation"
      CostCenter  = "portfolio-demo"
    }
  }
}
