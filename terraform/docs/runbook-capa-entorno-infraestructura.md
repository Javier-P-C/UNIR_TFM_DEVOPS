# Runbook: capa de entorno, infraestructura (Azure)

Este procedimiento crea y destruye con Terraform la infraestructura de un entorno en Azure: red, clúster AKS, PostgreSQL Flexible Server con la base de la aplicación preparada, e identidad del backend. Termina con un clúster vacío y una base lista, sin nada desplegado. Los ejemplos usan el entorno `prod`.

La descripción del código (módulos, excepción del proveedor de Kubernetes, controles de seguridad, notas de seguridad) está en `terraform/README.md`, sección «Capa de entorno: infraestructura». El estado final es el mismo que dejan los pasos 2 a 5 de `k8s/docs/runbook-linea-base-produccion.md`, más el NSG de la subred de la base.

## 0. Requisitos
- Capa base de Azure aplicada, con `prod` en `host_por_entorno` (`terraform/docs/runbook-arranque-capa-base.md`, paso 6).
- Terminal bash de WSL con `az`, `terraform` 1.17, `kubectl` y `jq` instalados dentro de Ubuntu, y `az login` hecho sobre la suscripción del proyecto. Los problemas conocidos de WSL están en el paso 0 de `k8s/docs/runbook-linea-base-produccion.md`.
- Permisos de quien aplica:
  - crear recursos en la suscripción (Contributor);
  - crear y borrar asignaciones de `AcrPull`, `Network Contributor`, `Key Vault Secrets User` y `App Configuration Data Reader` (RBAC Administrator). La identidad de GitHub lo tiene restringido a esos roles por una condición en `terraform/base/azure/main.tf`;
  - leer el estado de la capa base (`Storage Blob Data Contributor` en la cuenta del estado);
  - leer `DB-PASSWORD` del Key Vault del entorno, y leer y escribir claves en App Configuration. La capa base da estos permisos a quien la aplica y a la identidad de GitHub.

## 1. Variables y backend
Desde `terraform/entorno/azure/infraestructura/prod`:

1. Copiar la configuración del backend y rellenar `storage_account_name` con la cuenta del estado (la misma que en `terraform/base/azure/backend.hcl`):
   ```bash
   cp backend.hcl.example backend.hcl
   ```
2. Definir los valores de la sesión y de la cuenta. El resto de valores del entorno están en `prod.tfvars`:
   ```bash
   export TF_VAR_suscripcion_id=$(terraform -chdir=../../../../base/azure output -raw suscripcion_id)
   export TF_VAR_cuenta_estado=$(sed -n 's/^storage_account_name *= *"\(.*\)"/\1/p' backend.hcl)
   export TF_VAR_ejecucion=DD-MM-AAAA-a               # id de la sesión, por ejemplo 24-11-2026-a
   ```
3. Verificación: `env | grep TF_VAR_` muestra los tres valores, sin vacíos.

## 2. Inicializar
1. Inicializar con el estado remoto del entorno (clave `entorno-prod-infraestructura.tfstate`):
   ```bash
   terraform init -backend-config=backend.hcl
   ```
2. Verificación: termina con `Terraform has been successfully initialized!` y usa las versiones de `.terraform.lock.hcl`.

## 3. Plan
1. Generar el plan:
   ```bash
   terraform plan -var-file=prod.tfvars -out=plan.tfplan
   ```
2. Verificación: `Plan: 21 to add, 0 to change, 0 to destroy`. Son:
   - red: grupo de recursos, VNet, dos subredes, NSG y su asociación;
   - clúster: AKS y dos asignaciones de rol (`AcrPull` sobre el ACR, `Network Contributor` sobre la subred);
   - base de datos: sufijo del nombre, contraseña del administrador, zona DNS privada, enlace a la VNet, servidor PostgreSQL y clave `DB_HOST`;
   - identidad: identidad del backend, credencial federada y dos asignaciones de rol (Key Vault y App Configuration);
   - preparación de la base: Secret y Job de Kubernetes.

   Ningún recurso de la capa base aparece como modificado o destruido.

## 4. Aplicar
1. Aplicar el plan:
   ```bash
   terraform apply plan.tfplan
   ```
   El clúster y el servidor PostgreSQL se crean en paralelo. El Job de preparación de la base empieza cuando existen los dos, y el apply espera a que termine.
2. Si falla:
   - **Job que no termina** (`timeout while waiting for resource to be complete`): ver sus registros con el paso 5.3 y revisar:
     - `could not translate host name`: el enlace de la zona DNS privada no está activo;
     - `timeout` o `connection refused` en el 5432: la regla del NSG no admite el origen del pod;
     - `password authentication failed`: la contraseña de `pgadmin` no llegó al servidor.
     Corregida la causa, borrar el Job a mano (`kubectl delete job arranque-base-datos -n default`) y repetir `terraform apply -var-file=prod.tfvars`.
   - **403 al crear una asignación de rol**: el rol no está en la condición de la capa base. Añadirlo allí y aplicar la capa base antes de repetir.
   - **Tamaño o SKU no disponible** (`SkuNotAvailable`, tamaño de nodo rechazado): la suscripción no puede usarlo en la región. Igual que en el runbook de la línea base, elegir otro y anotarlo; cambiar `prod.tfvars` es un cambio de artefacto.

## 5. Verificación
1. Plan limpio:
   ```bash
   terraform plan -var-file=prod.tfvars -detailed-exitcode
   ```
   Termina con código `0` (sin cambios).
2. Variables para las verificaciones:
   ```bash
   export RG=$(terraform output -raw grupo_recursos)
   export AKS=$(terraform output -raw cluster_nombre)
   export PG_HOST=$(terraform output -raw postgresql_fqdn)
   export PG=${PG_HOST%%.*}
   export IDENTIDAD=id-tfm-unir-prod-backend
   export APPCS_NOMBRE=$(terraform -chdir=../../../../base/azure output -json app_configuration | jq -r .nombre)
   az aks get-credentials -g $RG -n $AKS --overwrite-existing
   ```
3. Base de datos preparada: `kubectl logs job/arranque-base-datos -n default` muestra `CREATE ROLE`, `GRANT ROLE`, `CREATE DATABASE` y `GRANT`.
4. `DB_HOST`: `az appconfig kv show -n $APPCS_NOMBRE --key DB_HOST --label prod --auth-mode login --query value -o tsv` devuelve `$PG_HOST`.
5. Nodos: `kubectl get nodes -o wide` muestra 2 nodos `Ready` con IP de `10.20.0.0/22`.
6. Controles de seguridad:
   - Base de datos sin acceso público: `az postgres flexible-server show -g $RG -n $PG --query network.publicNetworkAccess -o tsv` devuelve `Disabled`.
   - Solo el 5432 desde la subred del clúster: `az network nsg rule list -g $RG --nsg-name nsg-snet-postgres -o table` muestra la regla que permite TCP 5432 desde `10.20.0.0/22` y la que deniega el resto del tráfico de la VNet.
   - Zona DNS privada: `az network private-dns link vnet list -g $RG -z tfm-prod.private.postgres.database.azure.com -o table` muestra el enlace a la VNet.
   - Workload Identity sin credenciales estáticas: `az identity federated-credential list -g $RG --identity-name $IDENTIDAD --query "[].subject" -o tsv` devuelve `system:serviceaccount:gymscreen:backend`.
   - OIDC issuer habilitado: `az aks show -g $RG -n $AKS --query "[oidcIssuerProfile.enabled, securityProfile.workloadIdentity.enabled]" -o tsv` devuelve `true` dos veces.
   - Clúster sin claves SSH: `az aks show -g $RG -n $AKS --query linuxProfile` no devuelve nada.
7. Inventario: `scripts/inventario-recursos.sh`.
   - La parte 1 cuenta 13 recursos con entorno `produccion`, y la parte 2 los lista, todos con la `ejecucion` de la sesión:
     - 7 de esta configuración: el grupo de recursos, la VNet, el NSG de la subred de la base, el clúster, la zona DNS privada, el servidor PostgreSQL y la identidad del backend;
     - 5 que crea AKS con las etiquetas del clúster: el grupo de nodos `MC_...` y, dentro, la identidad del kubelet (`aks-...-agentpool`), el balanceador `kubernetes`, su IP pública de salida y el NSG `aks-agentpool-...`;
     - 1 que crea AKS con las etiquetas del grupo de nodos: el conjunto de escalado `aks-nodepool1-...-vmss`.

     Las subredes, el enlace DNS, la credencial federada y las asignaciones de rol no aparecen porque no son recursos etiquetables o no llevan etiquetas.
   - La parte 3 lista los servicios de costo: el clúster, el servidor PostgreSQL, el balanceador, la IP pública, la VNet y el conjunto de escalado de los nodos (`aks-nodepool1-...-vmss`).
   - Con el entorno en pie, el script termina con código `1`. Es lo esperado.

## 6. Destrucción
**Primero la configuración de aplicación, después esta.** Si la de aplicación está aplicada, destruirla antes con su runbook [COMPLETAR: ruta del runbook de la configuración de aplicación cuando exista]; si no existe, empezar en el punto 1. El orden importa por lo que queda fuera de Azure y por el estado de aplicación, no por el balanceador:
- **Registro DNS**: el registro de Route 53 apunta a la IP del Gateway. Lo borra la configuración de aplicación; si el clúster desaparece antes, queda apuntando a una IP que ya no existe.
- **Respaldo**: el respaldo de producción a S3 se hace con el servidor en pie, antes de destruir.
- **Estado de aplicación**: sus recursos viven dentro del clúster. Sin el clúster, su `destroy` no puede conectarse y hay que sacarlos del estado a mano.

El balanceador y la IP pública del Gateway no necesitan un paso propio: están en el grupo de nodos `MC_...`, y AKS lo borra con el clúster en el punto 1. La verificación del punto 3 comprueba que no queden.

1. Con las variables del paso 1 definidas (`TF_VAR_ejecucion` tiene que existir, aunque su valor no se use al destruir):
   ```bash
   terraform destroy -var-file=prod.tfvars
   ```
   Las asignaciones de rol se borran antes que las identidades, así que no quedan principales huérfanos en la capa base.
2. Limpieza local:
   ```bash
   kubectl config delete-context $AKS
   kubectl config delete-cluster $AKS
   rm -f plan.tfplan
   ```
3. Verificación:
   - `az group exists -n $RG` devuelve `false`.
   - `scripts/inventario-recursos.sh` termina con código `0`.
   - `az appconfig kv list -n $APPCS_NOMBRE --key DB_HOST --label prod --auth-mode login -o tsv` no devuelve nada.
   - `terraform state list` no devuelve nada.
