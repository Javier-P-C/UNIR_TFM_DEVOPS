terraform {
  required_version = "~> 1.17"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    random  = { source = "hashicorp/random", version = "~> 3.9.0" }
    # Solo para el Job que prepara la base de datos (ver arranque-base-datos.tf y el README)
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.5" }
  }

  # Los valores del backend se pasan al ejecutar: terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}
