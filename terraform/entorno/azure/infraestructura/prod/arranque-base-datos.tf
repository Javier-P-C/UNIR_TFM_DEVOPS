# Preparación de la base de datos: rol y base de la aplicación y permiso en el esquema public.
#
# El servidor no tiene acceso público y no se alcanza desde quien ejecuta Terraform, así que el SQL
# se ejecuta desde un Job dentro del clúster, que sí está en la VNet. Es la única razón por la que
# esta configuración usa el proveedor de Kubernetes.
#
# El Job no lleva ttlSecondsAfterFinished: si Kubernetes lo borrara, el siguiente plan lo volvería a crear.

provider "kubernetes" {
  host                   = module.cluster.host
  client_certificate     = base64decode(module.cluster.certificado_cliente)
  client_key             = base64decode(module.cluster.clave_cliente)
  cluster_ca_certificate = base64decode(module.cluster.certificado_ca)
}

# Usuario, base y puerto de la aplicación: los mismos que lee el backend (capa base)
data "azurerm_app_configuration_key" "db_user" {
  configuration_store_id = data.azurerm_app_configuration.base.id
  key                    = "DB_USER"
  label                  = var.entorno
}

data "azurerm_app_configuration_key" "db_name" {
  configuration_store_id = data.azurerm_app_configuration.base.id
  key                    = "DB_NAME"
  label                  = var.entorno
}

data "azurerm_app_configuration_key" "db_port" {
  configuration_store_id = data.azurerm_app_configuration.base.id
  key                    = "DB_PORT"
  label                  = var.entorno
}

# Contraseña de la aplicación: el mismo secreto que lee el backend
data "azurerm_key_vault_secret" "db_password" {
  name         = "DB-PASSWORD"
  key_vault_id = data.azurerm_key_vault.entorno.id
}

locals {
  # En default: el namespace de la aplicación lo crea su configuración, no esta
  namespace_arranque = "default"
}

resource "kubernetes_secret_v1" "arranque_base_datos" {
  metadata {
    name      = "arranque-base-datos"
    namespace = local.namespace_arranque
  }
  data = {
    PGPASSWORD = module.base_datos.contrasena_admin
    APP_PASS   = data.azurerm_key_vault_secret.db_password.value
  }
}

resource "kubernetes_job_v1" "arranque_base_datos" {
  metadata {
    name      = "arranque-base-datos"
    namespace = local.namespace_arranque
  }

  spec {
    # Reintentos: justo después de crear el clúster la red o el DNS del pod pueden tardar en estar listos
    backoff_limit           = 4
    active_deadline_seconds = 600

    template {
      metadata {}
      spec {
        restart_policy = "Never"

        security_context {
          run_as_non_root = true
          run_as_user     = 999 # usuario postgres de la imagen
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "psql"
          image = var.imagen_cliente_postgresql
          # El SQL entra por una tubería: psql no sustituye variables (:'app_pass') dentro de -c
          command = ["sh", "-c", "printf '%s\\n' \"$SQL_ARRANQUE\" | psql -v ON_ERROR_STOP=1 -v db_user=\"$DB_USER\" -v db_name=\"$DB_NAME\" -v app_pass=\"$APP_PASS\""]

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }

          env {
            name  = "PGHOST"
            value = module.base_datos.fqdn
          }
          env {
            name  = "PGPORT"
            value = data.azurerm_app_configuration_key.db_port.value
          }
          env {
            name  = "PGUSER"
            value = module.base_datos.usuario_admin
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name  = "PGSSLMODE"
            value = "require"
          }
          env {
            name  = "DB_USER"
            value = data.azurerm_app_configuration_key.db_user.value
          }
          env {
            name  = "DB_NAME"
            value = data.azurerm_app_configuration_key.db_name.value
          }
          env {
            name  = "SQL_ARRANQUE"
            value = file("${path.module}/arranque-base-datos.sql")
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.arranque_base_datos.metadata[0].name
                key  = "PGPASSWORD"
              }
            }
          }
          env {
            name = "APP_PASS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.arranque_base_datos.metadata[0].name
                key  = "APP_PASS"
              }
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
  }
}
