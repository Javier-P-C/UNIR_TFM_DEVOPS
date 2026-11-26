-- Rol y base de la aplicación. Lo ejecuta el administrador del servidor desde el Job de arranque-base-datos.tf.
-- Variables de psql: db_user, db_name, app_pass.
-- Idempotente: si el pod se reintenta tras un fallo parcial, no falla por objetos que ya existen.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'app_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')
\gexec

-- En PostgreSQL 16+ el administrador debe pertenecer al rol para asignarlo como dueño de la base
GRANT :"db_user" TO CURRENT_USER;

-- CREATE DATABASE no admite IF NOT EXISTS ni puede ir en un bloque DO
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')
\gexec

-- En Azure el dueño del esquema public es azure_pg_admin, no el dueño de la base:
-- sin este permiso las migraciones no pueden crear tablas
\connect :"db_name"
GRANT USAGE, CREATE ON SCHEMA public TO :"db_user";
