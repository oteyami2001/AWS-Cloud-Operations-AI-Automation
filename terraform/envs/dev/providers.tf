terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
  # Remote state: copy backend.tf.example -> backend.tf (S3, encrypted, versioned, S3-native locking).
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
