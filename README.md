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

## Convención de nombres en base de datos

- A partir de ahora, todo lo que se cree en base de datos lleva **siempre el nombre en inglés**: tablas, columnas, funciones, triggers, índices, políticas RLS, enums y sus valores.
- Los objetos existentes con nombre en español no se renombran; conviven con la convención nueva.
- Los textos destinados al usuario final (títulos/cuerpos de notificaciones, mensajes de error visibles) siguen en español; la convención aplica solo a los identificadores.
