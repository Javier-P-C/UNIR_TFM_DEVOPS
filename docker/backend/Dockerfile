# Imagen del backend: API de Django servida por Gunicorn.
# Se construye desde la raíz del repositorio (contexto de construcción):
#   docker build -f docker/backend/Dockerfile -t gymscreen-backend .
# Los archivos que se envían al build los limita Dockerfile.dockerignore (junto a este archivo).
#
# La instrucción ENV de Docker solo define variables de entorno. No tiene relación
# con la variable ENV de la aplicación (local|dev|prod), que esta imagen nunca fija:
# la pone el manifiesto de Kubernetes, así la misma imagen sirve en todos los entornos.

# ---- deps: dependencias de Python en un entorno virtual ----
FROM python:3.13.12-slim AS deps
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY backend/requirements.txt .
RUN pip install -r requirements.txt

# ---- static: reúne el CSS/JS del admin ----
# settings.py carga config.py, que falla sin configuración. Un env.local ficticio
# (valores falsos, sin secretos reales) existe solo en esta etapa para ejecutar
# collectstatic; la imagen final solo recibe la carpeta staticfiles/ resultante.
FROM deps AS static
WORKDIR /app/gymscreen
COPY backend/gymscreen/ .
RUN printf '%s\n' \
        'DJANGO_SECRET_KEY=collectstatic-only' \
        'DB_PASSWORD=unused' \
        'ALLOWED_HOSTS=localhost' \
        'DB_NAME=unused' \
        'DB_HOST=unused' \
        'DB_PORT=5432' \
        'DB_USER=unused' \
        'CORS_ALLOWED_ORIGINS=http://localhost' \
        > /app/env.local \
    && ENV=local python manage.py collectstatic --noinput

# ---- runtime: imagen final ----
FROM python:3.13.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    WEB_CONCURRENCY=2

# Usuario sin privilegios; UID numérico para que Kubernetes pueda verificar runAsNonRoot
RUN useradd --system --uid 10001 --no-create-home app

COPY --from=deps /opt/venv /opt/venv
# Misma estructura que el repositorio: config.py busca /app/env.local (= backend/env.local),
# que aquí no existe, así que un pod sin ENV=dev|prod falla al arrancar.
WORKDIR /app/gymscreen
COPY backend/gymscreen/ .
COPY --from=static /app/gymscreen/staticfiles ./staticfiles

USER 10001
EXPOSE 8000

# Comando por defecto. El Job de migraciones lo sustituye con `command:` en su manifiesto.
#   --preload            carga la aplicación (y su configuración) una vez, antes de crear
#                        los workers; un error de configuración detiene Gunicorn y el pod falla
#   --worker-tmp-dir     latidos de los workers en memoria; funciona con el sistema de
#                        archivos raíz en solo lectura
#   --access-logfile -   log de accesos a la salida estándar, como el resto de logs
# Workers: WEB_CONCURRENCY; opciones extra: GUNICORN_CMD_ARGS (ambas desde el manifiesto).
CMD ["gunicorn", "gymscreen.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--preload", \
     "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-"]
