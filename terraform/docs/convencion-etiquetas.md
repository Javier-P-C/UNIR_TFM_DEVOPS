# Convención de etiquetas

| Etiqueta  | Valores                                              | Uso |
|-----------|------------------------------------------------------|-----|
| proyecto  | tfm-unir                                       | Identifica todo lo del trabajo |
| entorno   | base, desarrollo, produccion, recuperacion           | Qué parte lo gestiona |
| ejecucion | capa-base, o id de la sesión DD/MM/AAAA (por ejemplo 12-11-2026-a) | Permite localizar lo que quedó activo tras una sesión |

La capa base aplica estas etiquetas de forma automática (default_tags en AWS, locals en Azure).
Los entornos usan el mismo esquema con su valor de entorno y el id de ejecución.
