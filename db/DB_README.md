Version de postgresql instalado en WSL: `psql --version`

Encender servicio: `sudo service postgresql start`

Apagar servicio: `sudo service postgresql stop`

Entrar: `sudo -u postgres psql`

IP conexión
``SHOW listen_addresses;
SHOW port;``

# Crear la base de datos desde cero (ejecución manual)

Orden: **1)** crear la base de datos vacía en psql → **2)** crear las tablas con Django → **3)** cargar el catálogo.

No crear las tablas a mano con SQL: Django no las tendría registradas en `django_migrations` y `migrate` fallaría al intentar crearlas de nuevo.

## 1. Crear usuario y base de datos (psql)

`migrate` no crea la base de datos, solo las tablas dentro de ella.

```bash
sudo service postgresql start
sudo -u postgres psql
```

```sql
CREATE USER username WITH PASSWORD 'password';
CREATE DATABASE database_name OWNER username;
\q
```

Los valores deben coincidir con `DATABASES` en `backend/gymscreen/gymscreen/settings.py`.

## 2. Crear las tablas (Django)

Desde la carpeta `backend/gymscreen`:

```bash
python manage.py migrate
```

## 3. Cargar el catálogo de ejercicios

Desde la raíz del repositorio:

```bash
psql -h localhost -U username -d database_name -f db/seed_data.sql
```

El script vacía y vuelve a cargar el catálogo, así que se puede repetir. Usarlo en local y en dev, solo sobre una base recién creada o cuyo catálogo no se haya editado desde el admin. Nunca en prod: recibe el catálogo al restaurar su respaldo.

> **Nota:** `seed_data.sql` usa nombres de tabla fijos (`exercise`, `muscle_group`, `exercise_musclegroup`, ...). Los modelos de Django deben definir `db_table` con esos nombres; si no, el script falla con `relation "..." does not exist`.