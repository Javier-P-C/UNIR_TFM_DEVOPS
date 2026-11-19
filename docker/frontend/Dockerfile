# Imagen del frontend: SPA de React compilada con Vite y servida por nginx.
# Se construye desde la raíz del repositorio (contexto de construcción):
#   docker build -f docker/frontend/Dockerfile -t gymscreen-frontend .
# Los archivos que se envían al build los limita Dockerfile.dockerignore (junto a este archivo).
#
# Ningún archivo .env* entra al build, así que VITE_API_URL no está definida y la
# aplicación llama a /api/v1 en el mismo origen: la misma imagen sirve en todos los entornos.

# ---- build: compila la aplicación en dist/ ----
# Misma versión de Node que frontend/gymscreen/.nvmrc. glibc (no Alpine) porque algunas
# dependencias traen binarios nativos. Esta etapa no llega a la imagen final.
FROM node:24.21.0-slim AS build
WORKDIR /app

# Primero las dependencias: esta capa queda en caché mientras no cambie el lockfile
COPY frontend/gymscreen/package.json frontend/gymscreen/package-lock.json ./
RUN npm ci

COPY frontend/gymscreen/ .
RUN npm run build

# ---- runtime: imagen final ----
# Rama estable de nginx; la variante sin privilegios corre como usuario 101 y escucha en el 8080
FROM nginxinc/nginx-unprivileged:1.30.6-alpine

COPY docker/frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
# El CMD se hereda de la imagen de nginx
