provider "azurerm" {
  features {
     key_vault {
       purge_soft_delete_on_destroy    = true
       recover_soft_deleted_key_vaults = true
     }
   }
  subscription_id     = var.suscripcion_id
  storage_use_azuread = true
}
provider "azuread" {}

data "azurerm_subscription" "actual" {}

locals {
  sujeto_repo = coalesce(var.github_repo_sujeto, var.github_repo)
  etiquetas = {
    proyecto  = var.proyecto
    entorno   = "base"
    ejecucion = "capa-base"
  }
}

# ---- Grupo de recursos de la capa base ----
resource "azurerm_resource_group" "base" {
  name     = "rg-${var.proyecto}-base"
  location = var.ubicacion
  tags     = local.etiquetas
}

# ---- Registro de contenedores (ACR) ----
resource "random_string" "acr" {
  length  = 6
  upper   = false
  special = false
}
resource "azurerm_container_registry" "acr" {
  name                = "acr${replace(var.proyecto, "-", "")}${random_string.acr.result}"
  resource_group_name = azurerm_resource_group.base.name
  location            = azurerm_resource_group.base.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.etiquetas

  lifecycle { prevent_destroy = true }
}

# ---- Identidad de GitHub Actions (OIDC, sin secretos) ----
resource "azuread_application" "github" {
  display_name = "${var.proyecto}-github-actions"
}
resource "azuread_service_principal" "github" {
  client_id = azuread_application.github.client_id
}
resource "azuread_application_federated_identity_credential" "entorno" {
  for_each       = toset(var.entornos_github)
  application_id = azuread_application.github.id
  display_name   = "github-${each.key}"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.sujeto_repo}:environment:${each.key}"
  audiences      = ["api://AzureADTokenExchange"]
}
resource "azuread_application_federated_identity_credential" "pull_request" {
  application_id = azuread_application.github.id
  display_name   = "github-pull-request"
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${local.sujeto_repo}:pull_request"
  audiences      = ["api://AzureADTokenExchange"]
}

# Permisos para crear y destruir los entornos. Reducir el alcance cuando el diseño esté definido.
resource "azurerm_role_assignment" "contributor" {
  scope                = data.azurerm_subscription.actual.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.github.object_id
}
# Necesario para asignar roles dentro de los entornos (por ejemplo, AKS con acceso a ACR).
resource "azurerm_role_assignment" "acceso_roles" {
  scope                = data.azurerm_subscription.actual.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.github.object_id
}
# Acceso al estado remoto con Azure AD (sin claves de la cuenta).
data "azurerm_storage_account" "estado" {
  name                = var.cuenta_estado
  resource_group_name = var.rg_estado
}
resource "azurerm_role_assignment" "estado" {
  scope                = data.azurerm_storage_account.estado.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github.object_id
}
