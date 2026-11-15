#!/usr/bin/env bash
# Arranque manual en Azure: grupo de recursos y almacenamiento del estado remoto.
# Requisito: az login con un usuario Owner de la suscripción y az account set --subscription <id>.
set -euo pipefail
source "$(dirname "$0")/variables.sh"

az group create -n "$AZ_RG_ESTADO" -l "$AZ_LOCATION" \
  --tags proyecto="$TAG_PROYECTO" entorno="$TAG_ENTORNO" ejecucion="arranque"

az storage account create -n "$AZ_STORAGE" -g "$AZ_RG_ESTADO" -l "$AZ_LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --tags proyecto="$TAG_PROYECTO" entorno="$TAG_ENTORNO" ejecucion="arranque"

az storage account blob-service-properties update --account-name "$AZ_STORAGE" -g "$AZ_RG_ESTADO" \
  --enable-versioning true

# El contenedor se crea con autenticación de Azure AD, sin claves de la cuenta.
# Si falla por permisos, asignar al usuario el rol "Storage Blob Data Contributor" sobre la cuenta.
az storage container create --name "$AZ_CONTAINER" --account-name "$AZ_STORAGE" --auth-mode login

echo "Estado remoto de Azure listo: cuenta=$AZ_STORAGE contenedor=$AZ_CONTAINER grupo=$AZ_RG_ESTADO"
