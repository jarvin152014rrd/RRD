# Usuarios, roles y contraseñas (010, 012)

**Quién hace qué (por defecto, desde 0.3.0):**
- **Dueño:** todo. SOLO él: cambiar permisos de roles (`permisos.editar`),
  reabrir meses (`periodos.reabrir`), acceso de soporte (`soporte.otorgar`),
  configurar la empresa (`empresa.configurar`: tope de crédito, inventario
  negativo) y administrar dueños. Estos permisos no se le pueden dar a otro
  rol (ni el dueño puede).
- **Admin:** agrega, cambia y desactiva usuarios **cajero y vendedor** (crear
  o desactivar administradores es solo del dueño); sucursales, cajas y bodegas;
  catálogos (categorías, unidades, campos extra, productos, precios,
  clientes y proveedores); límites de crédito hasta el tope del dueño;
  compras, pagos, ajustes y traslados. Nunca: nombrar o tocar dueños ni
  administradores, tocar al usuario del proveedor, ni dar un rol que tenga
  algún permiso que él no tiene (tampoco cambiar o desactivar a quien tenga
  un rol así; pasa si el dueño le da al cajero un permiso extra).
- **Cajero / vendedor:** ven cantidades de inventario (no costos), ven y
  registran clientes.
- **Contador (0.4.0):** solo lectura: contabilidad y reportes, bitácora,
  clientes y proveedores, compras y CxP, existencias **con costos y valor**
  (los necesita para el balance y el costo de ventas). No registra, no anula,
  no cierra meses, no administra usuarios. Solo el dueño lo crea, lo cambia
  o lo desactiva, y nadie le puede dar un permiso que mueva los libros.

`agregar_usuario_empresa(empresa, correo, rol, nombre?)` y
`desactivar_usuario_empresa(empresa, user_id, motivo)` (permiso
`usuarios.administrar`). La persona debe estar registrada en Supabase Auth.

**Contraseñas:** viven en Supabase Auth, nunca en estas tablas ni en SQL.
PENDIENTE (etapa de pantallas, no implementado): el alta de un usuario con
clave temporal y el "restablecer contraseña" se harán con una **Edge
Function** de Supabase que:
1. reciba el token del usuario que la llama;
2. verifique `tiene_permiso('usuarios.administrar', empresa)` (y las mismas
   reglas: no tocar dueños ni proveedor);
3. use la llave `service_role` SOLO dentro de la función (nunca en la app)
   para crear el usuario o enviar el correo de restablecimiento;
4. luego llame `agregar_usuario_empresa` y deje constancia en bitácora.
