# Seguridad (006_seguridad)

- **anon** (sin sesión): no ve ni ejecuta nada.
- **authenticated**: solo LEE lo de sus empresas (RLS) y escribe solo por
  funciones (RPC) que revisan todo.
- **service_role** (llave del proveedor): lee todo, escribe solo `licencia`
  y crea empresas.
- Asientos, líneas y bitácora además piden `contabilidad.ver` / `bitacora.ver`;
  clientes y proveedores, `terceros.ver` (financiero: el proveedor solo con soporte).
- Las políticas filtran con `empresa_id = ANY (ARRAY(SELECT empresas_con_permiso('...')))`:
  se calcula una vez por consulta, no por fila.
- Toda tabla de `public` tiene RLS y no se puede vaciar (TRUNCATE).
- El rol proveedor no recibe permisos por la tabla rol x permiso.
- Solo del dueño (012): `soporte.otorgar`, `permisos.editar`,
  `periodos.reabrir`, `empresa.configurar`. Ningún otro rol los recibe.
- Inventario y compras (015, 016): costos, kardex, compras y CxP piden
  `inventario.costos` / `compras.ver` (financieros: el proveedor solo los
  lee con soporte). `v_existencia` muestra cantidades con `inventario.ver`
  y oculta costos a quien no tiene `inventario.costos`.
- Dinero (022-024): cuentas de dinero, rastro, operaciones, pagos fijos,
  gastos y turnos piden `dinero.ver` (financiero); cada cajero ve sus turnos y
  cada quien los gastos, solicitudes y comprobantes que hizo. Aprobaciones:
  `aprobaciones.ver`. Las vistas no llaman funciones de `interno` (las
  ejecutaría el usuario); el nombre de un compañero sale de `nombre_usuario()`,
  que solo responde a alguien de la misma empresa.
- `cambiar_permiso_rol(empresa, rol, permiso, otorgar, motivo)`: motivo
  obligatorio; al dueño no se le quita `permisos.editar`; al contador solo se
  le dan permisos de lectura.
- **Usuario limitado a su sucursal (047, 052):** políticas RLS restrictivas `por_sucursal` en las tablas con
  sucursal, bodega o cuenta de dinero; desde 0.16.0 también líneas y pagos de compras, saldos iniciales de
  proveedor (solo sin restricción, `empresas_sin_restriccion()`) y la conciliación (`sucursales.md`).
- **Fotos de productos (053):** bucket privado `fotos-productos` en Supabase Storage (solo WEBP/JPEG, 1 MB). Políticas
  en `storage.objects`: leer = usuarios de esa empresa con fotos encendidas; subir/cambiar/borrar = `productos.editar`
  en esa empresa con fotos encendidas (subir además: licencia y módulo; borrar: solo archivos que nadie usa). La
  primera carpeta de la ruta es el id de la empresa. Ayudantes `empresas_fotos_productos(accion)` (una vez por
  consulta), `ruta_foto_producto_valida` y `foto_producto_en_uso`. Ver `productos.md`.
- **Límite honesto:** quien tiene la llave `service_role` o la clave
  `postgres` puede leer todo; eso se regula por contrato y bitácora
  (PROCEDIMIENTOS P-04).
