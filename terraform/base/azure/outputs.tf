output "acr_nombre" { value = azurerm_container_registry.acr.name }
output "acr_servidor" { value = azurerm_container_registry.acr.login_server }
output "github_client_id" { value = azuread_application.github.client_id }
output "tenant_id" { value = data.azurerm_subscription.actual.tenant_id }
output "suscripcion_id" { value = var.suscripcion_id }
output "key_vault" {
  value = { for e, k in azurerm_key_vault.entorno : e => { nombre = k.name, uri = k.vault_uri } }
}
output "app_configuration" {
  value = { nombre = azurerm_app_configuration.principal.name, endpoint = azurerm_app_configuration.principal.endpoint }
}