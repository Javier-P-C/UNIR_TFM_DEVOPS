variable "grupo_recursos" {
  type        = string
  description = "Nombre del grupo de recursos del entorno. Todo lo que crea la capa vive en él."
}

variable "ubicacion" {
  type = string
}

variable "etiquetas" {
  type        = map(string)
  description = "Etiquetas de terraform/docs/convencion-etiquetas.md (proyecto, entorno, ejecucion)"
}

variable "vnet_nombre" {
  type = string
}

variable "espacio_direcciones" {
  type        = list(string)
  description = "Rangos de la VNet"
}

variable "subred_cluster" {
  type = object({
    nombre  = string
    prefijo = string
  })
  description = "Subred de los nodos del clúster"
}

variable "subred_base_datos" {
  type = object({
    nombre  = string
    prefijo = string
  })
  description = "Subred delegada a PostgreSQL Flexible Server"
}

variable "puerto_base_datos" {
  type    = number
  default = 5432
}
