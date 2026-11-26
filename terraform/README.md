# Terraform

La infraestructura se divide en dos capas, cada una con sus propias configuraciones y estados remotos:

| Capa | Ciclo de vida | Configuraciones |
|---|---|---|
| Base | Se crea una sola vez y no se destruye con los entornos | `base/azure/`, `base/aws/` |
| Entorno | Se crea y se destruye en cada ciclo | `entorno/azure/infraestructura/` (y, más adelante, la de aplicación y las de `entorno/aws/`) |

La capa de entorno lee las salidas de la capa base con `terraform_remote_state` y no modifica sus recursos: solo añade asignaciones de rol y claves que se destruyen con el entorno, de modo que destruirlo no afecta a la capa base.

## Estructura
- `bootstrap/`: scripts del arranque manual (estado remoto).
- `base/azure/` y `base/aws/`: capa base, una configuración por nube.
- `entorno/`: capa de entorno, una carpeta por nube (`azure/`; `aws/` para el entorno de recuperación) y, dentro, una por configuración (`infraestructura/`; `aplicacion/` más adelante). Cada configuración tiene sus `modulos/` y una composición por entorno, con el nombre del entorno (`prod/`).
- `docs/`:
  - `runbook-arranque-capa-base.md`: arranque y aplicación de la capa base, paso a paso;
  - `runbook-capa-entorno-infraestructura.md`: crear, verificar y destruir la infraestructura de un entorno;
  - `convencion-etiquetas.md`: etiquetas de todos los recursos.

## Capa base
Recursos persistentes: estado remoto, identidad OIDC de GitHub Actions, registros de contenedores (ACR y ECR), almacenamiento de respaldos (S3), zona DNS (Route 53), Key Vault por entorno y un App Configuration único con etiquetas por entorno (Azure), y Secrets Manager y Parameter Store para la recuperación (AWS). El presupuesto y las alertas se configuran a mano fuera de este código.

- Estados: `base-azure.tfstate` y el de `base/aws/`, creados en el arranque (`bootstrap/`).
- Los recursos con datos o nombres difíciles de recrear (ACR, Key Vault, App Configuration…) llevan `prevent_destroy`.
- **No cambia durante las sesiones.** Ningún runbook ni workflow de entorno crea, modifica o borra recursos de la capa base fuera de su código. Su código solo cambia por decisión explícita, en su propia rama y con el plan revisado.
- Permisos de la identidad de GitHub en Azure: Contributor sobre la suscripción, y RBAC Administrator restringido por una condición a los roles que asigna la capa de entorno (`base/azure/main.tf`, plantilla `condicion-roles.tftpl`). Si la capa de entorno asigna un rol nuevo, hay que añadirlo a esa lista y aplicar la capa base antes.

## Capa de entorno: infraestructura (Azure)
`entorno/azure/infraestructura/`. Crea la infraestructura de un entorno: red, clúster AKS, PostgreSQL Flexible Server con la base de la aplicación preparada, e identidad del backend. Termina con un clúster vacío y una base lista, sin nada desplegado. Cómo aplicarla, verificarla y destruirla: `docs/runbook-capa-entorno-infraestructura.md`.

Es la primera de las dos configuraciones de la capa de entorno, cada una con su estado:

| Configuración | Estado remoto | Lee |
|---|---|---|
| Infraestructura | `entorno-<entorno>-infraestructura.tfstate` | La capa base (`base-azure.tfstate`) |
| Aplicación | `entorno-<entorno>-aplicacion.tfstate` | La de infraestructura y la capa base |

La dependencia va en un solo sentido: la de infraestructura no lee nada de la de aplicación.

El entorno es desechable: ningún recurso lleva `prevent_destroy`.

### Módulos y composición
- `modulos/red/`: grupo de recursos, VNet, subred del clúster, subred delegada a PostgreSQL y su NSG.
- `modulos/cluster/`: AKS, `AcrPull` del kubelet sobre el ACR y `Network Contributor` de la identidad del clúster sobre su subred.
- `modulos/base-datos/`: zona DNS privada con su enlace, servidor PostgreSQL y `DB_HOST` en App Configuration.
- `modulos/identidad/`: identidad administrada del backend, credencial federada y lectura de Key Vault y App Configuration.
- `prod/`: composición del entorno de producción. `prod.tfvars` tiene sus valores (sin secretos, confirmado en git) y `arranque-base-datos.tf` prepara la base.

Los módulos no contienen valores de ningún entorno: otro entorno es otra composición con los mismos módulos y su archivo de variables.

Las salidas de `prod/outputs.tf` son el contrato con la configuración de aplicación: cambiar su nombre o su significado obliga a cambiar también esa configuración.

### Orden de destrucción
**Primero la configuración de aplicación, después la de infraestructura.** La de aplicación borra el registro de Route 53, que está fuera de Azure, y hace el respaldo de producción a S3 con el servidor en pie. Además, sus recursos viven dentro del clúster: sin él, su `destroy` no puede conectarse. El balanceador y la IP pública del Gateway no quedan huérfanos, porque están en el grupo de nodos `MC_...`, que AKS borra con el clúster.

### Controles de seguridad
Son criterio de aceptación de esta capa. Cómo verificarlos: paso 5 del runbook.

| Control | Dónde |
|---|---|
| Base de datos sin acceso público | `modulos/base-datos`: subred delegada y `public_network_access_enabled = false` |
| Solo el 5432 desde la subred del clúster | `modulos/red`: NSG de la subred de la base. Permite TCP 5432 desde la subred del clúster y deniega el resto del tráfico de la VNet |
| Zona DNS privada | `modulos/base-datos`: zona enlazada a la VNet; el nombre del servidor solo resuelve desde dentro |
| Workload Identity sin credenciales estáticas | `modulos/identidad`: credencial federada para el ServiceAccount del backend. Sin secretos de cliente ni claves |
| OIDC issuer habilitado | `modulos/cluster`: `oidc_issuer_enabled` y `workload_identity_enabled` |
| Clúster sin claves SSH | `modulos/cluster`: sin `linux_profile` |

Además, el clúster descarga imágenes del ACR con `AcrPull` en la identidad del kubelet, sin secretos de registro. Las asignaciones de rol tienen como ámbito cada recurso, no la suscripción.

### Excepción: proveedor de Kubernetes
La configuración de infraestructura usa el proveedor de Kubernetes **solo** para el Job que prepara la base de datos (`prod/arranque-base-datos.tf`). Es una excepción deliberada a la separación entre infraestructura y aplicación:
- El rol de la aplicación, su base y el permiso en el esquema `public` forman parte de una base funcional, así que pertenecen a esta configuración.
- El servidor es privado y no se alcanza desde quien ejecuta Terraform. El SQL se ejecuta desde un pod dentro de la VNet, como en el paso 4 del runbook de la línea base (`k8s/docs/runbook-linea-base-produccion.md`).

Consecuencias:
- El proveedor se configura con las salidas de un clúster creado en la misma configuración. Funciona al crear y al destruir, pero si un cambio obliga a reemplazar el clúster, aplicar en dos pasos: primero `-target=module.cluster`, después el resto.
- El Job y su Secret quedan en el namespace `default` mientras exista el entorno. El Job no lleva TTL: si Kubernetes lo borrara, el siguiente plan lo volvería a crear.

### Etiquetas y nombres
- Etiquetas de `docs/convencion-etiquetas.md`. `ejecucion` registra la sesión que creó cada recurso: todos los recursos etiquetados llevan `ignore_changes = [tags["ejecucion"]]`, para que un plan de otra sesión no muestre diferencias y la detección de deriva siga siendo útil.
- El servidor PostgreSQL se llama `psql-<proyecto>-<entorno>-<sufijo>`, con un sufijo aleatorio que vive en el estado. Azure reserva durante un tiempo el nombre de un servidor borrado, así que un nombre fijo haría fallar la recreación. La sesión se identifica por la etiqueta `ejecucion`, no por el nombre.

### Notas de seguridad
- **Contraseñas en el estado.** El estado de la configuración de infraestructura contiene:
  - la contraseña de `tfm_app`, leída del Key Vault;
  - la del administrador `pgadmin`, generada en esa configuración;
  - las credenciales de cliente del clúster.

  El estado está en la cuenta de almacenamiento del arranque, con acceso por Azure AD y sin claves de la cuenta.
- **Contraseña de `tfm_app` en un Secret.** Pasa también por el Secret `arranque-base-datos` del namespace `default`. Es visible para quien administre el clúster mientras exista el entorno.
- **Contraseña de `pgadmin`.** Solo se usa en el Job. El servidor la recibe con `administrator_password_wo`, así que no queda en el recurso del servidor, pero sí en `random_password`.
- **La configuración de aplicación lee el estado de infraestructura completo** con `terraform_remote_state`, incluidos los valores sensibles: contraseñas y credenciales del clúster. Quien pueda ejecutar esa configuración puede leerlos.
- **Alcance de la lectura de App Configuration.** El almacén es único para `dev` y `prod`, y `App Configuration Data Reader` permite leer todas las etiquetas.
