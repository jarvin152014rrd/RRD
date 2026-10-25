# Catálogo de productos (014_productos) — módulo "inventario" o "ventas"

Desde 0.8.0 el catálogo (productos, categorías, unidades, campos extra y
precios) también se edita con solo el módulo "ventas" (negocio de solo
servicios, ver `modulos.md`). Bodegas y existencias siguen siendo de "inventario".

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

## Fotos de productos (0.17.0, migración 053)

Fotos livianas, con interruptor por empresa. **Apagado por defecto**: hasta que se enciende no se ve nada de fotos
(la app no muestra nada y Storage no deja leer ni subir).

- **Interruptor:** `empresa.fotos_productos`. Lo cambia el dueño con `activar_fotos_productos(empresa, true|false, motivo)`
  (`empresa.configurar`, motivo y bitácora; en la app: Ajustes > Mi negocio) o el proveedor con la ficha
  (`"opciones": {"fotos_productos": true}`; Armador o `aplicar_ficha`). `mi_perfil` lo devuelve en `empresa`.
- **El producto guarda la RUTA, no la imagen:** `foto_ruta` (unos 600 px) y `foto_miniatura_ruta` (unos 120 px), las
  dos `<empresa_id>/<producto_id>/<nombre>.webp|jpg` (el nombre: la huella del archivo). `v_producto` las devuelve.
- **`poner_foto_producto(empresa, producto, {"ruta","miniatura"} | null, id_operacion)`** (`productos.editar`, módulo de
  productos): poner o cambiar exige las fotos encendidas y rutas de ESTE producto (`FOTO_INVALIDA`, `FOTOS_APAGADAS`);
  `null` quita la foto (se puede siempre). Reintento con el mismo `id_operacion` = misma respuesta (`duplicado`).
  Cada cambio queda en `producto_foto` (foto nueva y la anterior; nunca se borra ni se edita) y en la bitácora del
  producto con motivo ("Poner o cambiar la foto del producto" / "Quitar la foto del producto"). Los archivos viejos
  NO se borran de Storage (el historial los nombra; la política de borrar no lo deja). Archivos sueltos (subidos sin
  llegar a guardarse, por ejemplo si se cerró la app a mitad) quedan hasta una limpieza futura (PENDIENTES).
- **Supabase Storage:** bucket PRIVADO `fotos-productos` (solo `image/webp` e `image/jpeg`, hasta 1 MB). Políticas
  en `storage.objects` (con los ayudantes `empresas_fotos_productos(accion)`, `ruta_foto_producto_valida(ruta)` y
  `foto_producto_en_uso(ruta)`; los dos últimos solo responden por empresas del usuario conectado):

| Política | Quién |
|---|---|
| `fotos_productos_leer` (SELECT) | usuarios de esa empresa (`mis_empresas`), con fotos encendidas |
| `fotos_productos_subir` (INSERT) | `productos.editar` en esa empresa, fotos encendidas, licencia vigente, módulo de productos y ruta de un producto suyo (lo mismo que `poner_foto_producto`) |
| `fotos_productos_cambiar` (UPDATE) | igual que subir |
| `fotos_productos_borrar` (DELETE) | `productos.editar` en esa empresa, fotos encendidas (apagadas no se ve nada, ni para borrar) y solo archivos que NO usa ningún producto (foto o miniatura actual) ni el historial `producto_foto` |

  Una empresa nunca ve ni sube en la carpeta de otra (la primera carpeta de la ruta es el id de la empresa).
  La 053 crea bucket y políticas por SQL si puede; si no, no falla: `estado_fotos_storage()` dice qué falta (revisa
  nombre, operación y que la regla llame al ayudante con su acción)
  (`verificar_instalacion.sql` lo muestra en la columna `fotos_productos`) y `docs/SUPABASE.md` explica los clics.
- **Lo impreso y el Excel no llevan fotos.** (La columna "tiene foto" en el Excel no se hizo: anotado en PENDIENTES.)
- Prueba 139 (políticas, permisos, interruptor, poner/cambiar/quitar, bitácora) y 140 (actualizar 0.16.0 -> 0.17.0).

## Precio mayorista (0.18.0, migración 054)

- Producto: `precio_mayorista_centavos` (opcional; se escribe igual que el precio de venta: con ISV si "precio
  incluye ISV" está en Sí) y `cantidad_mayorista` (opcional: desde cuántas unidades). Cliente: `tercero.es_mayorista`.
- `crear_producto` acepta las dos claves (con `productos.editar`). `editar_producto` también, pero cambiarlas pide
  `productos.precios` y motivo (como un cambio de precio; queda en la bitácora). `null` quita el mayorista.
- Reglas (trigger, por cualquier camino): el mayorista **nunca pasa el precio normal** (tampoco al bajar el normal con
  `cambiar_precio_producto`) y "desde cantidad" necesita el precio mayorista: `PRECIO_MAYORISTA_INVALIDO`.
- `crear_producto`, `editar_producto` y `cambiar_precio_producto` responden `"avisos"`: precio normal o mayorista (sin
  ISV) por debajo del costo promedio. Solo a quien ve costos; no impide guardar.
- Cliente mayorista: `crear_tercero` / `editar_tercero` con `"es_mayorista": true|false`; pide `productos.precios`
  (dueño y admin) porque cambia precios.
- `v_producto` agrega al final `precio_mayorista_centavos`, `cantidad_mayorista` y `precio_mayorista_con_isv_centavos`.
- Cómo se usa al vender: ver `ventas.md`, "Precio mayorista".
