#!/usr/bin/env bash
# Arranque manual en AWS: bucket S3 para el estado remoto.
# Requisito: sesión de AWS con permisos de administrador (aws sso login o credenciales temporales).
set -euo pipefail
source "$(dirname "$0")/variables.sh"

if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$AWS_BUCKET_ESTADO" --region "$AWS_REGION"
else
  aws s3api create-bucket --bucket "$AWS_BUCKET_ESTADO" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

aws s3api put-public-access-block --bucket "$AWS_BUCKET_ESTADO" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$AWS_BUCKET_ESTADO" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$AWS_BUCKET_ESTADO" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-tagging --bucket "$AWS_BUCKET_ESTADO" \
  --tagging "TagSet=[{Key=proyecto,Value=$TAG_PROYECTO},{Key=entorno,Value=$TAG_ENTORNO},{Key=ejecucion,Value=arranque}]"

echo "Estado remoto de AWS listo: bucket=$AWS_BUCKET_ESTADO región=$AWS_REGION"
