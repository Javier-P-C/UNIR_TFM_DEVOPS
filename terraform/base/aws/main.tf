provider "aws" {
  region = var.region
  default_tags {
    tags = {
      proyecto  = var.proyecto
      entorno   = "base"
      ejecucion = "capa-base"
    }
  }
}

data "aws_caller_identity" "actual" {}

# ---- Registro de contenedores (ECR) ----
resource "aws_ecr_repository" "repo" {
  for_each             = toset(var.repositorios_ecr)
  name                 = "${var.proyecto}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = false }

  lifecycle { prevent_destroy = true }
}

# ---- Almacenamiento de respaldos (fuera de Azure) ----
resource "aws_s3_bucket" "respaldos" {
  bucket = var.bucket_respaldos
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "respaldos" {
  bucket                  = aws_s3_bucket.respaldos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "respaldos" {
  bucket = aws_s3_bucket.respaldos.id
  rule {
    id     = "expirar-respaldos"
    status = "Enabled"
    filter {}
    expiration { days = var.dias_retencion_respaldos }
    noncurrent_version_expiration { noncurrent_days = var.dias_retencion_respaldos }
  }
}

# ---- Identidad de GitHub Actions (OIDC, sin secretos) ----
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "confianza" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        [for e in var.entornos_github : "repo:${var.github_repo}:environment:${e}"],
        ["repo:${var.github_repo}:pull_request"]
      )
    }
  }
}
resource "aws_iam_role" "github" {
  name                 = "${var.proyecto}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.confianza.json
  max_session_duration = 7200
}

# Permisos para crear y destruir los entornos. Reducir cuando el diseño esté definido.
resource "aws_iam_role_policy_attachment" "poweruser" {
  role       = aws_iam_role.github.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
# PowerUserAccess excluye IAM. Los entornos necesitan crear roles (EKS, nodos) solo con el prefijo del proyecto.
data "aws_iam_policy_document" "iam_acotado" {
  statement {
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:PassRole", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider", "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
      "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.actual.account_id}:role/${var.proyecto}-*",
      "arn:aws:iam::${data.aws_caller_identity.actual.account_id}:policy/${var.proyecto}-*",
      "arn:aws:iam::${data.aws_caller_identity.actual.account_id}:instance-profile/${var.proyecto}-*",
      "arn:aws:iam::${data.aws_caller_identity.actual.account_id}:oidc-provider/oidc.eks.*"
    ]
  }
  statement {
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}
resource "aws_iam_role_policy" "iam_acotado" {
  name   = "iam-acotado-${var.proyecto}"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.iam_acotado.json
}
