# Inventario y kardex (015_inventario) — módulo "inventario"

**Bodegas** (`bodega`): de una sucursal, código único por empresa.
`crear_bodega(empresa, sucursal, codigo, nombre)`; `desactivar_bodega(empresa, bodega, motivo)`
solo si está vacía (sin cantidad ni valor); `reactivar_bodega(empresa, bodega, motivo)`
(su sucursal debe estar activa). Permiso `bodegas.administrar` (dueño, admin).
Una sucursal con existencias en alguna de sus bodegas tampoco se desactiva.
No se crean solas: cree al menos una antes de comprar.

**Kardex** (`inventario_movimiento`): solo agregar. Tipos entrada, salida,
ajuste, traslado y `ajuste_costo` (0 unidades, solo valor); `origen` dice de
dónde vino (compra, anulacion_compra, ajuste, traslado, carga_inicial,
anulacion_ajuste, anulacion_traslado, anulacion_carga_inicial, ajuste_costo).
Cada fila guarda el saldo que dejó en su bodega. Cantidad con signo (+ entra,
− sale), hasta 4 decimales.

**Saldos** (`inventario_saldo`): cantidad, valor (centavos) y costo
promedio (centavos por unidad, 6 decimales) por producto y bodega. Se
actualiza en la misma transacción que el movimiento, con la fila bloqueada.

**Costo promedio ponderado:**
- Entrada de q a valor v: cantidad += q; valor += v; promedio = valor / cantidad.
- Salida de q: sale round(q × promedio); si la bodega queda en 0 sale TODO el
  valor (sin centavos sueltos). El promedio no cambia.
- Ejemplo: 100 a L 10.00 + 50 a L 13.00 = 150 por L 1,650.00 → promedio L 11.00.
- El orden del kardex es el orden en que se registra (no la fecha). Por eso
  una ENTRADA no puede tener fecha anterior a la última salida de ese
  producto en esa bodega (`ENTRADA_FECHA_ATRASADA`). Con el permiso
  `inventario.fecha_atrasada` (solo dueño) sí entra, y el efecto es: el
  costo nuevo cuenta desde el momento en que se registra; las salidas ya
  hechas NO se recalculan. Ejemplo: 10 a L 10.00, salen 4 el 10/01 (L 40.00),
  entran 4 a L 15.00 el 10/01 → 10 por L 120.00 (promedio L 12.00); el dueño
  registra 10 a L 13.00 con fecha 08/01 → 20 por L 250.00 (L 12.50) y la
  salida del 10/01 sigue en L 40.00.
- **0 unidades = L 0.00.** Si una bodega queda en 0 con valor (pasa al salir
  de negativo), el valor que sobra se lleva a 5.1.01.02 con una línea
  `ajuste_costo` y su asiento. Ejemplo: −3 lb por −L 60.00; entran 3 lb a
  L 25.00 = L 75.00 → quedaría 0 lb con L 15.00 → ajuste: Dr 5.1.01.02 L 15.00 /
  Cr 1.1.03.01 L 15.00, y queda 0 / L 0.00.

**Existencia negativa:** no se permite, salvo que el dueño la active para
la empresa (`configurar_empresa`, `permite_existencia_negativa`) o el
usuario tenga `inventario.negativo` (solo dueño por defecto). Si pasa,
queda una fila en `inventario_alerta`. La anulación de compras nunca deja
negativo.

| Función | Qué hace | Permiso |
|---|---|---|
| `ajustar_inventario(empresa, bodega, fecha, lineas, motivo, id_operacion)` | conteo físico: `[{"producto_id","cantidad_contada","costo_unitario"?}]`. Faltante: Dr 5.1.01.02 / Cr 1.1.03.01. Sobrante: Dr 1.1.03.01 / Cr 4.2.01.02 | inventario.ajustar |
| `trasladar_inventario(empresa, origen, destino, fecha, lineas, id_operacion, nota?)` | `[{"producto_id","cantidad"}]`, sale a costo promedio y entra con ese valor. Sin asiento | inventario.trasladar |
| `cargar_saldo_inicial(empresa, bodega, fecha, lineas, id_operacion, motivo?)` | `[{"producto_id","cantidad","costo_unitario"}]`. Dr 1.1.03.01 / Cr 3.3.01.03 Saldos de apertura (hasta 0.3.0 era 3.1.01.01). Una vez por producto y bodega (una carga anulada no cuenta); repetir pide `inventario.carga_inicial_repetir` y motivo | inventario.carga_inicial |
| `anular_documento_inventario(documento, motivo, id_operacion, fecha?)` | anula una carga inicial, un ajuste o un traslado. Solo si después no hubo movimientos de esos productos en esas bodegas (`MOVIMIENTOS_POSTERIORES`). Cada movimiento vuelve por el mismo valor; contra-asiento enlazado (la carga vuelve contra la cuenta de apertura que usó, nunca contra gasto; el traslado no lleva asiento). Fecha por defecto hoy, nunca antes del documento; mes abierto; una vez | inventario.anular + el del tipo (ajustar / trasladar / carga_inicial) |
| `buscar_producto_por_codigo(empresa, codigo)` | para escáner o cámara: busca por código de barras y luego por código interno; `{"encontrado":false}` si no hay | miembro |

Ajustes, traslados y cargas quedan en `inventario_documento` (+ líneas), con
número propio por tipo; su anulación en `inventario_documento_anulacion`.
Todas usan `id_operacion` (reintento = mismo documento; si el id es de otro
tipo de operación: `ID_OPERACION_USADO`) y el candado de la empresa.
Las respuestas traen los montos en null (`"costos_ocultos": true`) a quien no
tiene `inventario.costos`.

**Lectura:**
- `v_existencia`: cantidades por bodega con `bajo_minimo`. Pide
  `inventario.ver`; costo y valor salen vacíos sin `inventario.costos`.
  Es una vista "del sistema" (no security_invoker) para poder ocultar esas
  columnas; filtra con `empresas_con_permiso()` (una vez por consulta).
- `v_kardex`: movimientos con saldo por bodega y saldo acumulado del
  producto en todas las bodegas. Pide `inventario.costos`.

**Cuadre con la contabilidad:** el valor del kardex es igual al saldo de
1.1.03.01. Por eso, con el módulo activo, esa cuenta no acepta asientos
manuales (`CUENTA_CONTROLADA`) y los asientos de un módulo no se anulan con
`anular_asiento` (se anulan desde su documento). El módulo no se activa si
1.1.03.01 ya tiene saldo que el kardex no explica (`MODULO_CON_SALDO`, ver
PROCEDIMIENTOS P-07). Cuentas en `interno.cuenta_sistema` (y, si una empresa
ya usaba 3.3.01.03, su código propio en `interno.cuenta_sistema_empresa`).

Permisos por defecto: ver cantidades: dueño, admin, cajero, vendedor,
contador. Ver costos: dueño, admin, contador. Ajustar, trasladar, carga
inicial, anular documentos: dueño y admin. Negativo, repetir carga y
entradas con fecha atrasada: solo dueño.
