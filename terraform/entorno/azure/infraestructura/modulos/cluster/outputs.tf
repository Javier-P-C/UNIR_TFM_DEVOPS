output "id" {
  value = azurerm_kubernetes_cluster.cluster.id
}

output "nombre" {
  value = azurerm_kubernetes_cluster.cluster.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.cluster.oidc_issuer_url
}

# Conexión al API server para los proveedores de Kubernetes y Helm (cuenta local del clúster)
output "host" {
  value     = azurerm_kubernetes_cluster.cluster.kube_config[0].host
  sensitive = true
}

output "certificado_cliente" {
  value     = azurerm_kubernetes_cluster.cluster.kube_config[0].client_certificate
  sensitive = true
}

output "clave_cliente" {
  value     = azurerm_kubernetes_cluster.cluster.kube_config[0].client_key
  sensitive = true
}

output "certificado_ca" {
  value     = azurerm_kubernetes_cluster.cluster.kube_config[0].cluster_ca_certificate
  sensitive = true
}
