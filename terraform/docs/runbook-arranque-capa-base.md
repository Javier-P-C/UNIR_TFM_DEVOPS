# Runbook: arranque de la capa base

Este procedimiento es manual y queda fuera de las mediciones. Se ejecuta una sola vez por cuenta. Cada paso indica cómo verificarlo.

## 0. Requisitos
- Suscripción de Azure activa y cuenta de AWS, ambas con MFA.
- Presupuesto y alertas configurados a mano en cada nube (paso 1).
- Un usuario con rol Owner en la suscripción de Azure y uno con permisos de administrador en AWS. Son temporales y se reducen al final (paso 10).
- Repositorio de GitHub creado, con los entornos `dev` y `prod` (este con aprobación requerida).
- Instalados: Azure CLI, AWS CLI v2, Terraform y `gh`.
- Registrar en la hoja de registro: fecha, versiones usadas, tiempo y errores de cada paso.

## 1. Presupuesto y alertas
Los presupuestos no se definen en Terraform, por lo que se crean a mano antes de crear recursos.
1. Azure: en el portal, Cost Management > Budgets > Add. Crear un presupuesto mensual sobre la suscripción con alertas por correo (por ejemplo al 50 %, 80 % y 100 % del monto).
2. AWS: en la consola, Billing > Budgets > Create budget. Crear un presupuesto de costos mensual con alertas por correo con los mismos umbrales.
3. Confirmar en cada nube la suscripción al correo de alertas.
4. Verificación: ambos presupuestos aparecen listados y activos. Anotar el monto usado.

## 2. Preparar variables
1. Copiar el repositorio y editar `bootstrap/variables.sh`: `GITHUB_REPO`, regiones, `AWS_BUCKET_ESTADO` (sufijo único) y anotar `AZ_STORAGE`.
2. Verificación: `source bootstrap/variables.sh && env | grep -E "AZ_|AWS_"`.
3. Definir el subject de GitHub: los repositorios creados después del 15 de julio de 2026 emiten el token OIDC con los identificadores del propietario y del repositorio (`propietario@ID/repositorio@ID`). Los IDs se obtienen con `gh api repos/<propietario>/<repositorio> --jq '.owner.id, .id'` y se guardan en `github_repo_sujeto` de ambos `terraform.tfvars`. Si el repositorio es anterior a esa fecha y no activó el subject inmutable, `github_repo_sujeto` se omite.

## 3. Estado remoto
### 3.1 Azure
1. `az login` y `az account set --subscription <id>`.
2. Ejecutar `bootstrap/01-azure.sh`.
3. Si falla al crear el contenedor, asignar `Storage Blob Data Contributor` al usuario sobre la cuenta y repetir.
4. Verificación: `az storage container list --account-name $AZ_STORAGE --auth-mode login -o table` muestra `tfstate`.
5. Deshacer: `az group delete -n $AZ_RG_ESTADO` (solo si aún no hay estado guardado).

### 3.2 AWS
1. Iniciar sesión (`aws sso login` o credenciales temporales) y comprobar con `aws sts get-caller-identity`.
2. Ejecutar `bootstrap/02-aws.sh`.
3. Verificación: `aws s3api get-bucket-versioning --bucket $AWS_BUCKET_ESTADO` devuelve `Enabled`.
4. Deshacer: vaciar y eliminar el bucket (solo si aún no hay estado guardado).

## 4. Dominio y zona DNS
En el trabajo se simula la caída de la nube de Azure, por lo que el DNS se aloja en AWS (Route 53) para permitir la simulación de recuperación. El DNS requiere un proceso manual que empieza con la obtención de un dominio propio.

1. Comprar el dominio en un registrador externo. Terraform crea la zona de Route 53 (`base/aws/dns.tf`) y los servidores de nombres se copian después al registrador.
2. Confirmar el correo de contacto del dominio, ya que si no se confirma a tiempo el dominio puede suspenderse.
3. Agregar a `terraform.tfvars` de `base/aws/`: `dominio = "midominio.com"`.
4. La delegación de los servidores de nombres se hace después del apply del paso 5.

## 5. Aplicar la capa base de AWS
1. En `base/aws/`: copiar `backend.hcl.example` a `backend.hcl` y `terraform.tfvars.example` a `terraform.tfvars`, y completar los valores. `host_prod` es el nombre de host de producción (por ejemplo `app.midominio.com`) y debe ser el mismo que `host_por_entorno["prod"]` de Azure.
2. `terraform init -backend-config=backend.hcl`
3. `terraform plan -out=plan.tfplan` y revisar que solo cree: repositorios ECR, bucket de respaldos, proveedor OIDC, rol de GitHub, la zona de Route 53, dos secretos de Secrets Manager (`DJANGO_SECRET_KEY` y `DB_PASSWORD`) y cinco parámetros de Parameter Store.
4. `terraform apply plan.tfplan`
5. Anotar las salidas: `rol_github_arn`, `ecr_repositorios`, `bucket_respaldos`, `zona_dns_id`, `zona_dns_servidores_nombres`, `secretos_arn` y `prefijo_parametros`.
6. Verificación: `terraform plan` no muestra cambios; `aws ecr describe-repositories` lista los repositorios; `aws route53 list-hosted-zones` muestra la zona; `aws secretsmanager list-secrets` lista los dos secretos y `aws ssm get-parameters-by-path --path /tfm-unir/recuperacion` lista los cinco parámetros (sin `DB_HOST`, que escribe la capa de entorno).
7. Tomar los cuatro valores de `zona_dns_servidores_nombres` y pegarlos como servidores de nombres personalizados del dominio, en el panel del registrador. Con DNSSEC desactivado en el registrador.
8. Verificación de la delegación: `dig NS midominio.com` devuelve los cuatro servidores de nombres de Route 53. La propagación puede tardar desde minutos hasta unas horas; no continuar con pasos que dependan del DNS hasta que coincida.

## 6. Aplicar la capa base de Azure
1. En `base/azure/`: copiar `backend.hcl.example` a `backend.hcl` (con el nombre real de la cuenta) y `terraform.tfvars.example` a `terraform.tfvars`. Definir `host_por_entorno` con el nombre de host de `dev` y de `prod`.
2. `terraform init -backend-config=backend.hcl`
3. `terraform plan -out=plan.tfplan` y revisar: ACR, aplicación y entidad de servicio, credenciales federadas, asignaciones de rol, un App Configuration único, y por cada entorno un Key Vault con dos secretos y dos claves de configuración con la etiqueta del entorno, además de tres claves comunes sin etiqueta.
4. `terraform apply plan.tfplan`
5. Anotar las salidas: `github_client_id`, `tenant_id`, `suscripcion_id`, `acr_servidor`, `key_vault` y `app_configuration`. El apply incluye una espera de 60 segundos para que se propaguen los roles antes de escribir los secretos.
6. Si el apply falla al crear la aplicación en Azure AD, el usuario necesita el rol `Application Administrator` (o equivalente) en el directorio.
7. Verificación: `terraform plan` sin cambios; `az acr list -o table` muestra el registro; `az keyvault secret list --vault-name <nombre> -o table` lista `DJANGO-SECRET-KEY` y `DB-PASSWORD` de cada entorno; `az appconfig kv list --endpoint <endpoint> --auth-mode login --label '*' -o table` lista las tres claves comunes y las de cada etiqueta (`dev` y `prod`), sin `DB_HOST`.
8. Si el apply falla con 403 al escribir un secreto, esperar unos minutos y repetir `terraform apply`. Si se destruye la capa base y se vuelve a crear con el mismo nombre, el Key Vault puede quedar en borrado temporal; el proveedor está configurado para recuperarlo o purgarlo.

## 7. Variables en GitHub (sin secretos)
Con `gh variable set` en el repositorio o como variables de repositorio en la consola:
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- `AWS_ROLE_ARN`, `AWS_REGION`
- `ACR_SERVIDOR`, `ECR_URL_BACKEND`, `ECR_URL_FRONTEND`

Los valores salen de las salidas del apply en la capa base:
- Azure: `github_client_id`, `tenant_id`, `suscripcion_id` y `acr_servidor`.
- AWS: `rol_github_arn` y las URLs de `ecr_repositorios`. `AWS_REGION` es la que se usó.

## 8. Probar la autenticación
1. Ejecutar el workflow de prueba (`workflow_dispatch`, entorno `dev`).
2. Debe autenticarse en Azure con `azure/login` y en AWS con `aws-actions/configure-aws-credentials`, usando OIDC y sin credenciales fijas.
3. Verificación: `az account show` y `aws sts get-caller-identity` aparecen en el log con las identidades del proyecto.
4. Si falla la autenticación, revisar primero que los entornos de GitHub se llamen `dev` y `prod`, igual que en `entornos_github` de las variables de Terraform.
5. Si el error es `AADSTS700213` (Azure) o `Not authorized to perform sts:AssumeRoleWithWebIdentity` (AWS), el subject del token no coincide con la credencial federada o con la política de confianza. El error de Azure muestra el subject recibido. Debe copiarse tal cual, sin el prefijo `repo:` ni el sufijo `:environment:...`, en `github_repo_sujeto`, y volver a aplicar ambas capas bases.

## 9. Comprobar etiquetas
1. Todos los recursos creados llevan `proyecto`, `entorno=base` y `ejecucion=capa-base`.
2. Verificación en AWS: `aws resourcegroupstaggingapi get-resources --tag-filters Key=proyecto,Values=<proyecto>`. En Azure: `az resource list --tag proyecto=<proyecto> -o table`.

## 10. Cerrar el arranque
1. Retirar o reducir los permisos de los usuarios administradores temporales.
2. Anotar en la hoja de registro el tiempo total y los errores del arranque.
3. Guardar este runbook con los valores usados (sin contraseñas ni claves).

## Notas de seguridad
- No guardar claves ni contraseñas en el repositorio. `*.tfvars` y `*.tfstate` están en `.gitignore`.
- Los valores de `DJANGO_SECRET_KEY` y `DB_PASSWORD` se generan en Terraform, por lo que quedan en texto plano dentro del estado. El estado debe permanecer en el almacenamiento cifrado y con acceso restringido que crea el arranque.
- Los permisos del rol de GitHub (Contributor en Azure; PowerUserAccess y una política de IAM acotada en AWS) son amplios a propósito para el desarrollo; acotarlos cuando el diseño esté definido.