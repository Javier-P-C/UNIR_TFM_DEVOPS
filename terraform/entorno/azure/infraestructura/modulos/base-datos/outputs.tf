output "nombre" {
  value = azurerm_postgresql_flexible_server.base_datos.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.base_datos.fqdn
}

output "usuario_admin" {
  value = azurerm_postgresql_flexible_server.base_datos.administrator_login
}

output "contrasena_admin" {
  value     = random_password.admin.result
  sensitive = true
}
