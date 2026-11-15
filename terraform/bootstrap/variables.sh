#!/usr/bin/env bash
# Valores compartidos por los scripts de arranque. Ajustar antes de ejecutar.
# Los nombres de la cuenta de almacenamiento y del bucket son únicos a nivel global.
export PROYECTO="tfm-unir"
export GITHUB_REPO="Javier-P-C/UNIR_TFM_DEVOPS"            # formato propietario/repositorio

# Azure
export AZ_LOCATION="eastus2"
export AZ_RG_ESTADO="rg-${PROYECTO}-estado"
export AZ_STORAGE="sttfmestado$RANDOM"     # 3-24 caracteres, minúsculas y números; anotar el valor final
export AZ_CONTAINER="tfstate"

# AWS
export AWS_REGION="us-east-1"
export AWS_BUCKET_ESTADO="${PROYECTO}-estado-jpc"  # único global, se tendrá que cambiar sufijo; anotar el valor final

# Etiquetas comunes
export TAG_PROYECTO="${PROYECTO}"
export TAG_ENTORNO="base"
