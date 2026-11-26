variable "nombre" {
  type = string
}

variable "grupo_recursos" {
  type = string
}

variable "ubicacion" {
  type = string
}

variable "etiquetas" {
  type        = map(string)
  description = "Etiquetas de terraform/docs/convencion-etiquetas.md (proyecto, entorno, ejecucion)"
}

variable "oidc_issuer_url" {
  type        = string
  description = "OIDC issuer del clúster que emite los tokens del ServiceAccount"
}

variable "service_account" {
  type = object({
    namespace = string
    nombre    = string
  })
  description = "ServiceAccount de Kubernetes que usa la identidad"
}

variable "nombre_credencial" {
  type        = string
  description = "Nombre de la credencial federada"
}

variable "key_vault_id" {
  type        = string
  description = "Key Vault del entorno (capa base) del que la identidad lee secretos"
}

variable "app_configuration_id" {
  type        = string
  description = "App Configuration (capa base) del que la identidad lee la configuración"
}
