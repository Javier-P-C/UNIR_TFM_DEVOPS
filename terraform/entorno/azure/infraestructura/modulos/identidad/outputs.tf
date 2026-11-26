output "id" {
  value = azurerm_user_assigned_identity.identidad.id
}

output "client_id" {
  value = azurerm_user_assigned_identity.identidad.client_id
}

output "principal_id" {
  value = azurerm_user_assigned_identity.identidad.principal_id
}
