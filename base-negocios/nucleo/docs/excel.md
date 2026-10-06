# Excel de ida y vuelta (046_excel) — para la app

El servidor no lee ni escribe archivos Excel. **La app** convierte el `.xlsx` en JSON (y al revés) y llama:

| Función | Qué hace | Permiso |
|---|---|---|
| `exportar_plantilla(empresa, hoja)` | columnas + filas actuales | según la hoja (abajo) |
| `importar_vista_previa(empresa, hoja, filas)` | revisa cada fila; **no guarda nada** | `excel.importar` + el de cada fila |
| `importar_aplicar(empresa, hoja, filas, id_operacion, motivo)` | todo o nada; con UN error no guarda nada | `excel.importar` + el de cada fila |

`excel.importar`: dueño y admin (el dueño puede dárselo a otro puesto). El vendedor, el cajero y el contador no importan.
Por dentro se usan las funciones de siempre, así que cada fila pide además su permiso normal
(`productos.editar`, `productos.precios`, `terceros.editar`, `terceros.credito`, `inventario.carga_inicial`,
`ventas.saldo_inicial` / `compras.saldo_inicial`...). Un permiso que falta sale como error de esa fila.

## Formato

**`exportar_plantilla`** devuelve:
- `columnas`: `[{clave, titulo, editable, tipo, obligatorio, valores, descripcion}]`. Con esto la app arma el
  encabezado (usa `titulo`), pinta **azul** lo `editable` y **gris** lo demás, y llena la hoja **Instrucciones**
  (título, descripción y `valores` válidos de cada columna). `reglas` trae el texto general para esa hoja.
- `filas`: una por registro, con las claves de `columnas`. Montos en lempiras con 2 decimales (`15.00`),
  fechas `AAAA-MM-DD`, sí/no como `"Sí"` / `"No"`.
- `costos_ocultos`: true si el usuario no ve costos (las columnas de costo no vienen).

**`filas`** que se suben: lista de objetos con las mismas `clave` (no el título). Agregue `"fila": N` con el
número de fila real del Excel para que los errores lo digan bien (sin él: posición + 1, como si la fila 1 fuera el
encabezado). Ejemplo: `[{"fila": 2, "codigo": "TOR-001", "precio_venta": "16.50", "extra.marca": "Stanley"}]`.

Tipos de celda: `texto`; `codigo` (se pasa a mayúsculas; letras, números, `.` `_` `/` `-`); `monto` (lempiras,
número o texto como `"1,250.50"` o `"L 1250.50"`, máximo 2 decimales, sin negativos); `cantidad` (hasta 4 decimales);
`entero`; `numero`; `si_no` (`Sí`, `Si`, `No`, `true`, `false`, `1`, `0`); `fecha` (`AAAA-MM-DD`; la app convierte
las fechas de Excel); `lista` (uno de `valores`, sin importar mayúsculas).

**Respuesta de la vista previa y de aplicar:**
```json
{"hoja": "productos", "vista_previa": true, "aplicado": false,
 "resumen": {"filas": 10, "crear": 1, "actualizar": 2, "sin_cambios": 6, "error": 1},
 "errores": [{"fila": 2, "columna": "Precio de venta (L)", "mensaje": "el monto lleva máximo 2 decimales (centavos).",
              "texto": "Fila 2, columna \"Precio de venta (L)\": el monto lleva máximo 2 decimales (centavos)."}],
 "filas": [{"fila": 3, "accion": "actualizar", "llave": "TOR-001", "cambios": ["precio_venta", "extra.marca"]}],
 "documentos": [], "mensaje": "Hay 1 error(es). No se guardó nada: corrija y vuelva a subir."}
```
`accion`: `crear`, `actualizar`, `sin_cambios` o `error`. Al aplicar con éxito también: `importacion_id`, `numero`,
`documentos` (cargas iniciales o conteos creados) y `duplicado` (true si el `id_operacion` ya se aplicó: devuelve
lo mismo y no repite nada). El `motivo` (5 letras o más) queda en la bitácora y en el historial de precios.

## Reglas (todas las hojas)

- El **código es la llave**: con él se busca el registro; si no existe se crea uno nuevo.
- **Celda vacía conserva** el valor que ya había. **Nunca se borra** nada: para quitar, "Activo" = No.
- Las columnas **grises se ignoran** al subir (aunque las hayan cambiado). Una columna que no se reconoce es error.
- Una llave **repetida** en el mismo archivo es error ("ya viene en la fila 6").
- Máximo 5,000 filas por archivo.
- **Categorías y unidades que no existen = error claro** (decisión: no se crean solas desde la hoja de
  productos; las categorías se suben antes en su hoja y las unidades se crean en Ajustes). Así un error de
  escritura ("Ferreteria" sin tilde) no crea categorías repetidas.

## Hojas

**productos** — exportar: cualquier usuario de la empresa (costos solo con `inventario.costos`).
Editables: `codigo` (obligatorio), `codigo_barras`, `nombre` (obligatorio si es nuevo), `tipo` (bien/servicio, se
fija al crear), `categoria`, `subcategoria` (tercer nivel: `"Sub > Sub-sub"`), `unidad` (código), `se_vende_con_decimales`,
`impuesto` (código de la tabla de impuestos), `precio_venta` (como lo cobra), `precio_incluye_isv`, `existencia_minima`,
`activo` y un `extra.<clave>` por cada campo extra activo de la empresa.
Grises: `costo_promedio`, `valor_inventario`, `margen_porcentaje` (solo con costos), `existencia_total`, `precio_sin_isv`,
`precio_con_isv`, `ultima_venta`, `ultima_compra`.
Usuario restringido por sucursal (0.13.1): `existencia_total`, `valor_inventario` y `costo_promedio` solo con sus
bodegas; `ultima_venta` y `ultima_compra` de sus sucursales. En **clientes_proveedores** los saldos siguen el
criterio de `resumen_hoy` (ventas al crédito y compras de sus sucursales; sin saldos iniciales) y
`ultimo_cobro` es de sus sucursales. **existencias_iniciales** y **conteo_fisico** solo traen sus bodegas.
El precio cambia con `cambiar_precio_producto` (historial de precios con el motivo); "precio incluye ISV" pide `productos.precios`.

**clientes_proveedores** — exportar: `terceros.ver`. Editables: `codigo` (vacío = nuevo, el programa le pone
`T00012`; si viene vacío pero el RTN ya existe, se actualiza ese), `tipo` (cliente/proveedor/ambos: **solo agrega**
papeles, por defecto cliente), `tipo_persona`, `nombre`, `rtn`, `telefono`, `correo`, `direccion`, `limite_credito`,
`plazo_dias`, `activo`. Grises: `saldo_por_cobrar`, `vencido_por_cobrar`, `ultimo_cobro` (con `ventas.ver`),
`saldo_por_pagar`, `vencido_por_pagar`, `ultimo_pago` (con `compras.ver`). Desde 0.12.0 cada cliente y proveedor
tiene `codigo` (los que ya existían quedaron T00001, T00002... en el orden en que se crearon; no cambia).

**categorias** — exportar: cualquier usuario. Editables: `nombre` (obligatorio, sin `>`), `categoria_madre`
(vacío = principal; `"Ferretería"` o `"Ferretería > Tornillería"`; puede venir en una fila de arriba), `activo`.
Grises: `nivel`, `productos`.

**existencias_iniciales** — exportar: `inventario.carga_inicial` (trae los bienes activos x bodegas activas que
aún no tienen carga). Editables: `codigo`, `bodega` (obligatorios), `cantidad` (vacío = no se carga), `costo_unitario`
(L por unidad), `fecha` (vacío = inicio de la empresa). Grises: `nombre`, `unidad`, `sucursal`.
Se hace **una carga por bodega y fecha** con `cargar_saldo_inicial` (asiento contra Saldos de apertura).
**Una sola vez** por producto y bodega (repetir pide `inventario.carga_inicial_repetir`, solo el dueño).

**saldos_iniciales** — exportar: `ventas.saldo_inicial` o `compras.saldo_inicial` (solo el dueño). Editables:
`tipo` (cliente/proveedor), `codigo` (del cliente o proveedor), `documento` (obligatorios), `fecha_documento`,
`vencimiento` (vacío = + plazo), `monto`, `fecha` (del asiento; vacío = inicio de la empresa).
Grises: `nombre`, `saldo_pendiente`. Usa `registrar_saldo_inicial_cxc` / `_cxp`. Un documento ya cargado con
el mismo monto = sin cambios; con otro monto = error (anúlelo y vuelva a subirlo).

**conteo_fisico** — exportar: `inventario.ver`; **a ciegas** (no trae la existencia del sistema, como el arqueo).
Editables: `codigo`, `bodega`, `cantidad_contada` (vacío = no se contó). Grises: `nombre`, `unidad`.
**Nunca cambia la existencia**: por cada bodega con diferencias crea un `conteo_fisico` y una solicitud en
`aprobacion` (tipo `conteo_fisico`). La resuelve `resolver_aprobacion` (admin o dueño, `inventario.ajustar`; nadie
aprueba su propio conteo salvo el dueño; doble aprobación si la empresa la tiene). Al aprobar se hace
`ajustar_inventario` con la **diferencia** contada sobre la existencia de ese momento (si después del conteo se
vendió o trasladó, eso no se pierde). Ejemplo (prueba 127): sistema 100, contado 97 (−3); se trasladan 5 → 95;
al aprobar queda 92. Rechazar pide motivo y no mueve nada. Tabla `conteo_fisico` (lee quien tiene `inventario.ajustar`).

**Tablas nuevas:** `importacion_excel` (cada importación aplicada, con su resumen; lee `excel.importar`) y `conteo_fisico`.
