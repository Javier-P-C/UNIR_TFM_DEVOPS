# Secretos y variables de aplicación del entorno de recuperación (persistentes).
# Se crean una sola vez junto con la capa base. Destruir el entorno de recuperación no los afecta.
#
# Contenido:
#   Secrets Manager  DJANGO_SECRET_KEY y DB_PASSWORD
#   Parameter Store  DB_USER, DB_NAME, DB_PORT, ALLOWED_HOSTS y CORS_ALLOWED_ORIGINS
#
# DB_HOST no se escribe aquí: el endpoint de RDS lleva un identificador aleatorio y solo existe
# mientras el entorno está levantado. La capa de entorno escribe ${local.prefijo_parametros}/DB_HOST al crear la base.

locals {
  prefijo_secretos   = "${var.proyecto}/recuperacion"
  prefijo_parametros = "/${var.proyecto}/recuperacion"

  config = {
    DB_USER              = var.db_usuario
    DB_NAME              = var.db_nombre
    DB_PORT              = tostring(var.db_puerto)
    ALLOWED_HOSTS        = var.host_prod
    CORS_ALLOWED_ORIGINS = "https://${var.host_prod}"
  }

  valores_secretos = {
    DJANGO_SECRET_KEY = random_password.django.result
    DB_PASSWORD       = random_password.db.result
  }
}

resource "random_password" "django" {
  length           = 50
  special          = true
  override_special = "-_.~"
}
# RDS no admite "/", "@", comillas ni espacios en la contraseña del usuario maestro
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_secretsmanager_secret" "app" {
  for_each                = toset(["DJANGO_SECRET_KEY", "DB_PASSWORD"])
  name                    = "${local.prefijo_secretos}/${each.key}"
  recovery_window_in_days = 7

  lifecycle { prevent_destroy = true }
}
resource "aws_secretsmanager_secret_version" "app" {
  for_each      = aws_secretsmanager_secret.app
  secret_id     = each.value.id
  secret_string = local.valores_secretos[each.key]
}

resource "aws_ssm_parameter" "config" {
  for_each = local.config
  name     = "${local.prefijo_parametros}/${each.key}"
  type     = "String"
  value    = each.value
}
