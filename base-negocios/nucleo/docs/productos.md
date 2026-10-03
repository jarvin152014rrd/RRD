# Catálogo de productos (014_productos) — módulo "inventario"

- **Unidades** (`unidad`): comunes para todos (UND, KG, G, LB, LT, ML, GAL,
  M, CAJA, PAQ, DOC, PAR) + propias de la empresa (`crear_unidad`).
- **Categorías** (`categoria_producto`): con madre opcional, hasta 3 niveles
  (`crear_categoria(empresa, nombre, madre?)`, `desactivar_categoria`,
  `reactivar_categoria(empresa, categoria, motivo)`: la madre debe estar activa).
- **Campos extra** (`campo_extra`): la empresa define campos propios para
  productos: `crear_campo_extra(empresa, clave, etiqueta, tipo, opciones?, obligatorio?)`.
  Tipos: texto, numero, entero, fecha (AAAA-MM-DD), si_no, lista (con opciones).
  Un valor `null` quita el campo. Solo se aceptan campos activos; los
  obligatorios activos se exigen al crear o editar. Error `CAMPO_EXTRA_INVALIDO`.
  `desactivar_campo_extra` / `reactivar_campo_extra(empresa, campo, motivo)`.
- **Productos** (`producto`): `codigo` interno (se guarda en mayúsculas) y
  `codigo_barras` opcional, ambos únicos por empresa; `nombre`, `categoria_id`,
  `unidad_id` (defecto UND), `tipo_impuesto` ISV15 / ISV18 / EXENTO (defecto
  ISV15), `precio_venta_centavos` (guardado **tal como se escribe**),
  `precio_incluye_isv` (sí/no), `stock_minimo`, `permite_fracciones`,
  `activo`, `campos_extra`.

**Precio con o sin ISV (0.4.0):** `precio_incluye_isv` dice si el precio
escrito ya trae el ISV. Al crear, si no se indica, toma
`empresa.precio_incluye_isv_defecto` (true; lo cambia solo el dueño con
`configurar_empresa`). Productos creados antes de 0.4.0: false (eran sin ISV).
Cambiarlo en un producto (`editar_producto(..., {"precio_incluye_isv": false}, motivo)`)
pide `productos.precios` y motivo, y queda en el historial de precios.
Regla de cálculo (`public.precio_isv(precio, incluye, impuesto, cantidad)`),
por LÍNEA y redondeando a centavo (mitades hacia arriba):
- incluye ISV: con = cantidad x precio; sin = round(con / 1.15 ó 1.18); ISV = con − sin.
  Ej.: L 15.00 con ISV15 → sin ISV L 13.04, ISV L 1.96.
- no incluye: sin = cantidad x precio; ISV = round(sin x 0.15 ó 0.18); con = sin + ISV.
  Ej.: L 100.00 sin ISV15 → ISV L 15.00, con ISV L 115.00.
- Por línea: 3 x L 3.33 con ISV = L 9.99 → sin ISV L 8.69 (por unidad daría L 8.70).
Vista **`v_producto`**: `precio_sin_isv_centavos`, `isv_centavos`,
`precio_con_isv_centavos` (y `buscar_producto_por_codigo` los devuelve).

| Función | Permiso |
|---|---|
| `crear_producto(empresa, datos, id_operacion)` | productos.editar |
| `editar_producto(empresa, producto, datos, motivo?)` (no cambia precio; `"activo"` true/false pide motivo) | productos.editar |
| `desactivar_producto(empresa, producto, motivo)` | productos.editar |
| `cambiar_precio_producto(empresa, producto, precio_centavos, motivo)` | productos.precios |
| `buscar_producto_por_codigo(empresa, codigo)` (en 015) | miembro de la empresa |

**Historial de precios** (`producto_precio`): precio anterior, nuevo, si
incluía ISV antes y después (`incluye_isv_anterior/_nuevo`; vacío en filas de
antes de 0.4.0, que eran sin ISV), motivo, usuario y fecha. Lo llena un trigger, así que ningún cambio se lo salta (ni
uno hecho por fuera de las funciones, que además exige motivo).

**Con movimientos de inventario** la unidad del producto ya no se cambia, y
"se vende con decimales" no se apaga si hay existencias con decimales.

Permisos por defecto: dueño y admin. Vendedor y cajero solo leen el catálogo.

**0.7.0 — impuestos y servicios (ver `impuestos.md`):** `tipo_impuesto` es un código de la
tabla de impuestos de la empresa (en Honduras ISV15, ISV18, EXENTO, EXONERADO; sin indicarlo, el
predeterminado). Nuevo `"tipo": "bien" | "servicio"` y, en servicios, `"costo_estimado_centavos"`
(lo ve solo quien ve costos). Un servicio no lleva inventario.
