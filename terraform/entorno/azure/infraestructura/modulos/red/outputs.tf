output "grupo_recursos" {
  value = azurerm_resource_group.entorno.name
}

output "ubicacion" {
  value = azurerm_resource_group.entorno.location
}

output "vnet_id" {
  value = azurerm_virtual_network.entorno.id
}

output "subred_cluster_id" {
  value = azurerm_subnet.cluster.id
}

# Depende de la asociación del NSG: quien use la subred (el servidor PostgreSQL) la recibe ya protegida.
output "subred_base_datos_id" {
  value      = azurerm_subnet.base_datos.id
  depends_on = [azurerm_subnet_network_security_group_association.base_datos]
}
