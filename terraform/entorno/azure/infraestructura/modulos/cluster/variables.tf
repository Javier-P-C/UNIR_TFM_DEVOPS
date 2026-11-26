variable "nombre" {
  type        = string
  description = "Nombre del clúster; también se usa como prefijo DNS"
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

variable "nivel" {
  type        = string
  description = "Nivel del plano de control: Free o Standard"
}

variable "version_kubernetes" {
  type        = string
  description = "Versión menor de Kubernetes. AKS aplica el último parche disponible."
}

variable "nodos" {
  type = object({
    cantidad = number
    tamano   = string
  })
  description = "Grupo de nodos del sistema"
}

variable "subred_id" {
  type        = string
  description = "Subred de los nodos"
}

variable "red_kubernetes" {
  type = object({
    pod_cidr       = string
    service_cidr   = string
    dns_service_ip = string
  })
  description = "Rangos internos de Kubernetes. No deben solaparse con la VNet."
}

variable "acr_id" {
  type        = string
  description = "ACR de la capa base sobre el que el kubelet recibe AcrPull"
}
