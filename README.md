# GymScreen

GymScreen es una aplicación web para entrenar en un gimnasio en casa. Hoy ofrece un catálogo de ejercicios que se puede explorar por grupo muscular, con la imagen, la descripción y videos de ejemplo de cada ejercicio. Las secciones de Rutinas, A entrenar e Historial están reservadas en la interfaz para próximas versiones.

La aplicación está pensada para desplegarse en Azure, sobre AKS, con un entorno local (`local`) y dos entornos en la nube (`dev` y `prod`).

## Descripción técnica

### Componentes

La aplicación tiene tres capas y depende de dos servicios gestionados de Azure para su configuración.

```
 Navegador
    │  HTML/JS estático
    ▼
┌──────────────────┐   HTTP/JSON    ┌───────────────────────┐   SQL    ┌──────────────┐
│ Frontend (SPA)   │ ─────────────► │ Backend API           │ ───────► │ PostgreSQL   │
│ React + Vite     │   /api/v1/     │ Django + DRF          │          │ (única capa  │
│ sin estado       │                │ sin estado            │          │  con estado) │
└──────────────────┘                └───────────────────────┘          └──────────────┘
                                         │ al arrancar
                                         ▼
                             Azure Key Vault (secretos)
                             Azure App Configuration (parámetros)
```

| Componente | Tecnología | Responsabilidad | ¿Guarda estado? |
|---|---|---|---|
| Frontend | React 19, TypeScript, Vite 8, Tailwind CSS 4, React Router 7 | SPA que consume la API. Se compila a archivos estáticos (`npm run build` → `dist/`). | No |
| Backend API | Python 3.13, Django 5.2, Django REST Framework 3.18 | API REST de solo lectura en `/api/v1/` y panel de administración (`/admin`) para editar el catálogo. | No. Todo el estado vive en la base de datos. |
| Base de datos | PostgreSQL 18 (en local y en Azure Flexible Server) | Catálogo de ejercicios, usuarios del admin, sesiones y el historial de migraciones. | **Sí** |
| Configuración | Azure Key Vault y Azure App Configuration (en local, el archivo `backend/env.local`) | Credenciales y parámetros por entorno (`ENV` = `local`, `dev` o `prod`). | Fuera de la aplicación |

Las partes que más importan para el despliegue:

- **Configuración centralizada y fail-fast** ([backend/gymscreen/gymscreen/config.py](backend/gymscreen/gymscreen/config.py)):
  - Al arrancar, el backend carga una sola vez toda su configuración en un diccionario de solo lectura (`CONFIG`).
  - Los secretos (`DJANGO_SECRET_KEY`, `DB_PASSWORD`) vienen de Key Vault. Key Vault no admite guion bajo en los nombres, así que se guardan como `DJANGO-SECRET-KEY` y `DB-PASSWORD`.
  - Los parámetros (`ALLOWED_HOSTS`, `DB_NAME`, `DB_HOST`, `DB_PORT`, `DB_USER`, `CORS_ALLOWED_ORIGINS`) vienen de App Configuration, filtrados por la etiqueta del entorno.
  - Una variable de entorno con el nombre de un parámetro lo sustituye; por ejemplo, `ALLOWED_HOSTS` en el ConfigMap de Kubernetes. Los secretos no se pueden sustituir así.
  - Si falta un valor o un servicio no responde, el proceso termina al iniciar en lugar de fallar más tarde en una petición. Así, un contenedor mal configurado no llega a quedar listo.
- **Autenticación hacia Azure sin credenciales en el código:**
  - El backend usa `DefaultAzureCredential`.
  - En AKS usa Workload Identity: los pods del backend y el Job de migraciones corren con la ServiceAccount `backend`, vinculada a una identidad administrada con permisos de lectura sobre Key Vault y App Configuration. En el clúster no se guarda ninguna credencial.
  - En local se usa la sesión de Azure CLI, si hace falta.
- **Esquema versionado:**
  - El esquema de la base lo definen los modelos de Django ([backend/gymscreen/exercises/models.py](backend/gymscreen/exercises/models.py)).
  - Se aplica con las migraciones versionadas en [backend/gymscreen/exercises/migrations/](backend/gymscreen/exercises/migrations/).
  - No se edita SQL a mano.
- **Frontend estático:**
  - Se compila a archivos estáticos que sirve nginx en su contenedor.
  - En el clúster, el frontend y la API comparten origen: el Gateway envía `/api/v1` al backend y el resto al frontend. Por eso el frontend llama a la ruta relativa `/api/v1`, no necesita CORS y la misma imagen sirve para todos los entornos.
  - En local, `VITE_API_URL` (en `.env.local`) apunta al backend en otro puerto.

### Dependencias

Las versiones están fijadas para que el entorno se pueda reconstruir de forma idéntica:

| Ámbito | Archivo | Contenido |
|---|---|---|
| Python | [backend/.python-version](backend/.python-version) | 3.13.12 |
| Paquetes Python | [backend/requirements.txt](backend/requirements.txt) | Versiones exactas (`==`) |
| Node.js | [frontend/gymscreen/.nvmrc](frontend/gymscreen/.nvmrc) | v24.21.0 |
| Paquetes npm | [frontend/gymscreen/package-lock.json](frontend/gymscreen/package-lock.json) | Árbol completo resuelto (`npm ci`) |
| Esquema de BD | `exercises/migrations/` | Historial de migraciones |
| Datos del catálogo | [db/seed_data.sql](db/seed_data.sql) | Carga de datos de referencia |

Dependencias del backend:

| Paquete | Uso |
|---|---|
| `Django` | Framework web, ORM, migraciones y admin |
| `djangorestframework` | API REST |
| `psycopg[binary]` | Driver de PostgreSQL; la variante `binary` incluye `libpq`, así que la imagen no necesita paquetes del sistema |
| `django-cors-headers` | Permite que el frontend, en otro origen, llame a la API (en local; en el clúster comparten origen) |
| `python-dotenv` | Lee `env.local` en el entorno local |
| `azure-identity` | Autenticación con Azure (Workload Identity / CLI) |
| `azure-keyvault-secrets` | Lectura de secretos |
| `azure-appconfiguration` | Lectura de parámetros |
| `gunicorn` | Servidor de aplicación en el contenedor (`runserver` es solo para desarrollo) |
| `whitenoise` | Sirve los archivos estáticos del admin cuando `DEBUG` está desactivado |

Servicios externos de los que depende la aplicación en ejecución:

- Azure Key Vault y Azure App Configuration, solo en `dev` y `prod`.
- YouTube y TikTok, para reproducir los videos de ejemplo. El navegador los incrusta directamente.
- Los servidores donde estén alojadas las imágenes de los ejercicios. La base guarda URLs completas.

### Recursos necesarios

| Recurso | Local | Nube (`dev` / `prod`) |
|---|---|---|
| Cómputo backend | Proceso `manage.py runserver` | Contenedor con Gunicorn en AKS (imagen `docker/backend`) |
| Frontend | Servidor de desarrollo de Vite (puerto 5173) | Contenedor con nginx en AKS (imagen `docker/frontend`), detrás del Gateway |
| Base de datos | PostgreSQL en WSL | PostgreSQL gestionado (p. ej. Azure Database for PostgreSQL) |
| Secretos | `backend/env.local` (no se sube al repositorio) | Azure Key Vault |
| Parámetros | `backend/env.local` | Azure App Configuration, con una etiqueta por entorno |
| Identidad | — | Identidad gestionada con acceso de lectura a Key Vault y App Configuration |
| Red | `localhost` | Acceso privado del backend a PostgreSQL (VNet) y a los servicios de Azure; entrada HTTP por un Gateway (Envoy) que reparte entre frontend y API |

La carga es ligera. El backend no guarda archivos en disco ni sesiones en memoria, así que puede escalar horizontalmente o reemplazarse sin perder información.

### Capa de datos: qué persiste

PostgreSQL es el **único componente con estado**. Todo lo demás se puede destruir y volver a crear a partir del repositorio y de la configuración en Azure.

Esta es la base, con los volúmenes actuales del entorno local:

| Tabla | Filas | Tipo de dato | Contenido |
|---|---|---|---|
| `muscle_group` | 10 | Referencia | Grupos musculares |
| `equipment` | 11 | Referencia | Aparatos y material (nombre, descripción, URL de imagen) |
| `exercise` | 79 | Referencia | Ejercicios (nombre, descripción, URL de imagen) |
| `exercise_video` | 86 | Referencia | URLs de videos de ejemplo por ejercicio |
| `exercise_musclegroup` | 87 | Referencia | Relación N:M ejercicio ↔ grupo muscular |
| `exercise_equipment` | 134 | Referencia | Relación N:M ejercicio ↔ equipo |
| `auth_user`, `auth_group`, `auth_permission` y sus tablas de relación | — | Operacional | Usuarios y permisos del panel de administración (contraseñas con hash) |
| `django_session` | — | Operacional | Sesiones abiertas en el admin |
| `django_admin_log` | — | Operacional | Bitácora de cambios hechos desde el admin |
| `django_content_type` | — | Sistema | Catálogo interno de modelos de Django |
| `django_migrations` | — | Sistema | Migraciones aplicadas; indica en qué versión está el esquema |

La integridad la garantiza la propia base:

- Claves foráneas con borrado en cascada desde `exercise` hacia sus videos y relaciones.
- Restricciones de unicidad en los nombres y en cada par de las tablas de relación.

Los datos son de dos tipos, y cada uno se recupera de forma distinta:

- **Datos de referencia (catálogo):**
  - Se pueden regenerar desde el repositorio: migraciones más `seed_data.sql`.
  - En `dev` y `prod` el catálogo se edita desde `/admin`. A partir de ese momento la fuente de verdad es la base de datos y no el script, por lo que también necesitan respaldo.
- **Datos operacionales:**
  - Hoy son los usuarios del admin, las sesiones y la bitácora.
  - No se pueden regenerar; solo se recuperan desde un respaldo.
  - Las secciones previstas (Rutinas, A entrenar, Historial) añadirán datos generados por los usuarios, como rutinas y entrenamientos realizados, que también son de este tipo. Con ellas crecerán el volumen y la importancia de la recuperación.

**Qué no está en la base de datos:**

| Elemento | Dónde está | Implicación para la recuperación |
|---|---|---|
| Secretos y parámetros | Key Vault y App Configuration | Al restaurar la base, las credenciales de Key Vault deben coincidir con las del servidor restaurado. |
| Imágenes de ejercicios y videos | Servicios externos; la base solo guarda la URL | No forman parte del respaldo. Si un enlace externo deja de existir, la interfaz muestra un placeholder o el botón "Ver video". |
| Imágenes de grupos musculares, logo y placeholder | Repositorio (`frontend/gymscreen/src/assets/`), incluidas en la compilación | Se recuperan al volver a compilar el frontend. |
| Código, esquema y datos iniciales | Repositorio Git | Se recuperan clonando el repositorio. |

### Reproducibilidad y recuperación

- **Arquitectura de tres capas en contenedores:** frontend estático, API sin estado y base relacional, más servicios gestionados de configuración. Tiene dependencias reales entre componentes (orden de arranque, conectividad, identidad, secretos) y, a la vez, es lo bastante acotada para desplegarla, destruirla y volver a crearla con facilidad.
- **El estado está concentrado en un solo punto.** Recuperar la aplicación se reduce a dos pasos:
  1. volver a desplegar los componentes sin estado desde el repositorio;
  2. restaurar PostgreSQL.

  El tiempo de reconstrucción de la infraestructura y el de restauración de datos se pueden medir por separado; juntos dan el tiempo total de recuperación (RTO). La pérdida de datos máxima (RPO) depende solo de la frecuencia de respaldo de PostgreSQL.
- **Todo lo necesario para reconstruir está versionado:** versiones del lenguaje, dependencias exactas, esquema como migraciones y datos iniciales como script. Dos despliegues desde el mismo commit deberían producir el mismo resultado.
- **Los errores de configuración se detectan al arrancar.** La carga fail-fast hace visible un despliegue incompleto (un secreto que falta, un servicio inaccesible) en el momento del arranque, y la plataforma puede reflejarlo como un contenedor que no queda listo.
- **La recuperación se puede verificar con criterios objetivos tras restaurar:**
  - las migraciones aplicadas en `django_migrations` coinciden con las del repositorio;
  - el número de filas por tabla coincide con el respaldo;
  - los endpoints responden con los mismos datos (por ejemplo, `exercise_count` de cada grupo muscular).
- **Hay dos estrategias de recuperación posibles,** porque conviven datos regenerables con datos que solo existen en la base:
  - volver a cargar el catálogo desde el script;
  - restaurar desde un respaldo, que es la única opción para los datos operacionales.

### Estado actual y pendientes para el despliegue en la nube

Implementado:

- API de solo lectura del catálogo.
- Panel de administración, accesible en el clúster solo mediante `kubectl port-forward`.
- Carga de configuración por entorno con Key Vault y App Configuration, con sustitución de parámetros por variables de entorno.
- CORS (solo necesario en local).
- Frontend con la sección de Ejercicios completa: grupos, lista por grupo y detalle con videos.
- Imágenes de contenedor del backend (Gunicorn, estáticos del admin con WhiteNoise) y del frontend (nginx), con usuario sin privilegios.
- Endpoints de salud para las sondas de Kubernetes: `/healthz` (proceso vivo) y `/readyz` (base de datos accesible).
- Logs a la salida estándar.
- Manifiestos de Kubernetes con Kustomize (base y overlay `dev`), Gateway API con Envoy Gateway y Job de migraciones.
- Runbook de despliegue de prueba en AKS: [k8s/docs/runbook-despliegue-prueba-aks.md](k8s/docs/runbook-despliegue-prueba-aks.md).

Pendiente:

- Capa de entorno en Terraform (red, AKS, PostgreSQL, identidad), que hoy se crean a mano según el runbook.
- Pipeline de CI/CD: construir y subir las imágenes, desplegar y esperar al Job de migraciones antes de actualizar el backend.
- Dominio y HTTPS en el Gateway.
- Carga automática del catálogo al crear `dev`, que nace sin datos operacionales pero con el catálogo. `prod` lo recibe al restaurar su respaldo. `seed_data.sql` vacía las tablas antes de insertar, así que no debe ejecutarse sobre una base cuyo catálogo se haya editado.
- Estrategia de respaldo y restauración de PostgreSQL.
- Entorno de recuperación en AWS (EKS).

## Puesta en marcha local

Requisitos: WSL Ubuntu con PostgreSQL, pyenv (Python 3.13.12) y nvm (Node v24.21.0).

**Backend** (`backend/`):

1. Crear `backend/env.local` con `DJANGO_SECRET_KEY`, `DB_USER`, `DB_PASSWORD`, `ALLOWED_HOSTS`, `DB_NAME`, `DB_HOST`, `DB_PORT` y `CORS_ALLOWED_ORIGINS` (p. ej. `http://localhost:5173`).
2. `python -m venv venv && source venv/bin/activate && pip install -r requirements.txt`
3. `cd gymscreen && python manage.py migrate`
4. Cargar el catálogo (ver [Base de datos](#base-de-datos)).
5. `python manage.py createsuperuser` (opcional, para `/admin`)
6. `python manage.py runserver`

Después de actualizar el repositorio, volver a ejecutar `pip install -r requirements.txt` con el entorno virtual activo: las dependencias cambian (por ejemplo, `gunicorn` y `whitenoise`).

**Frontend** (`frontend/gymscreen/`):

1. Crear `.env.local` con `VITE_API_URL=http://localhost:8000/api/v1`.
2. `npm ci`
3. `npm run dev`. La aplicación queda en `http://localhost:5173`.

## Backend

### Base de datos

El esquema lo manejan las migraciones de Django; los datos del catálogo están en `db/seed_data.sql`.

Base nueva:
1. `python manage.py migrate`
2. `psql -h localhost -U <usuario> -d <base> -f db/seed_data.sql`

Recargar el catálogo (solo local): vuelve a correr el paso 2. Vacía y recarga las tablas de ejercicios sin tocar usuarios ni migraciones.

Cambios de esquema: edita `models.py`, luego `python manage.py makemigrations exercises` y `python manage.py migrate`. No se edita SQL a mano.

### Endpoints

Base: `/api/v1/`. Todos son de solo lectura (`GET`) y públicos.

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/v1/equipment/` | Lista del equipo: `id`, `name`, `description`, `image`, `exercise_count` |
| GET | `/api/v1/equipment/{id}/` | Detalle de un aparato |
| GET | `/api/v1/muscle-groups/` | Lista de grupos musculares: `id`, `name`, `exercise_count` |
| GET | `/api/v1/muscle-groups/{id}/` | Detalle de un grupo muscular |
| GET | `/api/v1/exercises/` | Lista de ejercicios: `id`, `name`, `image`, `muscle_groups`, `equipment` |
| GET | `/api/v1/exercises/{id}/` | Detalle de un ejercicio; agrega `description` y `videos` |

Filtros de `/api/v1/exercises/` (combinables):

| Parámetro | Ejemplo | Descripción |
|---|---|---|
| `equipment` | `?equipment=3,5` | Ejercicios que usan cualquiera de esos aparatos |
| `muscle_group` | `?muscle_group=2,7` | Ejercicios que trabajan cualquiera de esos grupos |
| `search` | `?search=press` | Nombre contiene el texto (sin distinguir mayúsculas) |

Un id no numérico en `equipment` o `muscle_group` responde `400`.

## Frontend

| Ruta | Pantalla |
|---|---|
| `/ejercicios` | Catálogo con dos vistas: grupos musculares (`?vista=grupos`) o todos los ejercicios (`?vista=ejercicios`) |
| `/ejercicios/grupos/:id` | Ejercicios de un grupo muscular |
| `/ejercicios/:id` | Detalle del ejercicio: imagen, grupos, descripción y videos |
| `/rutinas`, `/entrenar`, `/historial` | Próximamente |

Videos: los enlaces de YouTube (`watch`, `shorts`, `youtu.be`) y los de TikTok con formato completo (`tiktok.com/@usuario/video/<id>`) se incrustan en la página. Cualquier otro enlace se muestra como un botón "Ver video" que abre una pestaña nueva.

## Contenedores y Kubernetes

| Carpeta | Contenido |
|---|---|
| [docker/backend/](docker/backend/) | `Dockerfile` (etapas: dependencias, `collectstatic`, imagen final con Gunicorn) y `Dockerfile.dockerignore` |
| [docker/frontend/](docker/frontend/) | `Dockerfile` (compilación con Node e imagen final con nginx sin privilegios), `nginx.conf` y `Dockerfile.dockerignore` |
| [k8s/cluster/](k8s/cluster/) | `GatewayClass` de Envoy Gateway; se aplica una vez por clúster |
| [k8s/base/](k8s/base/) | Namespace, backend, frontend, Gateway, HTTPRoute y Job de migraciones, comunes a todos los entornos |
| [k8s/overlays/dev/](k8s/overlays/dev/) | Imágenes, ConfigMap del backend e identidad del entorno `dev` |

Las imágenes se construyen desde la raíz del repositorio. Cada `Dockerfile.dockerignore` deja pasar solo lo necesario: `env.local`, `creds.txt` y cualquier `.env*` quedan fuera.

```bash
docker build -f docker/backend/Dockerfile  -t gymscreen-backend .
docker build -f docker/frontend/Dockerfile -t gymscreen-frontend .
```

La imagen del backend no fija `ENV`: lo pone el overlay de cada entorno. Sin configuración real, el contenedor falla al arrancar.

Para revisar los manifiestos de un entorno sin aplicarlos: `kubectl kustomize k8s/overlays/dev`.

Rutas en el clúster: el Gateway envía `/api/v1` al backend y el resto al frontend. El admin no se publica; se accede con `kubectl port-forward svc/backend 8000:8000 -n gymscreen` y `http://localhost:8000/admin/`.

El procedimiento completo de despliegue (red, clúster, base de datos, identidad, imágenes, carga del catálogo y destrucción) está en el [runbook de despliegue de prueba en AKS](k8s/docs/runbook-despliegue-prueba-aks.md).

## Infraestructura
La carpeta terraform contiene la infraestructura como código necesaria para levanta la aplicación en un clúster de Kubernetes en Azure con dos ambientes (dev y prod) y una solución de recuperación en AWS. La zona DNS se encuentra en AWS Route 53.

## Scripts
Es una carpeta con scripts auxiliares del proyecto. 
El script de inventario permite ver un listado de los recursos creados en AWS y Azure

## Conexión nube - github
### Entornos y variables en GitHub
Se crearon dos entornos en GitHub Actions, dev y prod. A partir de las salidas de la capa base se crearon variables de repositorio, que contienen identificadores y no secretos:
• Azure: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID y ACR_SERVIDOR.
• AWS: AWS_ROLE_ARN, AWS_REGION, ECR_URL_BACKEND y ECR_URL_FRONTEND.

La autenticación de GitHub Actions frente a Azure y AWS se configuró con OIDC, de modo que cada ejecución recibe un token temporal y no se guardan credenciales fijas en el repositorio. En Azure se creó una aplicación con una entidad de servicio y credenciales federadas para los entornos dev y prod y para los pull requests. En AWS se creó el proveedor OIDC de GitHub y un rol cuya política de confianza limita el acceso al repositorio y a esos mismos entornos.

## Mejoras futuras
- Implementar una fecha de creacion y última actualización en las tablas de equipo y ejercicios
- Hacer que los ejercicios tengan su nombre en inglés y en españo dentro de la base de datos
- Se puede plantear la idea de filtrar los ejercicios por equipo en la sección de Ejercicios
- Usar un proveedor externo de DNS que no dependa de AWS o Azure
- Añadir workflow para apagar la base de datos

