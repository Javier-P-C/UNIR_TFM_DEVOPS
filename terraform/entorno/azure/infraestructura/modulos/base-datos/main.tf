# PostgreSQL Flexible Server sin acceso público, en una subred delegada, con su nombre resuelto
# por una zona DNS privada enlazada a la VNet. Escribe DB_HOST en App Configuration con la etiqueta del entorno.
#
# ignore_changes sobre tags["ejecucion"]: ver el módulo de red.

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    random  = { source = "hashicorp/random" }
  }
}

# Azure reserva durante un tiempo el nombre de un servidor borrado: un nombre fijo haría fallar la recreación.
# El sufijo vive en el estado, así que es estable mientras exista el entorno y nuevo en cada recreación.
resource "random_string" "sufijo" {
  length  = 6
  upper   = false
  special = false
}

# Solo para la preparación de la base (rol y base de la aplicación). La aplicación usa su propio usuario.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_private_dns_zone" "base_datos" {
  name                = var.zona_dns
  resource_group_name = var.grupo_recursos
  tags                = var.etiquetas

  lifecycle { ignore_changes = [tags["ejecucion"]] }
}

resource "azurerm_private_dns_zone_virtual_network_link" "base_datos" {
  name                 = "enlace-${basename(var.vnet_id)}"
  private_dns_zone_id  = azurerm_private_dns_zone.base_datos.id
  virtual_network_id   = var.vnet_id
  registration_enabled = false
}

resource "azurerm_postgresql_flexible_server" "base_datos" {
  name                          = "${var.prefijo_nombre}-${random_string.sufijo.result}"
  resource_group_name           = var.grupo_recursos
  location                      = var.ubicacion
  version                       = var.version_postgresql
  sku_name                      = var.sku
  storage_mb                    = var.almacenamiento_mb
  backup_retention_days         = var.retencion_respaldos_dias
  delegated_subnet_id           = var.subred_id
  private_dns_zone_id           = azurerm_private_dns_zone.base_datos.id
  public_network_access_enabled = false

  administrator_login = var.usuario_admin
  # Solo escritura: la contraseña no se guarda en este recurso del estado
  administrator_password_wo         = random_password.admin.result
  administrator_password_wo_version = 1

  tags = var.etiquetas

  # El enlace tiene que existir antes que el servidor para que el nombre resuelva desde la VNet
  depends_on = [azurerm_private_dns_zone_virtual_network_link.base_datos]

  lifecycle {
    # Azure elige la zona de disponibilidad al crear el servidor
    ignore_changes = [zone, tags["ejecucion"]]
  }
}

# El backend lee DB_HOST de App Configuration con la etiqueta de su entorno, junto con las claves de la capa base.
resource "azurerm_app_configuration_key" "db_host" {
  configuration_store_id = var.app_configuration_id
  key                    = "DB_HOST"
  label                  = var.etiqueta_app_configuration
  value                  = azurerm_postgresql_flexible_server.base_datos.fqdn
}
