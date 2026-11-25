terraform {
  required_version = "~> 1.17"

  required_providers {
    time    = { source = "hashicorp/time", version = "~> 0.13" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.1.0" }
    random  = { source = "hashicorp/random", version = "~> 3.9.0" }
  }

  # Los valores del backend se pasan al ejecutar: terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}
