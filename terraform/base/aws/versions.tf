terraform {
  required_version = "~> 1.17" 

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
    time = { source = "hashicorp/time", version = "~> 0.13" }
  random = { source = "hashicorp/random", version = "~> 3.9.0" }
  }

  # Los valores del backend se pasan al ejecutar: terraform init -backend-config=backend.hcl
  backend "s3" {}
}
