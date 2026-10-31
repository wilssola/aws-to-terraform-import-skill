terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state by default. To move to S3 later:
  # backend "s3" {
  #   bucket       = "<project>-terraform-state"
  #   key          = "infra/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   profile      = "<project>-terraform"
  # }
}
