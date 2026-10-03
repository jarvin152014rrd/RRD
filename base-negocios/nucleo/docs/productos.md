# Catálogo de productos (014_productos) — módulo "inventario"

- **Unidades** (`unidad`): comunes para todos (UND, KG, G, LB, LT, ML, GAL,
  M, CAJA, PAQ, DOC, PAR) + propias de la empresa (`crear_unidad`).
- **Categorías** (`categoria_producto`): con madre opcional, hasta 3 niveles
  (`crear_categoria(empresa, nombre, madre?)`, `desactivar_categoria`).
- **Campos extra** (`campo_extra`): la empresa define campos propios para
  productos: `crear_campo_extra(empresa, clave, etiqueta, tipo, opciones?, obligatorio?)`.
  Tipos: texto, numero, entero, fecha (AAAA-MM-DD), si_no, lista (con opciones).
  Un valor `null` quita el campo. Solo se aceptan campos activos; los
  obligatorios activos se exigen al crear o editar. Error `CAMPO_EXTRA_INVALIDO`.
- **Productos** (`producto`): `codigo` interno (se guarda en mayúsculas) y
  `codigo_barras` opcional, ambos únicos por empresa; `nombre`, `categoria_id`,
  `unidad_id` (defecto UND), `tipo_impuesto` ISV15 / ISV18 / EXENTO (defecto
  ISV15), `precio_venta_centavos` (**sin ISV**), `stock_minimo`,
  `permite_fracciones`, `activo`, `campos_extra`.

| Función | Permiso |
|---|---|
| `crear_producto(empresa, datos, id_operacion)` | productos.editar |
| `editar_producto(empresa, producto, datos, motivo?)` (no cambia precio; `"activo"` true/false pide motivo) | productos.editar |
| `desactivar_producto(empresa, producto, motivo)` | productos.editar |
| `cambiar_precio_producto(empresa, producto, precio_centavos, motivo)` | productos.precios |
| `buscar_producto_por_codigo(empresa, codigo)` (en 015) | miembro de la empresa |

**Historial de precios** (`producto_precio`): precio anterior, nuevo, motivo,
usuario y fecha. Lo llena un trigger, así que ningún cambio se lo salta (ni
uno hecho por fuera de las funciones, que además exige motivo).

**Con movimientos de inventario** la unidad del producto ya no se cambia.

Permisos por defecto: dueño y admin. Vendedor y cajero solo leen el catálogo.
