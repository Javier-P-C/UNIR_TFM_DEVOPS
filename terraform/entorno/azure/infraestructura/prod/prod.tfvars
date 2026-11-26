# Valores del entorno de producción. 
# Son los mismos que usa k8s/docs/runbook-linea-base-produccion.md (pasos 2 a 5)
# Versiones y tamaños fijados: no cambiarlos entre mediciones.
#
# Se pasan aparte, con TF_VAR_<nombre>: suscripcion_id, cuenta_estado y ejecucion.

entorno   = "prod"
ubicacion = "eastus2"

# ---- Red ----
espacio_direcciones = ["10.20.0.0/16"]
subred_cluster      = { nombre = "snet-aks", prefijo = "10.20.0.0/22" }
subred_base_datos   = { nombre = "snet-postgres", prefijo = "10.20.4.0/24" }

# ---- Clúster ----
nivel_cluster      = "Free"
version_kubernetes = "1.36"
nodos              = { cantidad = 2, tamano = "Standard_D2als_v6" }
# Rangos internos de Kubernetes; no se solapan con la VNet
red_kubernetes = {
  pod_cidr       = "10.244.0.0/16"
  service_cidr   = "10.0.0.0/16"
  dns_service_ip = "10.0.0.10"
}

# ---- Base de datos ----
version_postgresql           = "18"
sku_postgresql               = "B_Standard_B2s"
almacenamiento_postgresql_mb = 32768
retencion_respaldos_dias     = 7
zona_dns_postgresql          = "tfm-prod.private.postgres.database.azure.com"
imagen_cliente_postgresql    = "postgres:18"

# ---- Identidad del backend ----
service_account_backend = { namespace = "gymscreen", nombre = "backend" }
