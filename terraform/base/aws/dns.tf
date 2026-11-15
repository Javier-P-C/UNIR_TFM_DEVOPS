# Aquí Terraform crea la zona de Route 53. Después se copian los servidores de nombres
# de la salida en el panel del registrador.

variable "dominio" {
  type        = string
  description = "Dominio registrado en el registrador externo, por ejemplo midominio.com"
}

resource "aws_route53_zone" "principal" {
  name = var.dominio

  lifecycle { prevent_destroy = true }
}

output "zona_dns_id" {
  value = aws_route53_zone.principal.zone_id
}

# Estos cuatro valores se copian en el registrador como servidores de nombres (NS) del dominio.
output "zona_dns_servidores_nombres" {
  value = aws_route53_zone.principal.name_servers
}
