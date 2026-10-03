# Seguridad (006_seguridad)

- **anon** (sin sesión): no ve ni ejecuta nada.
- **authenticated**: solo LEE lo de sus empresas (RLS) y escribe solo por
  funciones (RPC) que revisan todo.
- **service_role** (llave del proveedor): lee todo, escribe solo `licencia`
  y crea empresas.
- Asientos, líneas y bitácora además piden `contabilidad.ver` / `bitacora.ver`.
- Toda tabla de `public` tiene RLS y no se puede vaciar (TRUNCATE).
- El rol proveedor no recibe permisos por la tabla rol x permiso.
- Solo del dueño (012): `soporte.otorgar`, `permisos.editar`,
  `periodos.reabrir`, `empresa.configurar`. Ningún otro rol los recibe.
- Inventario y compras (015, 016): costos, kardex, compras y CxP piden
  `inventario.costos` / `compras.ver` (financieros: el proveedor solo los
  lee con soporte). `v_existencia` muestra cantidades con `inventario.ver`
  y oculta costos a quien no tiene `inventario.costos`.
- `cambiar_permiso_rol(empresa, rol, permiso, otorgar, motivo)`: motivo
  obligatorio; al dueño no se le quita `permisos.editar`.
