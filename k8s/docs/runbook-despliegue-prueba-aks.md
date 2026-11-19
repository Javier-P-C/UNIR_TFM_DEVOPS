# Runbook: despliegue de prueba en AKS

Este procedimiento despliega la aplicación (frontend, backend y migraciones) en un clúster AKS del entorno de desarrollo (`dev`), para probar las imágenes de `docker/` y los manifiestos de `k8s/` antes de que exista la capa de entorno en Terraform. Es manual y queda fuera de las mediciones. Cada paso indica cómo verificarlo y, cuando aplica, cómo deshacerlo.

Alcance:
- Incluye: red, clúster AKS, PostgreSQL Flexible Server, identidad del backend, Envoy Gateway, imágenes en el ACR, despliegue, carga del catálogo y acceso al admin.
- No incluye: capa de entorno con Terraform, entorno de producción, entorno de recuperación en AWS, dominio ni HTTPS. La aplicación se prueba por la IP pública del Gateway y solo por HTTP.
- Todo lo que crea vive en un grupo de recursos propio de la prueba y se destruye al final (paso 13).
- La capa base no se modifica: no se escriben secretos ni claves de configuración. `DB_HOST` no se guarda en App Configuration; se pasa al backend en el ConfigMap del overlay (paso 8), con un valor de la sesión que no se confirma en el repositorio.

> **Pasos temporales hasta que exista la capa de entorno.** Tres pasos crean asignaciones de rol con ámbito en recursos de la capa base, fuera de su código de Terraform. No cambian esos recursos, pero sí sus permisos:
> - Paso 3: `AcrPull` de la identidad del clúster sobre el ACR (`--attach-acr`).
> - Paso 5: `Key Vault Secrets User` sobre el Key Vault de `dev` y `App Configuration Data Reader` sobre App Configuration, para la identidad del backend.
>
> El paso 13 borra las tres y verifica que no queden asignaciones huérfanas. Cuando exista la capa de entorno, estas asignaciones las creará y borrará su código [CONFIRMAR: capa que crea la identidad del backend y sus roles, decisión pendiente].

## 0. Requisitos
- Este runbook está escrito para una terminal bash de WSL (Ubuntu) en Windows. Todos los comandos se ejecutan ahí, con herramientas instaladas dentro de Ubuntu, no con las de Windows.
- Capa base de Azure aplicada (runbook `terraform/docs/runbook-arranque-capa-base.md`, paso 6) y acceso a su estado para leer las salidas.
- Un usuario con permisos para crear recursos en la suscripción y asignar roles (Owner, o Contributor más User Access Administrator).
- Instalados en WSL:
  - Azure CLI (`az`) y `az login` hecho sobre la suscripción del proyecto.
    - Problema conocido: desde WSL, `az login` no puede abrir el navegador. La alternativa `az login --use-device-code` la bloquean los Security Defaults del tenant.
    - Solución: usar el navegador de Windows mediante `wslview` (paquete `wslu`). La autenticación la sigue haciendo el Azure CLI de WSL, y los tokens quedan en `~/.azure` de Linux.
      ```bash
      sudo apt update && sudo apt install -y wslu
      which wslview                      # /usr/bin/wslview
      export BROWSER=/usr/bin/wslview
      az login --tenant <id-tenant>
      az account set --subscription <id-suscripcion>
      # Hacerlo permanente cuando funcione:
      echo 'export BROWSER=/usr/bin/wslview' >> ~/.bashrc
      ```
  - `kubectl`: `sudo az aks install-cli`, o el paquete oficial de Kubernetes.
  - `helm` (versión 3 o superior): script oficial de instalación de Helm.
  - `docker` con BuildKit (Docker 23 o superior).
  - `jq` y `terraform`.
- Imágenes probadas en local (`docker build` de `docker/backend` y `docker/frontend`).
- Registrar en la hoja de registro: fecha, id de ejecución, versiones usadas, tiempo y errores de cada paso.

Verificación: `az account show -o table` muestra la suscripción del proyecto; `kubectl version --client`, `helm version`, `docker version` y `jq --version` responden.

Verificación: `which az kubectl helm terraform` devuelve rutas de Linux (`/usr/bin/...`, `/usr/local/bin/...`), ninguna bajo `/mnt/c/`.
- Por qué: si alguna apunta a `/mnt/c/`, WSL está usando el binario de Windows, que termina cada línea con `\r\n`. `$(...)` quita el `\n` pero deja el `\r`, así que las variables de los pasos 1 a 5 acaban con un retorno de carro.
- Síntoma: el comando siguiente falla con un id o nombre "no válido" aunque se vea bien al imprimirlo. También puede fallar la conexión a PostgreSQL por `DB_PASS`.
- Comprobar una variable: `echo -n "$SUBRED_AKS_ID" | od -c | tail -2` muestra `\r` al final.
- Comprobar todas las variables de la sesión: `for v in $(compgen -e); do case "${!v}" in *$'\r'*) echo "$v contiene \\r";; esac; done` lista las afectadas.
- Corregir:
  1. Instalar la herramienta dentro de Ubuntu. Para Azure CLI: `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`.
  2. Ejecutar `hash -r`, repetir `az login` y volver a definir las variables.

## 1. Variables
Todos los pasos usan estas variables. Se definen una vez por sesión de terminal, desde la raíz del repositorio. Los recursos llevan las etiquetas de `terraform/docs/convencion-etiquetas.md` con `entorno=desarrollo`.

```bash
# Sesión
export PROYECTO=tfm-unir
export UBICACION=eastus2
export EJECUCION=DD-MM-AAAA-a          # id de la sesión, por ejemplo 16-11-2026-a
export ETIQUETAS="proyecto=$PROYECTO entorno=desarrollo ejecucion=$EJECUCION"

# Recursos de la prueba (se destruyen en el paso 13)
export RG_PRUEBA=rg-$PROYECTO-dev-prueba
export VNET=vnet-$PROYECTO-dev
export SUBRED_AKS=snet-aks
export SUBRED_DB=snet-postgres
export AKS=aks-$PROYECTO-dev
export PG=psql-$PROYECTO-dev-<sufijo>  # nombre único en todo Azure: añadir un sufijo propio
export IDENTIDAD=id-$PROYECTO-dev-backend

# Salidas de la capa base
export TF_BASE=terraform/base/azure
export ACR_NOMBRE=$(terraform -chdir=$TF_BASE output -raw acr_nombre)
export ACR_SERVIDOR=$(terraform -chdir=$TF_BASE output -raw acr_servidor)
export KV_DEV_NOMBRE=$(terraform -chdir=$TF_BASE output -json key_vault | jq -r .dev.nombre)
export KV_DEV_URI=$(terraform -chdir=$TF_BASE output -json key_vault | jq -r .dev.uri)
export APPCS_NOMBRE=$(terraform -chdir=$TF_BASE output -json app_configuration | jq -r .nombre)
export APPCS_ENDPOINT=$(terraform -chdir=$TF_BASE output -json app_configuration | jq -r .endpoint)
```

Verificación: `env | grep -E "^(RG_|VNET|SUBRED|AKS|PG|IDENTIDAD|ACR_|KV_|APPCS_)"` muestra todos los valores sin vacíos.

## 2. Red
Una VNet para el entorno de desarrollo, con el direccionamiento del diagrama de red: `10.10.0.0/16`, una subred para los nodos del clúster y otra delegada a PostgreSQL. La base queda sin acceso público y solo se alcanza desde dentro de la VNet.

| Subred | Rango | Uso |
|---|---|---|
| `snet-aks` | `10.10.0.0/22` | Nodos de AKS. Los pods usan una red superpuesta propia (paso 3), no consumen IP de la subred |
| `snet-postgres` | `10.10.4.0/24` | PostgreSQL Flexible Server, delegada a `Microsoft.DBforPostgreSQL/flexibleServers` |

1. Crear el grupo de recursos de la prueba:
   ```bash
   az group create -n $RG_PRUEBA -l $UBICACION --tags $ETIQUETAS
   ```
2. Crear la VNet con la subred del clúster:
   ```bash
   az network vnet create -g $RG_PRUEBA -n $VNET -l $UBICACION \
     --address-prefixes 10.10.0.0/16 \
     --subnet-name $SUBRED_AKS --subnet-prefixes 10.10.0.0/22 \
     --tags $ETIQUETAS
   ```
3. Crear la subred delegada de la base:
   ```bash
   az network vnet subnet create -g $RG_PRUEBA --vnet-name $VNET -n $SUBRED_DB \
     --address-prefixes 10.10.4.0/24 \
     --delegations Microsoft.DBforPostgreSQL/flexibleServers
   ```
4. Verificación: `az network vnet subnet list -g $RG_PRUEBA --vnet-name $VNET --query "[].{nombre:name, rango:addressPrefix, delegacion:delegations[0].serviceName}" -o table` muestra las dos subredes con sus rangos y la delegación en `snet-postgres`.
5. Deshacer: se elimina con todo el grupo en el paso 13. Si hay que repetir solo este paso: `az network vnet delete -g $RG_PRUEBA -n $VNET`.

## 3. Clúster AKS
Clúster pequeño en la subred `snet-aks`, con:
- Azure CNI en modo superpuesto (overlay): los nodos toman IP de la subred y los pods de un rango propio que no consume direcciones de la VNet.
- OIDC issuer y Workload Identity: los pods del backend obtienen un token de Azure sin credenciales guardadas en el clúster (paso 5).
- Permiso `AcrPull` sobre el ACR de la capa base (`--attach-acr`), para descargar las imágenes sin secretos de registro. Es una asignación temporal sobre la capa base (ver Alcance); el paso 13 la quita con `--detach-acr` antes de borrar el clúster.

Los rangos internos de Kubernetes no se solapan con la VNet (`10.10.0.0/16`) ni con la red de recuperación de AWS (`10.20.0.0/16`).

1. Verificar que hay cuota de vCPU para la familia del tamaño de nodo en la región. Hacen falta al menos 4 vCPU libres (2 nodos × 2).
   ```bash
   # Verificación: Limit menos CurrentValue >= 4 en ambas filas
   az vm list-usage -l $UBICACION -o table | grep -iE "Total Regional vCPUs|Dalv6 Family"
   ```
2. Obtener los identificadores de la subred y del ACR:
   ```bash
   export SUBRED_AKS_ID=$(az network vnet subnet show -g $RG_PRUEBA --vnet-name $VNET -n $SUBRED_AKS --query id -o tsv)
   export ACR_ID=$(az acr show -n $ACR_NOMBRE --query id -o tsv)
   ```
3. Crear el clúster (tarda entre 5 y 10 minutos):
   ```bash
   az aks create -g $RG_PRUEBA -n $AKS -l $UBICACION \
     --tier free \
     --node-count 2 --node-vm-size Standard_D2als_v6 \
     --network-plugin azure --network-plugin-mode overlay \
     --vnet-subnet-id $SUBRED_AKS_ID \
     --pod-cidr 10.244.0.0/16 --service-cidr 10.0.0.0/16 --dns-service-ip 10.0.0.10 \
     --enable-oidc-issuer --enable-workload-identity \
     --attach-acr $ACR_ID \
     --no-ssh-key \
     --tags $ETIQUETAS
   ```
   AKS solo acepta algunos tamaños por suscripción y región. Si `az aks create` rechaza el tamaño, el error lista los permitidos: elegir uno de 2 vCPU y al menos 4 GiB cuya familia tenga cuota, y anotarlo.
4. Configurar `kubectl`:
   ```bash
   az aks get-credentials -g $RG_PRUEBA -n $AKS --overwrite-existing
   ```
5. Verificación:
   - `kubectl get nodes -o wide` muestra 2 nodos `Ready` con IP de `10.10.0.0/22`.
   - `az aks show -g $RG_PRUEBA -n $AKS --query "{oidc:oidcIssuerProfile.enabled, workloadIdentity:securityProfile.workloadIdentity.enabled}" -o table` muestra `True` en ambas.
   - La identidad del kubelet tiene `AcrPull` sobre el ACR. `--attach-acr` puede fallar con solo un aviso y el clúster se crea igual; sin este rol los pods quedan en `ImagePullBackOff` con `401 Unauthorized`. El comando debe devolver el id del ACR; si no devuelve nada, ejecutar `az aks update -g $RG_PRUEBA -n $AKS --attach-acr $ACR_ID`:
     ```bash
     export KUBELET_ID=$(az aks show -g $RG_PRUEBA -n $AKS --query identityProfile.kubeletidentity.objectId -o tsv)
     az role assignment list --assignee $KUBELET_ID --all --query "[?roleDefinitionName=='AcrPull'].scope" -o tsv
     ```
   - `az aks check-acr -g $RG_PRUEBA -n $AKS --acr $ACR_SERVIDOR` termina sin errores. Justo después de crear el clúster puede fallar con `503` hasta que los pods `konnectivity-agent` de `kube-system` estén `Running`.
6. Si `--attach-acr` falla por permisos, el usuario necesita Owner o User Access Administrator sobre el ACR (asigna un rol).
7. Deshacer: primero quitar el `AcrPull` sobre el ACR, porque es una asignación en la capa base que no se borra con el clúster y quedaría huérfana: `az aks update -g $RG_PRUEBA -n $AKS --detach-acr $ACR_ID`. Después, `az aks delete -g $RG_PRUEBA -n $AKS --yes` (o con todo el grupo en el paso 13).

## 4. PostgreSQL Flexible Server
Servidor con acceso privado en `snet-postgres`, sin acceso público. Su nombre se resuelve con una zona DNS privada enlazada a la VNet, de modo que los pods lo alcanzan por `<servidor>.postgres.database.azure.com`. Como no es accesible desde fuera de la VNet, las operaciones con `psql` se hacen desde un pod temporal dentro del clúster.

Usuarios:
- `pgadmin`: administrador del servidor, solo para esta preparación. Su contraseña se genera aquí y no se guarda en el repositorio.
- `tfm_app`: el usuario de la aplicación (`DB_USER` en App Configuration). Su contraseña es el secreto `DB-PASSWORD` del Key Vault de `dev`, el mismo que lee el backend.

1. Obtener la subred y generar la contraseña del administrador:
   ```bash
   export SUBRED_DB_ID=$(az network vnet subnet show -g $RG_PRUEBA --vnet-name $VNET -n $SUBRED_DB --query id -o tsv)
   export PG_ADMIN_PASS=$(openssl rand -base64 24)
   ```
2. Crear la zona DNS privada y enlazarla a la VNet. Se crea antes que el servidor y se le pasa por id: al pasarla por nombre, Azure la rechaza con `PrivateDnsZoneNameNotValid`.
   ```bash
   export ZONA_PG=tfm-prueba.private.postgres.database.azure.com
   export VNET_ID=$(az network vnet show -g $RG_PRUEBA -n $VNET --query id -o tsv)
   az network private-dns zone create -g $RG_PRUEBA -n $ZONA_PG --tags $ETIQUETAS
   az network private-dns link vnet create -g $RG_PRUEBA -z $ZONA_PG -n enlace-$VNET \
     --virtual-network $VNET_ID --registration-enabled false
   export ZONA_PG_ID=$(az network private-dns zone show -g $RG_PRUEBA -n $ZONA_PG --query id -o tsv)
   ```
3. Crear el servidor (tarda entre 5 y 15 minutos):
   ```bash
   az postgres flexible-server create -g $RG_PRUEBA -n $PG -l $UBICACION \
     --version 18 \
     --tier Burstable --sku-name Standard_B2s --storage-size 32 \
     --subnet $SUBRED_DB_ID \
     --private-dns-zone $ZONA_PG_ID \
     --admin-user pgadmin --admin-password "$PG_ADMIN_PASS" \
     --backup-retention 7 \
     --tags $ETIQUETAS --yes
   export PG_HOST=$PG.postgres.database.azure.com
   ```
   Si falla con `SkuNotAvailable`, la suscripción no puede usar ese SKU en la región aunque aparezca en `az postgres flexible-server list-skus`. Probar otro Burstable (en esta prueba `Standard_B1ms` falló y `Standard_B2s` funcionó) y anotarlo.
4. Crear el usuario y la base de la aplicación desde un pod temporal. La contraseña de `tfm_app` se lee de Key Vault y se pasa a `psql` como variable, sin escribirla en el script:
   ```bash
   export DB_PASS=$(az keyvault secret show --vault-name $KV_DEV_NOMBRE -n DB-PASSWORD --query value -o tsv)

   # Rol y base. GRANT: en PostgreSQL 16+ el administrador debe pertenecer al rol para asignarlo como dueño
   printf '%s\n' \
     "CREATE ROLE tfm_app LOGIN PASSWORD :'app_pass';" \
     "GRANT tfm_app TO pgadmin;" \
     "CREATE DATABASE tfm OWNER tfm_app;" \
   | kubectl run psql-admin -n default --rm -i --restart=Never --image=postgres:18 \
       --env="PGPASSWORD=$PG_ADMIN_PASS" -- \
       psql "host=$PG_HOST user=pgadmin dbname=postgres sslmode=require" \
         -v ON_ERROR_STOP=1 -v app_pass="$DB_PASS"

   # Permiso en el esquema public. En Azure su dueño es azure_pg_admin, no el dueño de la base,
   # así que ser dueño de tfm no basta para que el Job de migraciones cree tablas
   printf '%s\n' "GRANT USAGE, CREATE ON SCHEMA public TO tfm_app;" \
   | kubectl run psql-admin -n default --rm -i --restart=Never --image=postgres:18 \
       --env="PGPASSWORD=$PG_ADMIN_PASS" -- \
       psql "host=$PG_HOST user=pgadmin dbname=tfm sslmode=require" -v ON_ERROR_STOP=1
   ```
   Cada llamada debe mostrar las respuestas de PostgreSQL (`CREATE ROLE`, `GRANT`, `CREATE DATABASE`; luego `GRANT`).
   - El SQL entra por una tubería, no con un heredoc ni con `-c`: un heredoc se descoloca al pegarlo en la terminal, y `psql` no sustituye `:'app_pass'` dentro de `-c`.
   - El pod se crea en `default` porque el namespace `gymscreen` exige pods sin root y la imagen `postgres` no lo cumple. Se borra al terminar (`--rm`).
   - Si `kubectl run` responde `AlreadyExists`, quedó un pod de un intento anterior: borrarlo con `kubectl delete pod psql-admin -n default` y repetir.
5. `DB_HOST` no se escribe en App Configuration: esa clave la escribirá la capa de entorno, y esta prueba no modifica la capa base. Se pasa al backend como sustitución en el ConfigMap del overlay (paso 8.1), con el valor de `$PG_HOST`.
6. Verificación:
   - `az postgres flexible-server show -g $RG_PRUEBA -n $PG --query "{estado:state, version:version, fqdn:fullyQualifiedDomainName, accesoPublico:network.publicNetworkAccess}" -o table` muestra `Ready`, versión 18 y acceso público `Disabled`.
   - Conexión con el usuario de la aplicación:
     ```bash
     kubectl run psql-check -n default --restart=Never --image=postgres:18 \
       --env="PGPASSWORD=$DB_PASS" -- \
       psql "host=$PG_HOST user=tfm_app dbname=tfm sslmode=require" -c "select current_user, current_database();"
     kubectl wait pod/psql-check -n default --for=jsonpath='{.status.phase}'=Succeeded --timeout=2m
     kubectl logs psql-check -n default
     kubectl delete pod psql-check -n default
     ```
     `logs` muestra `tfm_app | tfm`. Sin `--rm -i` porque, si el pod termina antes de que `kubectl` se conecte, la salida se pierde. Borrar el pod aunque falle el `wait`: lleva la contraseña en su definición.
7. Deshacer: `az postgres flexible-server delete -g $RG_PRUEBA -n $PG --yes`.

## 5. Identidad del backend
Identidad administrada que usan los pods del backend y el Job de migraciones (ServiceAccount `backend` del namespace `gymscreen`) para leer Key Vault y App Configuration. La credencial federada permite que el token del ServiceAccount, emitido por el OIDC issuer del clúster, se canjee por un token de Azure de esta identidad.

1. Crear la identidad y leer sus identificadores:
   ```bash
   az identity create -g $RG_PRUEBA -n $IDENTIDAD -l $UBICACION --tags $ETIQUETAS
   export IDENTIDAD_CLIENT_ID=$(az identity show -g $RG_PRUEBA -n $IDENTIDAD --query clientId -o tsv)
   export IDENTIDAD_PRINCIPAL_ID=$(az identity show -g $RG_PRUEBA -n $IDENTIDAD --query principalId -o tsv)
   export AKS_OIDC_ISSUER=$(az aks show -g $RG_PRUEBA -n $AKS --query oidcIssuerProfile.issuerUrl -o tsv)
   ```
2. Crear la credencial federada para el ServiceAccount `gymscreen/backend`:
   ```bash
   az identity federated-credential create -g $RG_PRUEBA --identity-name $IDENTIDAD -n backend \
     --issuer $AKS_OIDC_ISSUER \
     --subject system:serviceaccount:gymscreen:backend \
     --audiences api://AzureADTokenExchange
   ```
3. Asignar los roles de lectura sobre los almacenes de la capa base. Son asignaciones temporales sobre la capa base (ver Alcance); el paso 13 las borra:
   ```bash
   export KV_DEV_ID=$(az keyvault show -n $KV_DEV_NOMBRE --query id -o tsv)
   export APPCS_ID=$(az appconfig show -n $APPCS_NOMBRE --query id -o tsv)

   az role assignment create --assignee-object-id $IDENTIDAD_PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
     --role "Key Vault Secrets User" --scope $KV_DEV_ID
   az role assignment create --assignee-object-id $IDENTIDAD_PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
     --role "App Configuration Data Reader" --scope $APPCS_ID
   ```
   Los roles tardan unos minutos en propagarse. Si el backend arranca antes, falla con 403 y Kubernetes lo reinicia hasta que el permiso está activo.
4. Anotar `IDENTIDAD_CLIENT_ID`: es el `<client-id>` del overlay (paso 8).
5. Verificación:
   - `az identity federated-credential list -g $RG_PRUEBA --identity-name $IDENTIDAD --query "[].{nombre:name, subject:subject}" -o table` muestra `system:serviceaccount:gymscreen:backend`.
   - `az role assignment list --assignee $IDENTIDAD_PRINCIPAL_ID --all --query "[].{rol:roleDefinitionName, ambito:scope}" -o table` muestra los dos roles.
6. Deshacer: borrar primero las asignaciones de rol (están en la capa base y no se eliminan con el grupo de la prueba): `az role assignment delete --assignee $IDENTIDAD_PRINCIPAL_ID --scope $KV_DEV_ID` y lo mismo con `$APPCS_ID`; después `az identity delete -g $RG_PRUEBA -n $IDENTIDAD`.

## 6. Envoy Gateway
Controlador de Gateway API. Por cada `Gateway` crea un proxy Envoy y un Service `LoadBalancer` con IP pública en el namespace `envoy-gateway-system`. El chart instala también las definiciones (CRD) de Gateway API.

1. Instalar el controlador con una versión fijada:
   ```bash
   export ENVOY_GATEWAY_VERSION=v1.9.3
   helm install eg oci://docker.io/envoyproxy/gateway-helm --version $ENVOY_GATEWAY_VERSION \
     -n envoy-gateway-system --create-namespace
   kubectl wait --for=condition=Available deployment/envoy-gateway -n envoy-gateway-system --timeout=5m
   ```
2. Crear la `GatewayClass` (una vez por clúster; queda fuera de Kustomize porque es de ámbito de clúster):
   ```bash
   kubectl apply -f k8s/cluster/gatewayclass.yaml
   ```
3. Verificación: `kubectl get gatewayclass envoy` muestra `ACCEPTED True`.
4. Deshacer: `kubectl delete -f k8s/cluster/gatewayclass.yaml` y `helm uninstall eg -n envoy-gateway-system`.

## 7. Imágenes
Las imágenes se construyen desde la raíz del repositorio y se etiquetan con el commit del que salen, nunca con `latest`.

1. Confirmar que no hay cambios sin commit, para que la etiqueta corresponda exactamente al código de la imagen:
   ```bash
   git status --short        # debe salir vacío
   export TAG=$(git rev-parse --short HEAD)
   ```
2. Iniciar sesión en el ACR. Se usa un token en lugar de `az acr login` directo, porque en WSL `az` puede ser el de Windows y no encontrar el `docker` de Linux:
   ```bash
   az acr login -n $ACR_NOMBRE --expose-token --query accessToken -o tsv \
     | docker login $ACR_SERVIDOR -u 00000000-0000-0000-0000-000000000000 --password-stdin
   ```
3. Construir y subir. Los nodos de AKS son `linux/amd64`; si el equipo local es ARM, añadir `--platform linux/amd64` al build:
   ```bash
   docker build -f docker/backend/Dockerfile  -t $ACR_SERVIDOR/gymscreen-backend:$TAG .
   docker build -f docker/frontend/Dockerfile -t $ACR_SERVIDOR/gymscreen-frontend:$TAG .
   docker push $ACR_SERVIDOR/gymscreen-backend:$TAG
   docker push $ACR_SERVIDOR/gymscreen-frontend:$TAG
   ```
4. Verificación: `az acr repository show-tags -n $ACR_NOMBRE --repository gymscreen-backend -o table` (y lo mismo con `gymscreen-frontend`) muestra la etiqueta `$TAG`.
5. Deshacer: `az acr repository delete -n $ACR_NOMBRE --image gymscreen-backend:$TAG --yes` (y lo mismo con el frontend).

## 8. Despliegue
1. Rellenar los marcadores `<...>` del overlay con los valores de la sesión y añadir `DB_HOST` al ConfigMap como sustitución (en este entorno de prueba no existe en App Configuration, ver paso 4). Ninguno de estos valores es secreto, pero son de la sesión, así que no se confirman en el repositorio; al terminar la prueba se restaura el archivo (paso 13):
   ```bash
   sed -i \
     -e "s|<acr_servidor>|$ACR_SERVIDOR|g" \
     -e "s|<sha-del-commit>|$TAG|g" \
     -e "s|<key_vault_dev_uri>|$KV_DEV_URI|" \
     -e "s|<app_configuration_endpoint>|$APPCS_ENDPOINT|" \
     -e "s|<client-id>|$IDENTIDAD_CLIENT_ID|g" \
     -e "s|^      - ALLOWED_HOSTS=localhost$|      - DB_HOST=$PG_HOST\n      - ALLOWED_HOSTS=localhost|" \
     k8s/overlays/dev/kustomization.yaml
   ```
2. Revisar el resultado antes de aplicarlo: `kubectl kustomize k8s/overlays/dev | grep -nE "image:|DB_HOST|<"` muestra las imágenes del ACR con la etiqueta `$TAG`, `DB_HOST` con el servidor de la sesión y ningún `<` pendiente.
3. Aplicar. El Job de migraciones no admite cambios, así que se borra el anterior antes de cada despliegue (en el primero no existe y el comando no hace nada):
   ```bash
   kubectl delete job migrate -n gymscreen --ignore-not-found
   kubectl apply -k k8s/overlays/dev
   kubectl wait --for=condition=complete job/migrate -n gymscreen --timeout=10m
   kubectl rollout status deployment/backend  -n gymscreen --timeout=5m
   kubectl rollout status deployment/frontend -n gymscreen --timeout=5m
   ```
   El Job y los Deployments se aplican a la vez: en el primer despliegue la API puede responder con error durante los segundos que tarda la migración (limitación conocida, ver Pendientes).
4. Verificación:
   - `kubectl get pods -n gymscreen` muestra 2 pods `backend` y 2 `frontend` en `Running` y `READY 1/1`, y el pod del Job en `Completed`.
   - `kubectl logs job/migrate -n gymscreen` muestra las migraciones aplicadas (o `No migrations to apply`).
   - `kubectl logs deployment/backend -n gymscreen` muestra el arranque de Gunicorn sin errores de configuración.
   - `kubectl get gateway gymscreen -n gymscreen` muestra `PROGRAMMED True` y una dirección IP.
5. Si falla, revisar los logs del Job o del backend:
   - `Missing configuration for ENV=dev: ...`: falta una clave. `DB_HOST` debe estar en el ConfigMap (paso 8.1); las demás, en App Configuration con la etiqueta `dev` (capa base).
   - `Key Vault ... failed` o `App Configuration ... failed` con 403: los roles del paso 5 aún no se propagaron, o la credencial federada no coincide con `gymscreen/backend`.
   - Error de conexión a PostgreSQL: revisar el paso 4 (servidor `Ready`, zona DNS privada enlazada, usuario `tfm_app`).
   - `ImagePullBackOff`: revisar `az aks check-acr` (paso 3) y que la etiqueta exista (paso 7).
   - Pods rechazados al crearse (`violates PodSecurity "restricted"`): un manifiesto no cumple la política del namespace.
6. Deshacer: `kubectl delete -k k8s/overlays/dev`.

## 9. IP del Gateway en ALLOWED_HOSTS
El primer despliegue se hace con `ALLOWED_HOSTS=localhost` porque la IP pública del Gateway no existe hasta que Envoy la crea. Mientras no se añade, el frontend carga por la IP pero la API responde 400.

1. Obtener la IP y comprobar el estado actual:
   ```bash
   export GATEWAY_IP=$(kubectl get gateway gymscreen -n gymscreen -o jsonpath='{.status.addresses[0].value}')
   curl -s -o /dev/null -w "%{http_code}\n" http://$GATEWAY_IP/                         # 200 (frontend)
   curl -s -o /dev/null -w "%{http_code}\n" http://$GATEWAY_IP/api/v1/muscle-groups/   # 400 (host no permitido)
   ```
2. Añadir la IP al overlay (en un despliegue con dominio, aquí iría el nombre de host):
   ```bash
   sed -i "s|ALLOWED_HOSTS=localhost$|ALLOWED_HOSTS=localhost,$GATEWAY_IP|" k8s/overlays/dev/kustomization.yaml
   ```
3. Volver a aplicar con la misma secuencia del paso 8.3. El ConfigMap cambia de nombre (sufijo hash), lo que reinicia el backend y también cambia la plantilla del Job; por eso hay que borrar el Job también aquí.
4. Verificación: `curl -s -o /dev/null -w "%{http_code}\n" http://$GATEWAY_IP/api/v1/muscle-groups/` devuelve 200.
5. Si la IP existe pero las peticiones no responden (tiempo de espera agotado), revisar en el portal las sondas de estado del balanceador del clúster para el Service de Envoy (`kubectl get svc -n envoy-gateway-system`) y anotar el ajuste necesario en la hoja de registro.

## 10. Catálogo inicial
El entorno `dev` nace sin datos operacionales pero con el catálogo de ejercicios, que es dato de referencia. Las migraciones crean las tablas vacías y el catálogo se carga con `db/seed_data.sql`. `prod` no usa este paso: recibe el catálogo al restaurar su respaldo.

> **Paso manual temporal.** En el diseño, la carga del catálogo en `dev` es automática al crear el entorno, para no añadir pasos manuales a las mediciones. Esta prueba queda fuera de las mediciones, así que aquí se hace a mano, una sola vez.
>
> `seed_data.sql` empieza con un `TRUNCATE` del catálogo. Es seguro aquí porque la base se creó vacía en el paso 4; no ejecutarlo sobre una base cuyo catálogo se haya editado desde el admin.

1. Requisito: el Job `migrate` del paso 8 terminó (`kubectl get job migrate -n gymscreen` muestra `COMPLETIONS 1/1`). Sin las tablas, el script falla con `relation "..." does not exist`.
2. Cargar el script desde un pod temporal, con el usuario de la aplicación (`DB_PASS` y `PG_HOST` son del paso 4):
   ```bash
   kubectl run psql-seed -n default --rm -i --restart=Never --image=postgres:18 \
     --env="PGPASSWORD=$DB_PASS" -- \
     psql "host=$PG_HOST user=tfm_app dbname=tfm sslmode=require" -v ON_ERROR_STOP=1 -f - \
     < db/seed_data.sql
   ```
   El script es una sola transacción: si algo falla, no se carga nada.
3. Verificación: `curl -s http://$GATEWAY_IP/api/v1/muscle-groups/ | jq '.[] | {name, exercise_count}'` lista los grupos musculares con su número de ejercicios.

## 11. Acceso al admin
El admin de Django no se publica en el Gateway: desde fuera, `/admin/` llega al frontend. Solo se alcanza con un túnel temporal (`kubectl port-forward`) desde un equipo con credenciales del clúster. La seguridad la dan el acceso a Azure, el RBAC de Kubernetes y el login de Django.

1. Crear el superusuario (una vez; queda guardado en PostgreSQL). Se ejecuta dentro de un pod del backend, que ya tiene la configuración y la identidad:
   ```bash
   kubectl exec -it deployment/backend -n gymscreen -- python manage.py createsuperuser
   ```
2. Abrir el túnel al Service del backend (queda en primer plano):
   ```bash
   kubectl port-forward svc/backend 8000:8000 -n gymscreen
   ```
3. Entrar en `http://localhost:8000/admin/` desde el navegador. Funciona porque `localhost` está en `ALLOWED_HOSTS` (overlay) y los estilos los sirve WhiteNoise desde la imagen.
4. Cerrar el túnel con `Ctrl+C` al terminar.
5. Verificación: el login del admin carga con estilos y permite entrar con el superusuario; con el túnel cerrado, `http://localhost:8000/admin/` no responde.

## 12. Verificación completa
1. En el navegador, `http://<GATEWAY_IP>/`:
   - La sección de Ejercicios carga los grupos musculares, la lista por grupo y el detalle con videos.
   - Recargar el navegador en una página de detalle (por ejemplo `/ejercicios/1`) vuelve a mostrarla: nginx devuelve `index.html` y React Router resuelve la ruta.
2. Comprobaciones por línea de comandos:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://$GATEWAY_IP/api/v1/exercises/   # 200
   curl -s http://$GATEWAY_IP/admin/ | grep -c "Django"                            # 0: el admin no está publicado
   ```
3. Salud y logs:
   - `kubectl get pods -n gymscreen` sin reinicios (`RESTARTS 0`).
   - `kubectl logs deployment/backend -n gymscreen` muestra las peticiones de la prueba en el log de accesos de Gunicorn.
4. Recuperación de un pod: `kubectl delete pod -n gymscreen -l app.kubernetes.io/name=backend --wait=false` y comprobar con `kubectl get pods -n gymscreen -w` que se crean pods nuevos y quedan `READY 1/1`, mientras la API sigue respondiendo.
5. Anotar en la hoja de registro el tiempo total de los pasos 2 a 12.

## 13. Destruir la prueba
1. Restaurar el overlay (los valores de la sesión no se confirman en el repositorio):
   ```bash
   git restore k8s/overlays/dev/kustomization.yaml
   ```
2. Borrar las asignaciones de rol temporales sobre la capa base (ver Alcance). No se eliminan con el grupo de recursos: si se borran después de las identidades, quedan huérfanas (principal `Unknown`). El `AcrPull` se quita con el clúster todavía en pie:
   ```bash
   az aks update -g $RG_PRUEBA -n $AKS --detach-acr $ACR_ID
   az role assignment delete --assignee $IDENTIDAD_PRINCIPAL_ID --scope $KV_DEV_ID
   az role assignment delete --assignee $IDENTIDAD_PRINCIPAL_ID --scope $APPCS_ID
   ```
3. Borrar el grupo de la prueba. Elimina la red, el clúster (y su grupo de nodos `MC_...`, con el balanceador y la IP pública del Gateway), el servidor PostgreSQL con su zona DNS privada y la identidad:
   ```bash
   az group delete -n $RG_PRUEBA --yes
   ```
4. Quitar el contexto local de `kubectl`: `kubectl config delete-context $AKS` y `kubectl config delete-cluster $AKS`.
5. Opcional: las imágenes del ACR pueden quedarse (forman parte de la capa base); para borrarlas, ver el paso 7.
6. Verificación:
   - `az group exists -n $RG_PRUEBA` devuelve `false`.
   - `scripts/inventario-recursos.sh` termina con código 0: no quedan recursos con entorno distinto de `base` ni servicios de costo activos (AKS, bases de datos, balanceadores). El script consulta Azure y AWS, así que necesita las dos sesiones iniciadas.
   - Sin asignaciones de la prueba ni huérfanas en la capa base: `az role assignment list --scope <ámbito> --query "[].{principal:principalName, tipo:principalType, rol:roleDefinitionName}" -o table` con `$ACR_ID`, `$KV_DEV_ID` y `$APPCS_ID` muestra solo las asignaciones creadas por Terraform en la capa base, sin la identidad del backend, sin el `AcrPull` del clúster y sin principales `Unknown`.
   - `git status --short` no muestra cambios en `k8s/overlays/dev/`.
7. Anotar en la hoja de registro el tiempo de destrucción y lo que haya quedado pendiente.

## Pendientes
- **Dominio y HTTPS:** `hostname` en el listener del Gateway, certificado y puerto 443. Con el host real en `host_por_entorno`, `ALLOWED_HOSTS` vuelve a venir de App Configuration y el overlay solo conserva `localhost` para el admin.
- **Capa de entorno en Terraform:** sustituye los pasos 2 a 5 y escribe `DB_HOST` en App Configuration.
- **Pipeline de CI:** construir y subir las imágenes en cada commit, rellenar el overlay en el espacio de trabajo del pipeline y esperar al Job de migraciones antes de actualizar los Deployments (hoy se aplican a la vez).
- **Carga automática del catálogo al crear `dev`** (sin pasos manuales). `prod` lo recibe al restaurar su respaldo.
- **Respaldo y restauración de PostgreSQL**, y entorno de recuperación en AWS.

## Notas de seguridad
- No se guardan secretos en el repositorio. Los valores del overlay (ACR, URL de Key Vault, endpoint de App Configuration, client-id) no son secretos: sin los permisos de la identidad no dan acceso. Aun así no se confirman, porque cambian en cada sesión.
- La contraseña de `pgadmin` solo existe en la variable de la sesión y en el servidor, que se destruye en el paso 13. Si se necesita conservarla durante la prueba, guardarla en un gestor de contraseñas, nunca en el repositorio ni en la hoja de registro.
- `DB_PASS` se pasa como variable de entorno a los pods temporales de `psql` en `default`. Es visible para quien administre el clúster mientras el pod existe; los pods se borran al terminar (`--rm`).
- **Alcance de la identidad en App Configuration:** el almacén es único para `dev` y `prod`, y el rol `App Configuration Data Reader` permite leer todas las etiquetas. La identidad de `dev` puede leer las claves de `prod`, que son valores no sensibles (los secretos están en Key Vaults separados por entorno). Es una limitación aceptada del diseño de la capa base.
- El namespace `gymscreen` aplica la política Pod Security `restricted`: los pods de la aplicación corren sin root, con el sistema de archivos en solo lectura y sin capabilities. Los pods temporales de `psql` usan `default` porque la imagen `postgres` no cumple la política.
- El admin solo se alcanza por `kubectl port-forward`; no hay ruta pública hacia él.
