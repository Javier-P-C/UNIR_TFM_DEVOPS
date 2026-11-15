# Capa base

Recursos que se crean una sola vez y no se destruyen con los entornos:
estado remoto, identidad OIDC de GitHub Actions, registros de contenedores (ACR y ECR),
almacenamiento de respaldos (S3). El presupuesto y las alertas se configuran a mano fuera de este código.

- `bootstrap/`: scripts del arranque manual (estado remoto).
- `base/azure/` y `base/aws/`: configuraciones de Terraform, cada una con su propio estado.
- `docs/runbook-arranque-capa-base.md`: procedimiento paso a paso.
- `docs/convencion-etiquetas.md`: etiquetas de todos los recursos.

Los entornos (desarrollo, producción, recuperación) vivirán en otra configuración con su propio estado
y solo referenciarán estos recursos con `data` sources, de modo que destruirlos no afecta a la capa base.
