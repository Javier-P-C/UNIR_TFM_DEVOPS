output "ecr_repositorios" { value = { for k, r in aws_ecr_repository.repo : k => r.repository_url } }
output "rol_github_arn" { value = aws_iam_role.github.arn }
output "bucket_respaldos" { value = aws_s3_bucket.respaldos.bucket }
output "cuenta_aws" { value = data.aws_caller_identity.actual.account_id }
output "secretos_arn" { value = { for k, s in aws_secretsmanager_secret.app : k => s.arn } }
output "prefijo_parametros" { value = local.prefijo_parametros }