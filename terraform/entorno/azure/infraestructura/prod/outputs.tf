# Contrato con la configuración de aplicación, que lee estas salidas con terraform_remote_state.
# Cambiar el nombre o el significado de una salida obliga a cambiar también esa configuración.

# ---- Conexión al clúster (proveedores de Kubernetes y Helm) ----
output "cluster_host" {
  description = "URL del API server del clúster (argumento host de los proveedores)"
  value       = module.cluster.host
  sensitive   = true
}

output "cluster_certificado_cliente" {
  description = "Certificado de cliente en base64 (client_certificate, con base64decode)"
  value       = module.cluster.certificado_cliente
  sensitive   = true
}

output "cluster_clave_cliente" {
  description = "Clave privada del certificado de cliente en base64 (client_key, con base64decode)"
  value       = module.cluster.clave_cliente
  sensitive   = true
}

output "cluster_certificado_ca" {
  description = "Certificado de la autoridad del clúster en base64 (cluster_ca_certificate, con base64decode)"
  value       = module.cluster.certificado_ca
  sensitive   = true
}

output "cluster_nombre" {
  description = "Nombre del clúster, para az aks get-credentials"
  value       = module.cluster.nombre
}

output "grupo_recursos" {
  description = "Grupo de recursos del entorno, para az aks get-credentials"
  value       = module.red.grupo_recursos
}

# ---- Valores del overlay de Kubernetes ----
output "postgresql_fqdn" {
  description = "FQDN privado del servidor PostgreSQL (el mismo valor que DB_HOST en App Configuration)"
  value       = module.base_datos.fqdn
}

output "backend_client_id" {
  description = "Client-id de la identidad del backend: anotación azure.workload.identity/client-id del ServiceAccount"
  value       = module.identidad_backend.client_id
}

output "app_configuration_endpoint" {
  description = "Endpoint de App Configuration (capa base): APP_CONFIG_ENDPOINT del ConfigMap del backend"
  value       = local.base.app_configuration.endpoint
}

output "key_vault_uri" {
  description = "URI del Key Vault del entorno (capa base): KEY_VAULT_URL del ConfigMap del backend"
  value       = local.base.key_vault[var.entorno].uri
}

output "acr_servidor" {
  description = "Servidor del ACR (capa base): prefijo de las imágenes del overlay"
  value       = local.base.acr_servidor
}
