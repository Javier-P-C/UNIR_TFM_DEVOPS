# Los valores del entorno están en prod.tfvars.
# Los de la sesión y la cuenta se pasan aparte, con TF_VAR_<nombre>: suscripcion_id, cuenta_estado y ejecucion.

# ---- Sesión y cuenta (fuera de prod.tfvars) ----
variable "suscripcion_id" {
  type = string
}

variable "ejecucion" {
  type        = string
  description = "Id de la sesión que crea el entorno (DD-MM-AAAA-x). Solo se registra al crear cada recurso."
}

variable "cuenta_estado" {
  type        = string
  description = "Cuenta de almacenamiento del estado remoto (creada en el arranque); la misma de backend.hcl"
}

# ---- Estado remoto de la capa base ----
variable "rg_estado" {
  type    = string
  default = "rg-tfm-unir-estado"
}

variable "contenedor_estado" {
  type    = string
  default = "tfstate"
}

variable "clave_estado_base" {
  type    = string
  default = "base-azure.tfstate"
}

# ---- Entorno ----
variable "proyecto" {
  type    = string
  default = "tfm-unir"
}

variable "entorno" {
  type        = string
  description = "dev o prod: Key Vault de la capa base y etiqueta en App Configuration"
  validation {
    condition     = contains(["dev", "prod"], var.entorno)
    error_message = "entorno debe ser dev o prod."
  }
}

variable "ubicacion" {
  type = string
}

# ---- Red ----
variable "espacio_direcciones" {
  type = list(string)
}

variable "subred_cluster" {
  type = object({
    nombre  = string
    prefijo = string
  })
}

variable "subred_base_datos" {
  type = object({
    nombre  = string
    prefijo = string
  })
}

# ---- Clúster ----
variable "nivel_cluster" {
  type = string
}

variable "version_kubernetes" {
  type = string
}

variable "nodos" {
  type = object({
    cantidad = number
    tamano   = string
  })
}

variable "red_kubernetes" {
  type = object({
    pod_cidr       = string
    service_cidr   = string
    dns_service_ip = string
  })
}

# ---- Base de datos ----
variable "version_postgresql" {
  type = string
}

variable "sku_postgresql" {
  type = string
}

variable "almacenamiento_postgresql_mb" {
  type = number
}

variable "retencion_respaldos_dias" {
  type = number
}

variable "zona_dns_postgresql" {
  type = string
}

variable "imagen_cliente_postgresql" {
  type        = string
  description = "Imagen del Job que crea el rol y la base de la aplicación; misma versión mayor que el servidor"
}

# ---- Identidad del backend ----
variable "service_account_backend" {
  type = object({
    namespace = string
    nombre    = string
  })
  description = "ServiceAccount de los manifiestos (k8s/base) que usa la identidad del backend"
}
