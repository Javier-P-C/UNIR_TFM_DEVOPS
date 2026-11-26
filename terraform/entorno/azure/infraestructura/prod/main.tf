# Infraestructura de un entorno en Azure: red, clúster, base de datos e identidad del backend.
# Se crea y se destruye entera en cada ciclo; no lleva prevent_destroy.
#
# Lee la capa base con terraform_remote_state y no la modifica: solo añade asignaciones de rol
# sobre sus recursos y la clave DB_HOST en App Configuration, que se destruyen con este estado.

provider "azurerm" {
  features {}
  subscription_id = var.suscripcion_id
}

# ---- Capa base ----
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.rg_estado
    storage_account_name = var.cuenta_estado
    container_name       = var.contenedor_estado
    key                  = var.clave_estado_base
    use_azuread_auth     = true
  }
}

locals {
  base = data.terraform_remote_state.base.outputs
  # Grupo de la capa base: sus salidas dan los nombres de los recursos, no el grupo
  rg_base = "rg-${var.proyecto}-base"

  nombre = "${var.proyecto}-${var.entorno}"
  etiquetas = {
    proyecto  = var.proyecto
    entorno   = { dev = "desarrollo", prod = "produccion" }[var.entorno]
    ejecucion = var.ejecucion
  }
}

# Ids de los recursos de la capa base, ámbito de las asignaciones de rol
data "azurerm_container_registry" "base" {
  name                = local.base.acr_nombre
  resource_group_name = local.rg_base
}

data "azurerm_key_vault" "entorno" {
  name                = local.base.key_vault[var.entorno].nombre
  resource_group_name = local.rg_base
}

data "azurerm_app_configuration" "base" {
  name                = local.base.app_configuration.nombre
  resource_group_name = local.rg_base
}

# ---- Módulos ----
module "red" {
  source = "../modulos/red"

  grupo_recursos      = "rg-${local.nombre}"
  ubicacion           = var.ubicacion
  etiquetas           = local.etiquetas
  vnet_nombre         = "vnet-${local.nombre}"
  espacio_direcciones = var.espacio_direcciones
  subred_cluster      = var.subred_cluster
  subred_base_datos   = var.subred_base_datos
  puerto_base_datos   = tonumber(data.azurerm_app_configuration_key.db_port.value)
}

module "cluster" {
  source = "../modulos/cluster"

  nombre             = "aks-${local.nombre}"
  grupo_recursos     = module.red.grupo_recursos
  ubicacion          = module.red.ubicacion
  etiquetas          = local.etiquetas
  nivel              = var.nivel_cluster
  version_kubernetes = var.version_kubernetes
  nodos              = var.nodos
  subred_id          = module.red.subred_cluster_id
  red_kubernetes     = var.red_kubernetes
  acr_id             = data.azurerm_container_registry.base.id
}

module "base_datos" {
  source = "../modulos/base-datos"

  prefijo_nombre             = "psql-${local.nombre}"
  grupo_recursos             = module.red.grupo_recursos
  ubicacion                  = module.red.ubicacion
  etiquetas                  = local.etiquetas
  version_postgresql         = var.version_postgresql
  sku                        = var.sku_postgresql
  almacenamiento_mb          = var.almacenamiento_postgresql_mb
  retencion_respaldos_dias   = var.retencion_respaldos_dias
  subred_id                  = module.red.subred_base_datos_id
  vnet_id                    = module.red.vnet_id
  zona_dns                   = var.zona_dns_postgresql
  app_configuration_id       = data.azurerm_app_configuration.base.id
  etiqueta_app_configuration = var.entorno
}

module "identidad_backend" {
  source = "../modulos/identidad"

  nombre               = "id-${local.nombre}-backend"
  grupo_recursos       = module.red.grupo_recursos
  ubicacion            = module.red.ubicacion
  etiquetas            = local.etiquetas
  oidc_issuer_url      = module.cluster.oidc_issuer_url
  service_account      = var.service_account_backend
  nombre_credencial    = var.service_account_backend.nombre
  key_vault_id         = data.azurerm_key_vault.entorno.id
  app_configuration_id = data.azurerm_app_configuration.base.id
}
