variable "proyecto" {
  type    = string
  default = "tfm-unir"
}

variable "ubicacion" {
  type    = string
  default = "eastus2"
}

variable "suscripcion_id" { 
  type = string 
}

variable "github_repo" {
  type        = string
  description = "Repositorio en formato propietario/repositorio"
}

variable "entornos_github" {
  type    = list(string)
  default = ["dev", "prod"]
}

variable "rg_estado" {
  type        = string
  description = "Grupo de recursos del estado remoto (creado en el arranque)"
  default     = "rg-tfm-unir-estado"
}

variable "cuenta_estado" {
  type        = string
  description = "Cuenta de almacenamiento del estado remoto (creada en el arranque)"
}

variable "host_por_entorno" {
  type        = map(string)
  description = "Nombre de host público de cada entorno. Las claves (dev, prod) definen los Key Vault que se crean y las etiquetas de App Configuration."
  # Ejemplo: { dev = "dev.midominio.com", prod = "app.midominio.com" }
}

variable "db_usuario" {
  type    = string
  default = "tfm_app"
}

variable "db_nombre" {
  type    = string
  default = "tfm"
}

variable "db_puerto" {
  type    = number
  default = 5432
}

variable "sku_app_configuration" {
  type        = string
  description = "free o standard"
  default     = "free"
}