# Almacenes persistentes de secretos y variables de aplicación. Se crean una sola vez junto con la capa base.
# Destruir un entorno no los afecta.
#
# Contenido:
#   Key Vault (uno por entorno)   DJANGO-SECRET-KEY y DB-PASSWORD (los nombres de secretos de Key Vault no admiten guion bajo)
#   App Configuration (uno solo)  DB_USER, DB_NAME, DB_PORT, ALLOWED_HOSTS y CORS_ALLOWED_ORIGINS,
#                                 todas con la etiqueta del entorno (dev o prod)
#
# DB_HOST no se escribe aquí: depende del servidor PostgreSQL, que vive en la capa de entorno
# y se destruye con ella. La capa de entorno escribe DB_HOST en App Configuration, con la etiqueta de su entorno,
# al crear el servidor.
#
# El backend lee solo las claves con la etiqueta de su entorno (ENV=dev o prod).
# Una variable de entorno del pod con el mismo nombre que una clave la sustituye
# (por ejemplo ALLOWED_HOSTS en el ConfigMap del overlay); los secretos no se sustituyen.

data "azurerm_client_config" "actual" {}

locals {
  # Una entrada por entorno y clave: "dev/ALLOWED_HOSTS" => { etiqueta, clave, valor }
  config_entorno = merge([
    for e, host in var.host_por_entorno : {
      for k, v in {
        DB_USER              = var.db_usuario
        DB_NAME              = var.db_nombre
        DB_PORT              = tostring(var.db_puerto)
        ALLOWED_HOSTS        = host
        CORS_ALLOWED_ORIGINS = "https://${host}"
      } : "${e}/${k}" => { etiqueta = e, clave = k, valor = v }
    }
  ]...)
}

# Sufijo para nombres globalmente únicos (Key Vault y App Configuration)
resource "random_string" "almacenes" {
  length  = 4
  upper   = false
  special = false
}

# ---- Valores secretos generados por Terraform ----
resource "random_password" "django" {
  for_each         = var.host_por_entorno
  length           = 50
  special          = true
  override_special = "-_.~"
}
resource "random_password" "db" {
  for_each         = var.host_por_entorno
  length           = 32
  special          = true
  override_special = "-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# ---- Key Vault (uno por entorno) ----
resource "azurerm_key_vault" "entorno" {
  for_each                   = var.host_por_entorno
  name                       = "kv-${var.proyecto}-${each.key}-${random_string.almacenes.result}"
  location                   = azurerm_resource_group.base.location
  resource_group_name        = azurerm_resource_group.base.name
  tenant_id                  = data.azurerm_client_config.actual.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.etiquetas

  lifecycle { prevent_destroy = true }
}

# ---- App Configuration (un solo almacén, entornos separados con etiquetas) ----
resource "azurerm_app_configuration" "principal" {
  name                = "appcs-${var.proyecto}-${random_string.almacenes.result}"
  location            = azurerm_resource_group.base.location
  resource_group_name = azurerm_resource_group.base.name
  sku                 = var.sku_app_configuration
  tags                = local.etiquetas

  lifecycle { prevent_destroy = true }
}

# ---- Permisos ----
# Quien aplica la capa base (tu usuario) necesita escribir los valores iniciales.
resource "azurerm_role_assignment" "kv_aplicador" {
  for_each             = azurerm_key_vault.entorno
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}
resource "azurerm_role_assignment" "appcs_aplicador" {
  scope                = azurerm_app_configuration.principal.id
  role_definition_name = "App Configuration Data Owner"
  principal_id         = data.azurerm_client_config.actual.object_id
}

# La identidad de GitHub Actions (capa de entorno) lee la contraseña para crear el servidor
# y escribe DB_HOST en App Configuration. Contributor no incluye permisos de datos.
resource "azurerm_role_assignment" "kv_github" {
  for_each             = azurerm_key_vault.entorno
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.github.object_id
}
resource "azurerm_role_assignment" "appcs_github" {
  scope                = azurerm_app_configuration.principal.id
  role_definition_name = "App Configuration Data Owner"
  principal_id         = azuread_service_principal.github.object_id
}

# Los roles tardan en propagarse. Sin esta espera, la escritura de secretos puede fallar con 403.
resource "time_sleep" "propagacion_roles" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.kv_aplicador, azurerm_role_assignment.appcs_aplicador]
}

# ---- Valores iniciales ----
resource "azurerm_key_vault_secret" "django" {
  for_each     = var.host_por_entorno
  name         = "DJANGO-SECRET-KEY"
  value        = random_password.django[each.key].result
  key_vault_id = azurerm_key_vault.entorno[each.key].id
  depends_on   = [time_sleep.propagacion_roles]
}
resource "azurerm_key_vault_secret" "db_password" {
  for_each     = var.host_por_entorno
  name         = "DB-PASSWORD"
  value        = random_password.db[each.key].result
  key_vault_id = azurerm_key_vault.entorno[each.key].id
  depends_on   = [time_sleep.propagacion_roles]
}

# Claves propias de cada entorno, con la etiqueta dev o prod
resource "azurerm_app_configuration_key" "entorno" {
  for_each               = local.config_entorno
  configuration_store_id = azurerm_app_configuration.principal.id
  key                    = each.value.clave
  label                  = each.value.etiqueta
  value                  = each.value.valor
  depends_on             = [time_sleep.propagacion_roles]
}