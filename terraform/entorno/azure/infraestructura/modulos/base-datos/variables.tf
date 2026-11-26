variable "prefijo_nombre" {
  type        = string
  description = "Prefijo del nombre del servidor; se completa con un sufijo aleatorio"
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

variable "version_postgresql" {
  type = string
}

variable "sku" {
  type        = string
  description = "SKU con el prefijo del nivel"
}

variable "almacenamiento_mb" {
  type = number
}

variable "retencion_respaldos_dias" {
  type = number
}

variable "usuario_admin" {
  type    = string
  default = "pgadmin"
}

variable "subred_id" {
  type        = string
  description = "Subred delegada a Microsoft.DBforPostgreSQL/flexibleServers"
}

variable "vnet_id" {
  type        = string
  description = "VNet a la que se enlaza la zona DNS privada"
}

variable "zona_dns" {
  type        = string
  description = "Zona DNS privada; debe terminar en .postgres.database.azure.com"
}

variable "app_configuration_id" {
  type        = string
  description = "App Configuration de la capa base donde se escribe DB_HOST"
}

variable "etiqueta_app_configuration" {
  type        = string
  description = "Etiqueta del entorno en App Configuration (dev o prod)"
}
