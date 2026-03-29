# LosResis DB

Repositorio compartido de migraciones Supabase para:

- `losresis-app`
- `losresis-panel`

## Uso

Las migraciones viven en la raíz de este repositorio.

Cada proyecto incorpora este repo como submódulo en:

- `supabase/migrations`

## Flujo

1. Crear o editar la migración en este repositorio compartido.
2. Hacer commit y push aquí.
3. Actualizar el puntero del submódulo en `losresis-app` y/o `losresis-panel`.
