# Runbook: línea base manual del entorno de producción en Azure

Este procedimiento aprovisiona a mano el entorno de producción (`prod`) en Azure: red, clúster AKS, PostgreSQL Flexible Server, identidad del backend, Envoy Gateway, cert-manager, datos, despliegue, registro DNS y certificado HTTPS. Destruirlo se cronometra aparte.

No es una prueba. Es el instrumento con el que se mide la línea base manual, que después se compara con el ciclo `destroy`/`apply` de la automatización. Por eso:
- **Hace lo mismo que hará la automatización, con los mismos artefactos del repositorio**: overlay `k8s/overlays/prod`, emisores de `k8s/cluster/`, versiones fijadas y claves de App Configuration.
- **Queda congelado antes de la primera medición.** Si cambia entre repeticiones, los tiempos dejan de ser comparables (ver «Congelación»).
- **Se ejecuta tres veces** el ciclo de recreación (recorrido B).

## Recorridos
Hay dos recorridos. Cada paso indica a cuál pertenece.

| Recorrido | Cuándo | Qué hace | Se cronometra |
|---|---|---|---|
| **A. Creación inicial** | Una sola vez, antes de las mediciones | Crea el entorno con la base vacía, carga el catálogo, crea el superusuario y deja el **respaldo de referencia** en S3. Usa el emisor de pruebas de Let's Encrypt. Termina destruyendo el entorno (paso 16) | No forma parte de la línea base. Se anotan los tiempos como referencia |
| **B. Ciclo de recreación** | Tres veces | Crea el entorno y **restaura el respaldo de referencia** desde S3. Usa el emisor de producción | Sí: pasos 1 a 13. La destrucción (paso 16), aparte |

| Paso | A | B |
|---|---|---|
| 0 a 8 | Sí | Sí |
| 9A. Base vacía y catálogo | Sí | No |
| 9B. Restauración desde S3 | No | Sí |
| 10 a 13 | Sí | Sí |
| 14. Superusuario y respaldo de referencia | Sí | No |
| 15. Acceso al admin | Opcional, fuera de la medición | Opcional, fuera de la medición |
| 16. Destrucción | Sí | Sí, cronometrada aparte |

## Medición

### Frontera
- **Inicio:** la marca «1 inicio», antes de leer el paso 1. En ese momento la capa base existe y hay sesión iniciada en Azure y en AWS (paso 0, fuera de la medición).
- **Fin:** el criterio de respuesta del paso 13 se cumple.
- **Destrucción:** de la marca «16 inicio», antes de leer el paso 16, a la marca «16 fin». Es una medición separada.

### Criterio de respuesta
`GET https://<host>/api/v1/muscle-groups/` devuelve `200`, con un certificado de confianza, y los `exercise_count` de cada grupo muscular coinciden con los del respaldo. La referencia es `conteos.json`, que el recorrido A guarda en S3 junto al respaldo.

### Marcas de tiempo
Cada paso empieza con `marca "<paso> inicio"` y termina con `marca "<paso> fin"`. La marca de inicio es lo primero del paso, antes de su descripción: leer el paso es parte del trabajo manual, sobre todo para quien no lo ha ejecutado antes o lo retoma tiempo después. La función `marca` (paso 0.6) escribe la hora UTC en el archivo de registro de la ejecución. Las llamadas a `marca` no cuentan como pasos manuales.

### Esperas externas
La propagación DNS (paso 11) y la emisión del certificado (paso 12) dependen de servicios externos (Route 53, los resolutores DNS y Let's Encrypt). Son las dos fuentes de variabilidad externa del ciclo. Cada una lleva sus propias marcas (`espera-dns`, `espera-certificado`), y en la hoja de registro se anotan aparte, además de estar incluidas en el tiempo total.

### Paso manual
Cuenta como paso manual:
- cada comando tecleado o pegado y ejecutado, incluidos los de verificación. Un comando partido en varias líneas con `\`, o una tubería, cuenta como uno;
- cada valor copiado de un paso a otro, o leído en pantalla y escrito a mano, como `TAG`, `RESPALDO_VERSION` o un id;
- cada interacción con el portal de Azure o la consola de AWS: abrir una página, hacer clic o rellenar un campo.

### Error
Es un error un comando que falla, o una verificación que no pasa, y que obliga a una acción no prevista en el runbook. Se anotan el paso, el mensaje y la acción tomada. Un fallo que el propio runbook prevé y resuelve con su instrucción (por ejemplo, repetir tras `AlreadyExists`) también se anota como error, porque obligó a hacer algo que el camino normal no incluye.

### Mismo respaldo en las tres repeticiones
El recorrido B restaura siempre el mismo objeto de S3, fijado por su `VersionId` (el bucket tiene versionado). Así el tiempo de restauración es comparable entre repeticiones.

La versión actual de cada objeto del bucket no expira. Las versiones reemplazadas sí: se borran a los `dias_retencion_respaldos` días (capa base de AWS). Por eso **solo el recorrido A escribe en `prod/linea-base/`**. Si otra subida sobrescribe esas claves, la versión de referencia pasa a ser anterior y desaparece pasado ese plazo. Repetir el recorrido A genera un respaldo nuevo e inicia una serie nueva.

### Límite de Let's Encrypt
El emisor de producción admite 5 certificados duplicados por semana para el mismo conjunto de nombres de host. Cada repetición del recorrido B emite uno nuevo, porque el clúster se crea desde cero. Las tres repeticiones dejan margen para dos reintentos en 7 días. Cualquier depuración se hace con `letsencrypt-staging` (recorrido A), y nunca con el emisor de producción.

Para cambiar de emisor, se cambia `EMISOR` en el paso 1 antes del paso 8. El valor acaba en `issuerRef` de `k8s/overlays/prod/certificado.yaml`. Si el certificado ya existe con el otro emisor, basta con volver a aplicar `certificado.yaml` con el valor nuevo: cert-manager detecta el cambio de emisor y emite otro.

### Congelación
Antes de la primera repetición medida:
1. El runbook, `k8s/`, `docker/`, `backend/` y `frontend/` están confirmados en git y sin cambios locales (`git status --short` vacío).
2. Se anota el commit (`git rev-parse --short HEAD`). Las tres repeticiones se hacen desde ese commit.
3. Las imágenes se construyen una sola vez (requisito previo P3), y las tres repeticiones usan la misma `TAG`.

Si hay que cambiar algo del runbook o de los artefactos entre repeticiones, se anota el motivo y la serie de tres repeticiones vuelve a empezar.

### Repetición que no llega al criterio
Una repetición del recorrido B que se interrumpe sin cumplir el criterio de respuesta (paso 13), aunque no haga falta cambiar ningún artefacto:
1. Se detiene el cronómetro con `marca "abortada <paso>"` y se anotan el error, el paso y la causa.
2. El entorno a medias se destruye con el paso 16 completo, aunque algunos objetos todavía no existan (ese comando falla y se sigue con el siguiente). Después se exige su verificación, con el inventario en código 0. Esta destrucción no se cuenta como medición.
3. La repetición se **descarta**: queda en la hoja de registro como abortada, pero no es una de las tres de la serie.
4. La serie **continúa** con una repetición nueva, desde el paso 1 y con un `EJECUCION` nuevo. Excepciones:
   - si corregir la causa exige cambiar el runbook o un artefacto, se aplica la regla de «Congelación» y la serie vuelve a empezar;
   - si dos repeticiones se abortan por la misma causa, la causa se trata como un defecto del procedimiento: se corrige y la serie vuelve a empezar.
5. Si la repetición abortada llegó a emitir un certificado con `letsencrypt-prod`, cuenta para el límite semanal (ver «Límite de Let's Encrypt»).

Motivo: un tiempo truncado no es comparable con uno completo; repetir sin cambiar nada mantiene comparables las demás, y un fallo que se repite deja de ser azar y señala el procedimiento.

## Alcance
- **Incluye:** todo lo que el entorno `prod` necesita además de la capa base. Es decir: red, clúster, base de datos, identidad del backend con sus roles, `DB_HOST` en App Configuration, controladores del clúster (Envoy Gateway, cert-manager), datos, aplicación, registro DNS y certificado.
- **No incluye:** la capa base, que no cambia en las sesiones; el entorno `dev`; el entorno de recuperación en AWS; la construcción de imágenes, que se hace una vez como requisito previo.
- **Todo lo que crea vive en el grupo de recursos `rg-tfm-unir-prod`**, salvo cuatro cosas que viven en la capa base y que el paso 16 borra de forma explícita:
  - la asignación `AcrPull` sobre el ACR (paso 3);
  - las asignaciones `Key Vault Secrets User` sobre el Key Vault de `prod` y `App Configuration Data Reader` sobre App Configuration (paso 5);
  - la clave `DB_HOST` con etiqueta `prod` en App Configuration (paso 4);
  - el registro A del nombre de host en la zona de Route 53 (paso 11). El script de inventario no revisa Route 53.

  Son exactamente los objetos que creará y borrará la capa de entorno. No modifican los recursos de la capa base, solo sus permisos y su contenido.

## Requisitos previos (una sola vez, fuera de la medición)

### P1. Configuración de `prod` en App Configuration
En App Configuration, con la etiqueta `prod`:
- `ALLOWED_HOSTS` es `<host>,localhost`. `localhost` permite entrar al admin por `kubectl port-forward` (paso 15);
- `CORS_ALLOWED_ORIGINS` es `https://<host>`.

`<host>` es el nombre de host público de producción.

Verificación:
```bash
az appconfig kv list -n <app_configuration> --label prod --auth-mode login --query "[?key=='ALLOWED_HOSTS' || key=='CORS_ALLOWED_ORIGINS'].{clave:key, valor:value}" -o table
```
Muestra `<host>,localhost` y `https://<host>`. Si no coincide, aplicar la capa base de Azure (`terraform/base/azure`) antes de empezar.

### P1b. Retención del bucket de respaldos
La regla de ciclo de vida del bucket de respaldos no expira la versión actual de los objetos. Por qué importa: ver «Mismo respaldo en las tres repeticiones».

Verificación:
```bash
aws s3api get-bucket-lifecycle-configuration --bucket <bucket_respaldos>
```
Muestra una sola regla, con `NoncurrentVersionExpiration` y sin `Expiration`. Si no coincide, aplicar la capa base de AWS (`terraform/base/aws`) antes de empezar.

### P2. Artefactos en el repositorio
Estos archivos están confirmados en git, sin cambios locales y con sus marcadores (`<host-prod>`, `<acr_servidor>`…) sin rellenar:
- `k8s/overlays/prod/`: overlay de producción, con `certificado.yaml` aplicado aparte;
- `k8s/cluster/clusterissuer-letsencrypt.yaml`: emisores `letsencrypt-staging` y `letsencrypt-prod`.

El paso 8 rellena los marcadores y el paso 16 los restaura. Si siguen rellenos, la ejecución anterior no terminó el paso 16.

Verificación, desde la raíz del repositorio:
```bash
git status --short k8s/overlays/prod/ k8s/cluster/
grep -l '<host-prod>' k8s/overlays/prod/*.yaml
```
El primer comando no muestra nada. El segundo lista los tres archivos del overlay. Si no coincide, ejecutar `git restore k8s/overlays/prod/` y repetir la verificación.

### P3. Imágenes
Se construyen y suben una vez, desde la raíz del repositorio, sin cambios locales, para que la etiqueta corresponda exactamente al código de la imagen. Requiere `docker` con BuildKit (Docker 23 o superior). Los nodos de AKS son `linux/amd64`; si el equipo local es ARM, añadir `--platform linux/amd64` al build.
```bash
git status --short        # debe salir vacío
export TAG=$(git rev-parse --short HEAD)
export ACR_NOMBRE=$(terraform -chdir=terraform/base/azure output -raw acr_nombre)
export ACR_SERVIDOR=$(terraform -chdir=terraform/base/azure output -raw acr_servidor)
az acr login -n $ACR_NOMBRE --expose-token --query accessToken -o tsv \
  | docker login $ACR_SERVIDOR -u 00000000-0000-0000-0000-000000000000 --password-stdin
docker build -f docker/backend/Dockerfile  -t $ACR_SERVIDOR/gymscreen-backend:$TAG .
docker build -f docker/frontend/Dockerfile -t $ACR_SERVIDOR/gymscreen-frontend:$TAG .
docker push $ACR_SERVIDOR/gymscreen-backend:$TAG
docker push $ACR_SERVIDOR/gymscreen-frontend:$TAG
```
Verificación: `az acr repository show-tags -n $ACR_NOMBRE --repository gymscreen-backend -o table` (y lo mismo con `gymscreen-frontend`) muestra la etiqueta `$TAG`.

Se anota la `TAG`. En la automatización, el pipeline de CI construye y sube las imágenes; la creación del entorno solo las despliega. Por eso no forman parte del ciclo medido.

### P4. Registro de la ejecución
Una hoja de registro con las columnas de la sección «Hoja de registro», y una carpeta local fuera del repositorio para los archivos de cada ejecución (paso 0.6).

## 0. Sesión (fuera de la medición)
- Este runbook está escrito para una terminal bash de WSL (Ubuntu) en Windows. Todos los comandos se ejecutan ahí, con herramientas instaladas dentro de Ubuntu, no con las de Windows.
- Toda la ejecución se hace **en una sola terminal**: las variables y la función `marca` no pasan a otras.

1. Herramientas instaladas en WSL:
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
   - AWS CLI v2 con sesión iniciada en la cuenta del proyecto. Hace falta porque la zona DNS está en Route 53, el respaldo está en S3 y las salidas de la capa base de AWS se leen de su estado.
   - `kubectl`: `sudo az aks install-cli`, o el paquete oficial de Kubernetes.
   - `helm` (versión 3 o superior): script oficial de instalación de Helm.
   - `jq`, `terraform`, `git`, `curl` y `dig` (paquete `dnsutils`).
2. Verificación de las sesiones:
   - `az account show -o table` muestra la suscripción del proyecto.
   - `aws sts get-caller-identity` muestra la cuenta del proyecto.
   - `kubectl version --client`, `helm version`, `jq --version`, `terraform version` y `dig -v` responden.
3. Verificación: `which az aws kubectl helm terraform` devuelve rutas de Linux (`/usr/bin/...`, `/usr/local/bin/...`), ninguna bajo `/mnt/c/`.
   - Por qué: si alguna apunta a `/mnt/c/`, WSL está usando el binario de Windows, que termina cada línea con `\r\n`. `$(...)` quita el `\n` pero deja el `\r`, así que las variables de los pasos 1 a 5 acaban con un retorno de carro.
   - Síntoma: el comando siguiente falla con un id o nombre "no válido" aunque se vea bien al imprimirlo. También puede fallar la conexión a PostgreSQL por `DB_PASS`.
   - Comprobar una variable: `echo -n "$SUBRED_AKS_ID" | od -c | tail -2` muestra `\r` al final.
   - Comprobar todas las variables de la sesión: `for v in $(compgen -e); do case "${!v}" in *$'\r'*) echo "$v contiene \\r";; esac; done` lista las afectadas.
   - Corregir:
     1. Instalar la herramienta dentro de Ubuntu. Para Azure CLI: `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`.
     2. Ejecutar `hash -r`, repetir `az login` y volver a definir las variables.
4. Congelación: desde la raíz del repositorio, `git status --short` sale vacío. Anotar `git rev-parse --short HEAD` en la hoja de registro.
5. No consultar el nombre de host público (ni `curl`, ni navegador, ni `dig`) antes del paso 11. Si se consulta mientras no existe el registro A, la respuesta negativa queda en la caché de los resolutores hasta 15 minutos, y alarga de forma artificial la espera del paso 11.
6. Preparar el registro de la ejecución:
   ```bash
   export EJECUCION=DD-MM-AAAA-a          # id de la sesión, por ejemplo 19-11-2026-a
   export RECORRIDO=B                     # A: creación inicial; B: ciclo de recreación
   export TRABAJO=~/mediciones/$EJECUCION # archivos locales de la ejecución, fuera del repositorio
   mkdir -p $TRABAJO
   marca() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EJECUCION" "$RECORRIDO" "$*" | tee -a $TRABAJO/marcas.tsv; }
   ```
   Verificación: `marca prueba` imprime una línea con la hora UTC y la añade a `$TRABAJO/marcas.tsv`.

## 1. Variables
```bash
marca "1 inicio"
```
**Aquí empieza la medición.**

Todos los pasos usan estas variables. Se definen desde la raíz del repositorio. Los recursos llevan las etiquetas de `terraform/docs/convencion-etiquetas.md` con `entorno=produccion`.

```bash
# Sesión
export PROYECTO=tfm-unir
export UBICACION=eastus2
export ETIQUETAS="proyecto=$PROYECTO entorno=produccion ejecucion=$EJECUCION"
export TAG=<tag-de-P3>                   # la misma en las tres repeticiones
if [ "$RECORRIDO" = A ]; then export EMISOR=letsencrypt-staging; else export EMISOR=letsencrypt-prod; fi

# Recursos del entorno (se destruyen en el paso 16)
export RG=rg-$PROYECTO-prod
export VNET=vnet-$PROYECTO-prod
export SUBRED_AKS=snet-aks
export SUBRED_DB=snet-postgres
export AKS=aks-$PROYECTO-prod
export K8S_VERSION=1.36
export PG=psql-$PROYECTO-prod-${EJECUCION//-/}   # nombre único en Azure: lleva el id de la ejecución
export ZONA_PG=tfm-prod.private.postgres.database.azure.com
export IDENTIDAD=id-$PROYECTO-prod-backend

# Salidas de la capa base de Azure
export TF_AZ=terraform/base/azure
export ACR_NOMBRE=$(terraform -chdir=$TF_AZ output -raw acr_nombre)
export ACR_SERVIDOR=$(terraform -chdir=$TF_AZ output -raw acr_servidor)
export KV_PROD_NOMBRE=$(terraform -chdir=$TF_AZ output -json key_vault | jq -r .prod.nombre)
export KV_PROD_URI=$(terraform -chdir=$TF_AZ output -json key_vault | jq -r .prod.uri)
export APPCS_NOMBRE=$(terraform -chdir=$TF_AZ output -json app_configuration | jq -r .nombre)
export APPCS_ENDPOINT=$(terraform -chdir=$TF_AZ output -json app_configuration | jq -r .endpoint)

# Salidas de la capa base de AWS
export TF_AWS=terraform/base/aws
export ZONA_DNS_ID=$(terraform -chdir=$TF_AWS output -raw zona_dns_id)
export BUCKET=$(terraform -chdir=$TF_AWS output -raw bucket_respaldos)

# Nombre de host público: CORS_ALLOWED_ORIGINS de prod en App Configuration, sin el https://
export HOST_PUBLICO=$(az appconfig kv show -n $APPCS_NOMBRE --key CORS_ALLOWED_ORIGINS --label prod --auth-mode login --query value -o tsv | sed 's|^https://||')

# Respaldo de referencia en S3 (lo crea el recorrido A, paso 14)
export RESPALDO_CLAVE=prod/linea-base/tfm.dump
export CONTEOS_CLAVE=prod/linea-base/conteos.json
export RESPALDO_VERSION=<version-id-del-paso-14>   # solo recorrido B
export CONTEOS_VERSION=<version-id-del-paso-14>    # solo recorrido B
marca "1 fin"
```

- El nombre de PostgreSQL lleva el id de la ejecución porque Azure puede reservar el nombre de un servidor borrado durante un tiempo. Repetir el mismo nombre entre repeticiones haría fallar la creación.
- `K8S_VERSION` fija la versión menor de Kubernetes. Sin ella, AKS elige la predeterminada de la región, que puede cambiar entre repeticiones.

Verificación: `env | grep -E "^(RG|VNET|SUBRED|AKS|K8S|PG|ZONA|IDENTIDAD|ACR_|KV_|APPCS_|BUCKET|HOST_PUBLICO|TAG|EMISOR|RESPALDO|CONTEOS)"` muestra todos los valores, sin vacíos y sin `<` en el recorrido B. `HOST_PUBLICO` es un nombre de host, sin esquema ni barra final.

## 2. Red
```bash
marca "2 inicio"
```
Una VNet para producción, con el direccionamiento del diagrama de red: `10.20.0.0/16`, una subred para los nodos del clúster y otra delegada a PostgreSQL. La base queda sin acceso público y solo se alcanza desde dentro de la VNet.

| Subred | Rango | Uso |
|---|---|---|
| `snet-aks` | `10.20.0.0/22` | Nodos de AKS. Los pods usan una red superpuesta propia (paso 3), no consumen IP de la subred |
| `snet-postgres` | `10.20.4.0/24` | PostgreSQL Flexible Server, delegada a `Microsoft.DBforPostgreSQL/flexibleServers` |

1. Crear el grupo de recursos del entorno:
   ```bash
   az group create -n $RG -l $UBICACION --tags $ETIQUETAS
   ```
2. Crear la VNet con la subred del clúster:
   ```bash
   az network vnet create -g $RG -n $VNET -l $UBICACION \
     --address-prefixes 10.20.0.0/16 \
     --subnet-name $SUBRED_AKS --subnet-prefixes 10.20.0.0/22 \
     --tags $ETIQUETAS
   ```
3. Crear la subred delegada de la base:
   ```bash
   az network vnet subnet create -g $RG --vnet-name $VNET -n $SUBRED_DB \
     --address-prefixes 10.20.4.0/24 \
     --delegations Microsoft.DBforPostgreSQL/flexibleServers
   ```
4. Verificación: `az network vnet subnet list -g $RG --vnet-name $VNET --query "[].{nombre:name, rango:addressPrefix, delegacion:delegations[0].serviceName}" -o table` muestra las dos subredes con sus rangos y la delegación en `snet-postgres`.
```bash
marca "2 fin"
```

## 3. Clúster AKS
```bash
marca "3 inicio"
```
Clúster pequeño en la subred `snet-aks`, con:
- Azure CNI en modo superpuesto (overlay): los nodos toman IP de la subred y los pods de un rango propio que no consume direcciones de la VNet.
- OIDC issuer y Workload Identity: los pods del backend obtienen un token de Azure sin credenciales guardadas en el clúster (paso 5).
- Permiso `AcrPull` sobre el ACR de la capa base (`--attach-acr`), para descargar las imágenes sin secretos de registro. Es una asignación sobre la capa base (ver Alcance); el paso 16 la quita con `--detach-acr` antes de borrar el clúster.

Los rangos internos de Kubernetes (`10.244.0.0/16` para pods, `10.0.0.0/16` para servicios) no se solapan con la VNet.

1. Verificar que hay cuota de vCPU para la familia del tamaño de nodo en la región, y que la versión de Kubernetes está disponible. Hacen falta al menos 4 vCPU libres (2 nodos × 2).
   ```bash
   # Verificación: Limit menos CurrentValue >= 4 en ambas filas
   az vm list-usage -l $UBICACION -o table | grep -iE "Total Regional vCPUs|Dalv6 Family"
   # Verificación: aparece al menos un parche de la versión $K8S_VERSION
   az aks get-versions -l $UBICACION --query "values[?starts_with(version, '$K8S_VERSION')].version" -o tsv
   ```
2. Obtener los identificadores de la subred y del ACR:
   ```bash
   export SUBRED_AKS_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET -n $SUBRED_AKS --query id -o tsv)
   export ACR_ID=$(az acr show -n $ACR_NOMBRE --query id -o tsv)
   ```
3. Crear el clúster (tarda entre 5 y 10 minutos):
   ```bash
   az aks create -g $RG -n $AKS -l $UBICACION \
     --tier free \
     --kubernetes-version $K8S_VERSION \
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
   az aks get-credentials -g $RG -n $AKS --overwrite-existing
   ```
5. Verificación:
   - `kubectl get nodes -o wide` muestra 2 nodos `Ready` con IP de `10.20.0.0/22`.
   - `az aks show -g $RG -n $AKS --query "{version:currentKubernetesVersion, oidc:oidcIssuerProfile.enabled, workloadIdentity:securityProfile.workloadIdentity.enabled}" -o table` muestra la versión `$K8S_VERSION.x` (anotarla) y `True` en las otras dos.
   - La identidad del kubelet tiene `AcrPull` sobre el ACR. `--attach-acr` puede fallar con solo un aviso y el clúster se crea igual; sin este rol los pods quedan en `ImagePullBackOff` con `401 Unauthorized`. El comando debe devolver el id del ACR; si no devuelve nada, ejecutar `az aks update -g $RG -n $AKS --attach-acr $ACR_ID`:
     ```bash
     export KUBELET_ID=$(az aks show -g $RG -n $AKS --query identityProfile.kubeletidentity.objectId -o tsv)
     az role assignment list --assignee $KUBELET_ID --all --query "[?roleDefinitionName=='AcrPull'].scope" -o tsv
     ```
   - `az aks check-acr -g $RG -n $AKS --acr $ACR_SERVIDOR` termina sin errores. Justo después de crear el clúster puede fallar con `503` hasta que los pods `konnectivity-agent` de `kube-system` estén `Running`.
6. Si `--attach-acr` falla por permisos, el usuario necesita Owner o User Access Administrator sobre el ACR (asigna un rol).
```bash
marca "3 fin"
```

## 4. PostgreSQL Flexible Server
```bash
marca "4 inicio"
```
Servidor con acceso privado en `snet-postgres`, sin acceso público. Su nombre se resuelve con una zona DNS privada enlazada a la VNet, de modo que los pods lo alcanzan por `<servidor>.postgres.database.azure.com`. Como no es accesible desde fuera de la VNet, las operaciones con `psql` se hacen desde un pod temporal dentro del clúster.

Usuarios:
- `pgadmin`: administrador del servidor, solo para esta preparación. Su contraseña se genera aquí y no se guarda en el repositorio ni en la hoja de registro.
- `tfm_app`: el usuario de la aplicación (`DB_USER` en App Configuration). Su contraseña es el secreto `DB-PASSWORD` del Key Vault de `prod`, el mismo que lee el backend.

1. Obtener la subred y generar la contraseña del administrador:
   ```bash
   export SUBRED_DB_ID=$(az network vnet subnet show -g $RG --vnet-name $VNET -n $SUBRED_DB --query id -o tsv)
   export PG_ADMIN_PASS=$(openssl rand -base64 24)
   ```
2. Crear la zona DNS privada y enlazarla a la VNet. Se crea antes que el servidor y se le pasa por id: al pasarla por nombre, Azure la rechaza con `PrivateDnsZoneNameNotValid`.
   ```bash
   export VNET_ID=$(az network vnet show -g $RG -n $VNET --query id -o tsv)
   az network private-dns zone create -g $RG -n $ZONA_PG --tags $ETIQUETAS
   az network private-dns link vnet create -g $RG -z $ZONA_PG -n enlace-$VNET \
     --virtual-network $VNET_ID --registration-enabled false
   export ZONA_PG_ID=$(az network private-dns zone show -g $RG -n $ZONA_PG --query id -o tsv)
   ```
3. Crear el servidor (tarda entre 5 y 15 minutos):
   ```bash
   az postgres flexible-server create -g $RG -n $PG -l $UBICACION \
     --version 18 \
     --tier Burstable --sku-name Standard_B2s --storage-size 32 \
     --subnet $SUBRED_DB_ID \
     --private-dns-zone $ZONA_PG_ID \
     --admin-user pgadmin --admin-password "$PG_ADMIN_PASS" \
     --backup-retention 7 \
     --tags $ETIQUETAS --yes
   export PG_HOST=$PG.postgres.database.azure.com
   ```
   Si falla con `SkuNotAvailable`, la suscripción no puede usar ese SKU en la región aunque aparezca en `az postgres flexible-server list-skus`. Probar otro Burstable y anotarlo.
4. Crear el usuario y la base de la aplicación desde un pod temporal. La contraseña de `tfm_app` se lee de Key Vault y se pasa a `psql` como variable, sin escribirla en el script:
   ```bash
   export DB_PASS=$(az keyvault secret show --vault-name $KV_PROD_NOMBRE -n DB-PASSWORD --query value -o tsv)

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
5. Escribir `DB_HOST` en App Configuration con la etiqueta `prod`. Es el estado final que dejará la capa de entorno: el backend lee todas sus claves de App Configuration y el overlay no sustituye ninguna. El paso 16 la borra.
   ```bash
   az appconfig kv set -n $APPCS_NOMBRE --key DB_HOST --label prod --value $PG_HOST --auth-mode login --yes
   ```
   Escribe con el rol `App Configuration Data Owner` que la capa base da a quien la aplica.
6. Verificación:
   - `az postgres flexible-server show -g $RG -n $PG --query "{estado:state, version:version, fqdn:fullyQualifiedDomainName, accesoPublico:network.publicNetworkAccess}" -o table` muestra `Ready`, versión 18 y acceso público `Disabled`.
   - `az appconfig kv show -n $APPCS_NOMBRE --key DB_HOST --label prod --auth-mode login --query value -o tsv` devuelve `$PG_HOST`.
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
```bash
marca "4 fin"
```

## 5. Identidad del backend
```bash
marca "5 inicio"
```
Identidad administrada que usan los pods del backend y el Job de migraciones (ServiceAccount `backend` del namespace `gymscreen`) para leer Key Vault y App Configuration. La credencial federada permite que el token del ServiceAccount, emitido por el OIDC issuer del clúster, se canjee por un token de Azure de esta identidad.

1. Crear la identidad y leer sus identificadores:
   ```bash
   az identity create -g $RG -n $IDENTIDAD -l $UBICACION --tags $ETIQUETAS
   export IDENTIDAD_CLIENT_ID=$(az identity show -g $RG -n $IDENTIDAD --query clientId -o tsv)
   export IDENTIDAD_PRINCIPAL_ID=$(az identity show -g $RG -n $IDENTIDAD --query principalId -o tsv)
   export AKS_OIDC_ISSUER=$(az aks show -g $RG -n $AKS --query oidcIssuerProfile.issuerUrl -o tsv)
   ```
2. Crear la credencial federada para el ServiceAccount `gymscreen/backend`:
   ```bash
   az identity federated-credential create -g $RG --identity-name $IDENTIDAD -n backend \
     --issuer $AKS_OIDC_ISSUER \
     --subject system:serviceaccount:gymscreen:backend \
     --audiences api://AzureADTokenExchange
   ```
3. Asignar los roles de lectura sobre los almacenes de la capa base. Son asignaciones sobre la capa base (ver Alcance); el paso 16 las borra:
   ```bash
   export KV_PROD_ID=$(az keyvault show -n $KV_PROD_NOMBRE --query id -o tsv)
   export APPCS_ID=$(az appconfig show -n $APPCS_NOMBRE --query id -o tsv)

   az role assignment create --assignee-object-id $IDENTIDAD_PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
     --role "Key Vault Secrets User" --scope $KV_PROD_ID
   az role assignment create --assignee-object-id $IDENTIDAD_PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
     --role "App Configuration Data Reader" --scope $APPCS_ID
   ```
   Los roles tardan unos minutos en propagarse. Si el backend arranca antes, falla con 403 y Kubernetes lo reinicia hasta que el permiso está activo.
4. Verificación:
   - `az identity federated-credential list -g $RG --identity-name $IDENTIDAD --query "[].{nombre:name, subject:subject}" -o table` muestra `system:serviceaccount:gymscreen:backend`.
   - `az role assignment list --assignee $IDENTIDAD_PRINCIPAL_ID --all --query "[].{rol:roleDefinitionName, ambito:scope}" -o table` muestra los dos roles.
```bash
marca "5 fin"
```

## 6. Envoy Gateway
```bash
marca "6 inicio"
```
Controlador de Gateway API. Por cada `Gateway` crea un proxy Envoy y un Service `LoadBalancer` con IP pública en el namespace `envoy-gateway-system`. El chart instala también las definiciones (CRD) de Gateway API, que cert-manager necesita (paso 7).

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
```bash
marca "6 fin"
```

## 7. cert-manager y emisores
```bash
marca "7 inicio"
```
cert-manager emite el certificado de Let's Encrypt con el desafío HTTP-01, que resuelve sobre el propio Gateway: crea una `HTTPRoute` temporal en el listener del puerto 80. No usa un Ingress.
- Versión fijada: **v1.21.3**. Admite Kubernetes 1.33 a 1.36.
- `config.gatewayAPI.enabled=true` activa la integración con Gateway API. cert-manager tiene que arrancar después de que existan las CRD de Gateway API (paso 6); si no, hay que reiniciar su Deployment.
- Referencias: instalación con Helm, https://cert-manager.io/docs/installation/helm/; solucionador HTTP-01 con Gateway API, https://cert-manager.io/docs/configuration/acme/http01/.

1. Instalar cert-manager:
   ```bash
   export CERT_MANAGER_VERSION=v1.21.3
   helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version $CERT_MANAGER_VERSION \
     -n cert-manager --create-namespace \
     --set crds.enabled=true \
     --set config.gatewayAPI.enabled=true
   kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=5m
   ```
2. Crear los dos emisores. Son de ámbito de clúster, así que quedan fuera de Kustomize, igual que la `GatewayClass`:
   ```bash
   kubectl apply -f k8s/cluster/clusterissuer-letsencrypt.yaml
   ```
   Si responde `failed calling webhook`, el webhook de cert-manager todavía no está listo: esperar unos segundos y repetir.
3. Verificación: `kubectl get clusterissuer` muestra `letsencrypt-staging` y `letsencrypt-prod` con `READY True`. Esto confirma que se registró la cuenta ACME en cada servidor de Let's Encrypt.
```bash
marca "7 fin"
```

## 8. Overlay de producción
```bash
marca "8 inicio"
```
1. Comprobar que las imágenes de `TAG` están en el ACR:
   ```bash
   az acr repository show-tags -n $ACR_NOMBRE --repository gymscreen-backend  -o tsv | grep -x $TAG
   az acr repository show-tags -n $ACR_NOMBRE --repository gymscreen-frontend -o tsv | grep -x $TAG
   ```
2. Rellenar los marcadores `<...>` del overlay con los valores de la sesión. Ninguno es secreto, pero son de la sesión o del dominio, así que no se confirman en el repositorio; el paso 16 restaura los archivos:
   ```bash
   sed -i \
     -e "s|<acr_servidor>|$ACR_SERVIDOR|g" \
     -e "s|<sha-del-commit>|$TAG|g" \
     -e "s|<key_vault_prod_uri>|$KV_PROD_URI|" \
     -e "s|<app_configuration_endpoint>|$APPCS_ENDPOINT|" \
     -e "s|<client-id>|$IDENTIDAD_CLIENT_ID|g" \
     -e "s|<host-prod>|$HOST_PUBLICO|g" \
     -e "s|<emisor>|$EMISOR|g" \
     k8s/overlays/prod/kustomization.yaml \
     k8s/overlays/prod/httproute-redireccion.yaml \
     k8s/overlays/prod/certificado.yaml
   ```
3. Verificación:
   - `kubectl kustomize k8s/overlays/prod | grep -nE "image:|hostname:|KEY_VAULT_URL|client-id|<"` muestra las imágenes del ACR con `$TAG`, `$HOST_PUBLICO` en los dos listeners, la URL del Key Vault de `prod`, el client-id y ningún `<` pendiente.
   - `grep -nE "dnsNames|name: \"?letsencrypt|$HOST_PUBLICO" k8s/overlays/prod/certificado.yaml` muestra `$HOST_PUBLICO` y `$EMISOR`.
```bash
marca "8 fin"
```

## 9. Datos y migraciones
```bash
marca "9$RECORRIDO inicio"      # 9A o 9B, según el recorrido
```
El Job de migraciones (`migrate`) y el resto de los recursos se aplican en dos fases. La fase 1 aplica todo menos los Deployments: los dos llevan la etiqueta `app.kubernetes.io/component: servidor` (`k8s/base/`), y el selector `!=` incluye también los recursos sin esa etiqueta. Los Deployments entran en el paso 10, cuando el Job ya terminó.

El Job no admite cambios, así que se borra el anterior antes de cada aplicación (en la primera no existe y el comando no hace nada).

Usar el subpaso 9A en el recorrido A y el 9B en el recorrido B.

### 9A. Base vacía y catálogo (solo recorrido A)
1. Fase 1 y espera del Job. Las migraciones crean las tablas vacías:
   ```bash
   kubectl delete job migrate -n gymscreen --ignore-not-found
   kubectl apply -k k8s/overlays/prod -l 'app.kubernetes.io/component!=servidor'
   kubectl wait --for=condition=complete job/migrate -n gymscreen --timeout=10m
   ```
2. Cargar el catálogo. `seed_data.sql` empieza con un `TRUNCATE` del catálogo; aquí es seguro porque la base se acaba de crear:
   ```bash
   kubectl run psql-seed -n default --rm -i --restart=Never --image=postgres:18 \
     --env="PGPASSWORD=$DB_PASS" -- \
     psql "host=$PG_HOST user=tfm_app dbname=tfm sslmode=require" -v ON_ERROR_STOP=1 -f - \
     < db/seed_data.sql
   ```
   El script es una sola transacción: si algo falla, no se carga nada.
3. Verificación: `kubectl logs job/migrate -n gymscreen` muestra las migraciones aplicadas, y la carga termina con `COMMIT`.
```bash
marca "9A fin"
```

### 9B. Restauración desde S3 (solo recorrido B)
Orden: **crear la base (paso 4), restaurar el respaldo, ejecutar el Job de migraciones y esperarlo, y después desplegar (paso 10).**

Por qué en ese orden y no al revés:
- **Restaurar antes de migrar.** El respaldo contiene las tablas, sus datos y la tabla `django_migrations`, que registra qué migraciones tiene ese esquema. Si el Job corriera primero sobre la base vacía, crearía las tablas y la restauración fallaría con objetos que ya existen. Al migrar después, Django aplica solo las migraciones que el código de la imagen tiene y el respaldo no. Es lo que pasa en una recuperación real cuando la imagen es más nueva que el respaldo; si coinciden, el Job responde `No migrations to apply`.
- **Esperar al Job antes de desplegar.** Si los pods del backend arrancaran antes, servirían código contra un esquema incompleto o distinto. Su sonda de disponibilidad (`/readyz`) solo comprueba la conexión, así que los pods estarían `Ready` y la API devolvería errores 500. El criterio de respuesta (paso 13) mediría un estado que no es el final.

1. Descargar el respaldo y los conteos de referencia, fijados por su versión:
   ```bash
   aws s3api get-object --bucket $BUCKET --key $RESPALDO_CLAVE --version-id $RESPALDO_VERSION $TRABAJO/tfm.dump
   aws s3api get-object --bucket $BUCKET --key $CONTEOS_CLAVE --version-id $CONTEOS_VERSION $TRABAJO/conteos-referencia.json
   ```
2. Restaurar el respaldo desde un pod de herramientas. El archivo entra por la entrada estándar de `kubectl exec`, que transmite binarios sin alterarlos, así que el clúster no necesita credenciales de AWS:
   ```bash
   kubectl run pg-herramientas -n default --restart=Never --image=postgres:18 \
     --env="PGPASSWORD=$DB_PASS" -- sleep 3600
   kubectl wait pod/pg-herramientas -n default --for=condition=Ready --timeout=2m
   kubectl exec -i pg-herramientas -n default -- \
     pg_restore --no-owner --no-acl --single-transaction --exit-on-error \
       -d "host=$PG_HOST user=tfm_app dbname=tfm sslmode=require" \
     < $TRABAJO/tfm.dump
   kubectl delete pod pg-herramientas -n default
   ```
   - `--no-owner --no-acl`: los objetos quedan a nombre de `tfm_app`, el usuario que restaura.
   - `--single-transaction`: si algo falla, no queda una restauración a medias.
   - Si `pg_restore` falla, borrar igualmente el pod: lleva la contraseña en su definición.
3. Fase 1 y espera del Job de migraciones:
   ```bash
   kubectl delete job migrate -n gymscreen --ignore-not-found
   kubectl apply -k k8s/overlays/prod -l 'app.kubernetes.io/component!=servidor'
   kubectl wait --for=condition=complete job/migrate -n gymscreen --timeout=10m
   ```
4. Verificación: `pg_restore` termina sin errores, y `kubectl logs job/migrate -n gymscreen` muestra `No migrations to apply` o solo las migraciones posteriores al respaldo.
```bash
marca "9B fin"
```

### Si el Job no termina
`kubectl wait --for=condition=complete` no termina antes si el Job falla: espera hasta el tiempo límite. Si tarda más de lo normal, revisar con `kubectl get pods -n gymscreen -l job-name=migrate` y `kubectl logs -n gymscreen -l job-name=migrate --tail=40 --prefix`:
- `permission denied for schema public`: falta el `GRANT` del paso 4.4.
- `Missing configuration for ENV=prod: ...`: falta una clave en App Configuration con etiqueta `prod` (`DB_HOST` del paso 4.5, o las de la capa base).
- `Key Vault ... failed` o `App Configuration ... failed` con 403: los roles del paso 5 aún no se propagaron, o la credencial federada no coincide con `gymscreen/backend`.
- `ImagePullBackOff`: revisar el `AcrPull` del paso 3.5 y que la etiqueta exista (paso 8.1).

## 10. Aplicación
```bash
marca "10 inicio"
```
1. Fase 2: aplicar el overlay completo. Entran los Deployments; el resto de recursos no cambia:
   ```bash
   kubectl apply -k k8s/overlays/prod
   kubectl rollout status deployment/backend  -n gymscreen --timeout=5m
   kubectl rollout status deployment/frontend -n gymscreen --timeout=5m
   ```
2. Verificación:
   - `kubectl get pods -n gymscreen` muestra 2 pods `backend` y 2 `frontend` en `Running` y `READY 1/1`, y el pod del Job en `Completed`.
   - `kubectl logs deployment/backend -n gymscreen` muestra el arranque de Gunicorn sin errores de configuración.
     - Línea conocida: `[ERROR] Control server error: [Errno 30] Read-only file system: '/home/app'`. Gunicorn intenta abrir su servidor de control en el directorio del usuario, y el contenedor tiene el sistema de archivos de solo lectura. No impide el arranque: los workers arrancan y las sondas responden `200`. No es un error de configuración y no se anota como error.
   - `kubectl get gateway gymscreen -n gymscreen` muestra una dirección IP. El listener `https` todavía no está listo, porque el certificado se emite en el paso 12.
```bash
marca "10 fin"
```

## 11. Registro DNS
```bash
marca "11 inicio"
```
Secuencia obligada: el Gateway ya existe (paso 9), aquí se lee su IP, se escribe el registro A y se espera a que resuelva. **Solo entonces** se emite el certificado (paso 12). Let's Encrypt valida el desafío HTTP-01 conectándose al nombre de host, así que el nombre tiene que apuntar ya a la IP del Gateway.

El registro tiene TTL de 60 segundos, para que la IP de la repetición anterior caduque pronto en las cachés.

1. Leer la IP del Gateway y escribir el registro A en Route 53:
   ```bash
   export GATEWAY_IP=$(kubectl get gateway gymscreen -n gymscreen -o jsonpath='{.status.addresses[0].value}')
   echo "$GATEWAY_IP"                     # no debe salir vacío
   export CAMBIO_DNS=$(aws route53 change-resource-record-sets --hosted-zone-id $ZONA_DNS_ID \
     --change-batch "$(jq -nc --arg h "$HOST_PUBLICO" --arg ip "$GATEWAY_IP" \
       '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$h,Type:"A",TTL:60,ResourceRecords:[{Value:$ip}]}}]}')" \
     --query ChangeInfo.Id --output text)
   ```
2. Espera de la propagación (espera externa). Primero Route 53 confirma el cambio en sus servidores; después el nombre tiene que resolver en un servidor de la zona y en el resolutor local, que es el que usará la verificación del paso 13:
   ```bash
   marca "11 espera-dns inicio"
   aws route53 wait resource-record-sets-changed --id $CAMBIO_DNS
   export NS_ZONA=$(aws route53 get-hosted-zone --id $ZONA_DNS_ID --query 'DelegationSet.NameServers[0]' --output text)
   timeout 5m bash -c 'until [ "$(dig +short @$NS_ZONA $HOST_PUBLICO A)" = "$GATEWAY_IP" ]; do sleep 5; done' \
     && timeout 20m bash -c 'until getent hosts $HOST_PUBLICO | grep -q "^$GATEWAY_IP "; do sleep 10; done' \
     && marca "11 espera-dns fin" \
     || marca "11 espera-dns tiempo agotado"
   ```
   Límites:
   - `aws route53 wait` tiene el suyo: consulta cada 30 segundos, hasta 60 veces (30 minutos), y termina con error si se agota.
   - Servidor de la zona: 5 minutos. Route 53 confirma los cambios en sus servidores en menos de un minuto.
   - Resolutor local: 20 minutos. Cubre el TTL de 60 segundos y una respuesta negativa en caché, que dura como máximo 15 minutos (paso 0.5).
3. Verificación: `dig +short @$NS_ZONA $HOST_PUBLICO A` y `getent hosts $HOST_PUBLICO` devuelven `$GATEWAY_IP`.
4. Si se agota algún límite (`11 espera-dns tiempo agotado`), no se pasa al paso 12. Se anota como error y:
   - **Servidor de la zona o `aws route53 wait`:** el registro no llegó a Route 53 o la zona no es la del dominio. Revisar `aws route53 list-resource-record-sets --hosted-zone-id $ZONA_DNS_ID --query "ResourceRecordSets[?Type=='A']"` y que `dig +short NS <dominio>` devuelva los servidores de `aws route53 get-hosted-zone --id $ZONA_DNS_ID`. Corregido, repetir el subpaso 2.
   - **Resolutor local:** el servidor de la zona ya responde, pero el resolutor local no, y la causa probable es una respuesta negativa en caché (ver paso 0.5). No se acorta borrando cachés, para no alterar la medición. La repetición se aborta (ver «Repetición que no llega al criterio»).
```bash
marca "11 fin"
```

## 12. Certificado
```bash
marca "12 inicio"
```
1. Solicitar el certificado. cert-manager crea el desafío, publica la respuesta en el listener del puerto 80 y, cuando Let's Encrypt la valida, guarda el certificado en el Secret `gymscreen-tls`:
   ```bash
   kubectl apply -f k8s/overlays/prod/certificado.yaml
   ```
2. Espera de la emisión (espera externa):
   ```bash
   marca "12 espera-certificado inicio"
   kubectl wait --for=condition=Ready certificate/gymscreen-tls -n gymscreen --timeout=15m
   marca "12 espera-certificado fin"
   ```
3. Verificación:
   - `kubectl get certificate gymscreen-tls -n gymscreen` muestra `READY True`.
   - `kubectl get gateway gymscreen -n gymscreen -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="Programmed")].status}'` devuelve `True`.
4. Si no pasa a `Ready`:
   - `kubectl describe certificate gymscreen-tls -n gymscreen` y `kubectl get challenges -n gymscreen -o wide` muestran en qué estado está el desafío.
   - **La redirección captura la validación** (el fallo más probable).
     - Síntoma: el desafío queda inválido con un error de conexión o de TLS contra el puerto 443, que no se parece a un 404. Con la URL del desafío (`kubectl get challenges -n gymscreen -o yaml`, campos `url` y `token`), `curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" http://$HOST_PUBLICO/.well-known/acme-challenge/<token>` devuelve `301 https://...` en lugar de `200` con el token.
     - Causa: la regla `PathPrefix: /` de la `HTTPRoute` `gymscreen-redireccion` ganó a la ruta exacta del desafío. Let's Encrypt siguió la redirección hasta un 443 que todavía no tiene certificado.
     - Salida: excluir `/.well-known/acme-challenge/` de la `HTTPRoute` de redirección, para que la ruta del desafío tenga precedencia. Gateway API no tiene coincidencias negativas, así que la exclusión exige cambiar la `HTTPRoute` de redirección. Es un cambio de artefacto: se aplica la regla de «Congelación».
   - `404` en `/.well-known/acme-challenge/`: la `HTTPRoute` temporal de cert-manager no se enganchó al listener `http`. Revisar `kubectl get httproute -n gymscreen` y que cert-manager se instaló con `config.gatewayAPI.enabled=true` después de Envoy Gateway (pasos 6 y 7).
   - Desafío pendiente por DNS: el nombre no resuelve todavía a `$GATEWAY_IP` (paso 11).
   - Límite de Let's Encrypt (`too many certificates`): no reintentar con `letsencrypt-prod` (ver «Límite de Let's Encrypt»).
```bash
marca "12 fin"
```

## 13. Criterio de respuesta
```bash
marca "13 inicio"
```
1. La API responde por HTTPS con un certificado válido:
   ```bash
   # Recorrido A: el certificado de pruebas no es de confianza, añadir -k
   curl -s -o /dev/null -w "%{http_code}\n" https://$HOST_PUBLICO/api/v1/muscle-groups/      # 200
   ```
2. Conteos por grupo muscular, ordenados para compararlos:
   ```bash
   # Recorrido A: añadir -k, igual que arriba
   curl -s https://$HOST_PUBLICO/api/v1/muscle-groups/ | jq -S '[.[] | {name, exercise_count}] | sort_by(.name)' > $TRABAJO/conteos.json
   ```
3. Comparar con la referencia:
   - Recorrido B: `diff $TRABAJO/conteos-referencia.json $TRABAJO/conteos.json` no muestra diferencias. Si las hay, el criterio no se cumple y se anota como error.
   - Recorrido A: no hay referencia todavía. `$TRABAJO/conteos.json` se convierte en la referencia en el paso 14.
4. **Fin de la medición** (recorrido B), cuando los dos puntos anteriores se cumplen:
   ```bash
   marca "13 fin"
   ```
5. Comprobaciones posteriores (fuera del tiempo medido):
   - `curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" http://$HOST_PUBLICO/` devuelve `301 https://<host>/`.
   - En el navegador, `https://<host>/` carga la sección de Ejercicios. Recargar en una página de detalle (por ejemplo `/ejercicios/1`) vuelve a mostrarla.
   - `curl -s https://$HOST_PUBLICO/admin/ | grep -c "Django"` devuelve `0`: el admin no está publicado.
   - Anotar en la hoja de registro el tiempo total (de «1 inicio» a «13 fin»), el de cada paso y el de las dos esperas externas.

## 14. Superusuario y respaldo de referencia (solo recorrido A)
Deja en S3 el respaldo que restauran las tres repeticiones del recorrido B, y los conteos con los que se comparan.

1. Crear el superusuario. Se ejecuta dentro de un pod del backend, que ya tiene la configuración y la identidad; queda guardado en PostgreSQL y viaja en el respaldo:
   ```bash
   kubectl exec -it deployment/backend -n gymscreen -- python manage.py createsuperuser
   ```
2. Hacer el respaldo desde un pod de herramientas. `pg_dump` escribe en la salida estándar de `kubectl exec`, que transmite binarios sin alterarlos:
   ```bash
   kubectl run pg-herramientas -n default --restart=Never --image=postgres:18 \
     --env="PGPASSWORD=$DB_PASS" -- sleep 3600
   kubectl wait pod/pg-herramientas -n default --for=condition=Ready --timeout=2m
   kubectl exec pg-herramientas -n default -- \
     pg_dump -Fc --no-owner --no-acl "host=$PG_HOST user=tfm_app dbname=tfm sslmode=require" \
     > $TRABAJO/tfm.dump
   # Comprobación del archivo: lista su contenido sin restaurarlo
   kubectl exec -i pg-herramientas -n default -- pg_restore --list < $TRABAJO/tfm.dump | grep -c "TABLE DATA"
   kubectl delete pod pg-herramientas -n default
   ```
   El número de `TABLE DATA` coincide con el número de tablas de la aplicación y de Django.
3. Guardar la referencia de conteos y subir los dos archivos a S3:
   ```bash
   cp $TRABAJO/conteos.json $TRABAJO/conteos-referencia.json
   aws s3 cp $TRABAJO/tfm.dump s3://$BUCKET/$RESPALDO_CLAVE
   aws s3 cp $TRABAJO/conteos-referencia.json s3://$BUCKET/$CONTEOS_CLAVE
   aws s3api head-object --bucket $BUCKET --key $RESPALDO_CLAVE --query VersionId --output text
   aws s3api head-object --bucket $BUCKET --key $CONTEOS_CLAVE --query VersionId --output text
   ```
4. Anotar en la hoja de registro los dos `VersionId` (son `RESPALDO_VERSION` y `CONTEOS_VERSION` del recorrido B), la fecha de subida y los conteos. A partir de aquí no se vuelve a escribir en `prod/linea-base/` durante la serie (ver «Mismo respaldo en las tres repeticiones»).
5. Verificación: `aws s3api list-object-versions --bucket $BUCKET --prefix prod/linea-base/ --query "Versions[].{clave:Key, version:VersionId, ultima:IsLatest}" --output table` muestra los dos objetos con esas versiones.

## 15. Acceso al admin (fuera de la medición)
El admin de Django no se publica en el Gateway: desde fuera, `/admin/` llega al frontend. Solo se alcanza con un túnel temporal (`kubectl port-forward`) desde un equipo con credenciales del clúster. La seguridad la dan el acceso a Azure, el RBAC de Kubernetes y el login de Django.

1. Abrir el túnel al Service del backend (queda en primer plano):
   ```bash
   kubectl port-forward svc/backend 8000:8000 -n gymscreen
   ```
2. Entrar en `http://localhost:8000/admin/` desde el navegador con el superusuario del respaldo. Funciona porque `ALLOWED_HOSTS` de `prod` incluye `localhost` (requisito P1) y los estilos los sirve WhiteNoise desde la imagen.
3. Cerrar el túnel con `Ctrl+C` al terminar.

## 16. Destrucción (cronometrada aparte)
```bash
marca "16 inicio"
```
Borra el entorno y los cuatro objetos que viven en la capa base (ver Alcance). Las asignaciones de rol no se eliminan con el grupo de recursos: si se borran después de las identidades, quedan huérfanas (principal `Unknown`).

1. Borrar el registro A de Route 53. Para borrarlo hay que enviar el registro exacto, así que se lee primero:
   ```bash
   export REGISTRO_A=$(aws route53 list-resource-record-sets --hosted-zone-id $ZONA_DNS_ID \
     --query "ResourceRecordSets[?Name=='$HOST_PUBLICO.' && Type=='A'] | [0]" --output json)
   aws route53 change-resource-record-sets --hosted-zone-id $ZONA_DNS_ID \
     --change-batch "$(jq -nc --argjson r "$REGISTRO_A" '{Changes:[{Action:"DELETE",ResourceRecordSet:$r}]}')"
   ```
2. Borrar `DB_HOST` de App Configuration:
   ```bash
   az appconfig kv delete -n $APPCS_NOMBRE --key DB_HOST --label prod --auth-mode login --yes
   ```
3. Borrar las asignaciones de rol sobre la capa base. El `AcrPull` se quita con el clúster todavía en pie:
   ```bash
   az aks update -g $RG -n $AKS --detach-acr $ACR_ID
   az role assignment delete --assignee $IDENTIDAD_PRINCIPAL_ID --scope $KV_PROD_ID
   az role assignment delete --assignee $IDENTIDAD_PRINCIPAL_ID --scope $APPCS_ID
   ```
4. Borrar el grupo del entorno. Elimina la red, el clúster (y su grupo de nodos `MC_...`, con el balanceador y la IP pública del Gateway), el servidor PostgreSQL con su zona DNS privada y la identidad:
   ```bash
   az group delete -n $RG --yes
   ```
```bash
marca "16 fin"
```
5. Limpieza local (fuera del tiempo de destrucción):
   ```bash
   kubectl config delete-context $AKS
   kubectl config delete-cluster $AKS
   git restore k8s/overlays/prod/
   rm -f $TRABAJO/tfm.dump               # contiene los datos y el hash de la contraseña del superusuario
   ```
6. Verificación:
   - `az group exists -n $RG` devuelve `false`.
   - `scripts/inventario-recursos.sh` termina con código 0: no quedan recursos con entorno distinto de `base` ni servicios de costo activos (AKS, bases de datos, balanceadores). El script consulta Azure y AWS, así que necesita las dos sesiones iniciadas.
   - `dig +short @$NS_ZONA $HOST_PUBLICO A` no devuelve nada. Se consulta al servidor de la zona, no al resolutor local, para no dejar una respuesta negativa en su caché antes de la siguiente repetición (paso 0.5).
   - `az appconfig kv list -n $APPCS_NOMBRE --key DB_HOST --label prod --auth-mode login -o tsv` no devuelve nada.
   - Sin asignaciones del entorno ni huérfanas en la capa base: `az role assignment list --scope <ámbito> --query "[].{principal:principalName, tipo:principalType, rol:roleDefinitionName}" -o table` con `$ACR_ID`, `$KV_PROD_ID` y `$APPCS_ID` muestra solo las asignaciones creadas por Terraform en la capa base, sin la identidad del backend, sin el `AcrPull` del clúster y sin principales `Unknown`.
   - `git status --short` no muestra cambios en `k8s/overlays/prod/`.
7. Anotar en la hoja de registro el tiempo de destrucción (de «16 inicio» a «16 fin») y lo que haya quedado pendiente.

## Hoja de registro
Una fila por ejecución, con el resumen. El detalle de los tiempos de cada paso está en `$TRABAJO/marcas.tsv`, que se conserva junto a la hoja; la fila solo lo referencia.

| Campo | Contenido |
|---|---|
| Ejecución | `EJECUCION` y recorrido (A o B) |
| Estado | Completa o abortada (ver «Repetición que no llega al criterio») |
| Commit | `git rev-parse --short HEAD` del paso 0.4 |
| Imágenes | `TAG` |
| Versiones | Kubernetes real (paso 3.5), Envoy Gateway, cert-manager, PostgreSQL |
| Emisor | `letsencrypt-staging` o `letsencrypt-prod` |
| Respaldo | `RESPALDO_VERSION` y `CONTEOS_VERSION` |
| Marcas | Ruta del archivo `marcas.tsv` de la ejecución |
| Esperas externas | Duración de `espera-dns` y de `espera-certificado` |
| Tiempo total | De «1 inicio» a «13 fin» |
| Pasos manuales | Número total y por paso (definición en «Medición») |
| Errores | Paso, mensaje y acción tomada (definición en «Medición») |
| Criterio | Código HTTP y resultado del `diff` del paso 13 |
| Destrucción | De «16 inicio» a «16 fin», y resultado del inventario |

## Notas de seguridad
- No se guardan secretos en el repositorio. Los valores del overlay (ACR, URL de Key Vault, endpoint de App Configuration, client-id, nombre de host, emisor) no son secretos, pero son de la sesión o del dominio, y el paso 16 restaura los archivos.
- La contraseña de `pgadmin` solo existe en la variable de la sesión y en el servidor, que se destruye en el paso 16. No se anota en la hoja de registro.
- `DB_PASS` se pasa como variable de entorno a los pods temporales de `default`. Es visible para quien administre el clúster mientras el pod existe; los pods se borran al terminar.
- No usar `--debug` en los comandos `az` que llevan contraseñas (`az postgres flexible-server create`): el registro de depuración incluye el cuerpo de la petición con la contraseña. Ningún archivo de registro se guarda dentro del repositorio.
- El respaldo de S3 contiene los datos de la aplicación y el hash de la contraseña del superusuario. El bucket es privado, cifrado y con versionado (capa base de AWS). La copia local se borra en el paso 16.
- **Alcance de la identidad en App Configuration:** el almacén es único para `dev` y `prod`, y el rol `App Configuration Data Reader` permite leer todas las etiquetas. La identidad de `prod` puede leer las claves de `dev`, que son valores no sensibles (los secretos están en Key Vaults separados por entorno). Es una limitación aceptada del diseño de la capa base.
- El namespace `gymscreen` aplica la política Pod Security `restricted`. Los pods de la aplicación y los del desafío HTTP-01 de cert-manager la cumplen. Los pods temporales de PostgreSQL usan `default` porque la imagen `postgres` no la cumple.
- El admin solo se alcanza por `kubectl port-forward`; no hay ruta pública hacia él. `localhost` en `ALLOWED_HOSTS` no lo expone: el listener del Gateway solo acepta el nombre de host público.
