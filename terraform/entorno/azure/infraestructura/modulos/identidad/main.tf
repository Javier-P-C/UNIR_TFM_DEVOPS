# Identidad administrada de un ServiceAccount de Kubernetes: la credencial federada
# permite canjear el token del ServiceAccount, emitido por el OIDC issuer del clúster, por un token de Azure
# de esta identidad. Sin secretos ni credenciales guardadas en el clúster.
#
# Recibe lectura de secretos en el Key Vault del entorno y lectura de App Configuration.
# Son asignaciones sobre recursos de la capa base; se destruyen antes que la identidad por la dependencia,
# así que no quedan asignaciones huérfanas.
#
# ignore_changes sobre tags["ejecucion"]: ver el módulo de red.

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

resource "azurerm_user_assigned_identity" "identidad" {
  name                = var.nombre
  resource_group_name = var.grupo_recursos
  location            = var.ubicacion
  tags                = var.etiquetas

  lifecycle { ignore_changes = [tags["ejecucion"]] }
}

resource "azurerm_federated_identity_credential" "service_account" {
  name                      = var.nombre_credencial
  user_assigned_identity_id = azurerm_user_assigned_identity.identidad.id
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.service_account.namespace}:${var.service_account.nombre}"
  audience                  = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "key_vault" {
  scope                            = var.key_vault_id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.identidad.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# El almacén es único para todos los entornos: este rol permite leer las claves de cualquier etiqueta.
resource "azurerm_role_assignment" "app_configuration" {
  scope                            = var.app_configuration_id
  role_definition_name             = "App Configuration Data Reader"
  principal_id                     = azurerm_user_assigned_identity.identidad.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
