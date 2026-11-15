variable "proyecto" {
  type    = string
  default = "tfm-unir"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repo" {
  type        = string
  description = "Repositorio en formato propietario/repositorio"
}

variable "entornos_github" {
  type    = list(string)
  default = ["dev", "prod"]
}

variable "repositorios_ecr" {
  type    = list(string)
  default = ["backend", "frontend"]
}

variable "bucket_respaldos" {
  type        = string
  description = "Nombre único global del bucket de respaldos de la base de datos"
}

variable "dias_retencion_respaldos" {
  type    = number
  default = 30
}

variable "host_prod" {
  type        = string
  description = "Nombre de host público de producción. La recuperación en AWS responde con el mismo nombre. Debe coincidir con host_por_entorno[\"prod\"] de Azure."
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

variable "github_repo_sujeto" {
  type        = string
  default     = null
  description = "Repositorio tal como aparece en el subject del token OIDC. Con subject inmutable: propietario@ID/repositorio@ID. Si es null se usa github_repo."
}