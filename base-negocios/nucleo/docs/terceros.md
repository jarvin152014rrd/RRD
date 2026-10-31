# Clientes y proveedores (013_terceros)

**Una sola tabla `tercero`** para clientes y proveedores: `es_cliente`,
`es_proveedor` (puede ser los dos), `tipo_persona` (natural / juridica),
`nombre`, `rtn` (14 dígitos), `telefono` (8-15 dígitos), `correo`,
`direccion`, `limite_credito_centavos`, `plazo_dias` (0-365), `activo`.
Todo se liga por **id**, nunca por nombre (dos "Juan Pérez" son distintos).
El RTN no se repite dentro de la empresa. Desde 0.12.0 cada uno tiene `codigo` (T00001...; llave del Excel, no cambia; ver `excel.md`).

**RPC** (`datos` en jsonb; solo las claves que se quieren poner o cambiar):

| Función | Permiso |
|---|---|
| `crear_tercero(empresa, datos, id_operacion)` | terceros.editar |
| `editar_tercero(empresa, tercero, datos, motivo?)` | terceros.editar |
| `desactivar_tercero(empresa, tercero, motivo)` | terceros.desactivar |
| reactivar: `editar_tercero(..., {"activo": true}, motivo)` | terceros.desactivar |

Ejemplo de `datos`: `{"nombre":"Ferretería Lara","es_proveedor":true,"rtn":"0801-1999-000012","telefono":"9999-8888","plazo_dias":30}`.
El RTN y el teléfono aceptan guiones, espacios y paréntesis; se guardan solo dígitos.

**Crédito:** cambiar `limite_credito_centavos` o `plazo_dias` pide además
`terceros.credito`. Quien no es dueño no puede subir un límite por encima de
`empresa.tope_credito_centavos` (lo fija el dueño con `configurar_empresa`;
0 por defecto = solo el dueño da crédito). Error `TOPE_CREDITO`.

**Historial:** cada alta y cambio queda en la bitácora con el antes, el
después, quién y el motivo. Nunca se borra: se desactiva.

**Ver** (0.4.0): pide `terceros.ver` (financiero). Lo tienen dueño, admin,
cajero, vendedor y contador; el proveedor solo con acceso de soporte vigente.

**Permisos por defecto:** editar: dueño, admin, cajero, vendedor.
Crédito y desactivar: dueño y admin. En `crear_tercero`, un `id_operacion`
ya usado en otra operación que no es un tercero da `ID_OPERACION_USADO`.
