# Inventario y kardex (015_inventario) — módulo "inventario"

**Bodegas** (`bodega`): de una sucursal, código único por empresa.
`crear_bodega(empresa, sucursal, codigo, nombre)`; `desactivar_bodega(empresa, bodega, motivo)`
solo si está vacía. Permiso `bodegas.administrar` (dueño, admin).
No se crean solas: cree al menos una antes de comprar.

**Kardex** (`inventario_movimiento`): solo agregar. Tipos entrada, salida,
ajuste, traslado; `origen` dice de dónde vino (compra, anulacion_compra,
ajuste, traslado, carga_inicial). Cada fila guarda el saldo que dejó en su
bodega. Cantidad con signo (+ entra, − sale), hasta 4 decimales.

**Saldos** (`inventario_saldo`): cantidad, valor (centavos) y costo
promedio (centavos por unidad, 6 decimales) por producto y bodega. Se
actualiza en la misma transacción que el movimiento, con la fila bloqueada.

**Costo promedio ponderado:**
- Entrada de q a valor v: cantidad += q; valor += v; promedio = valor / cantidad.
- Salida de q: sale round(q × promedio); si la bodega queda en 0 sale TODO el
  valor (sin centavos sueltos). El promedio no cambia.
- Ejemplo: 100 a L 10.00 + 50 a L 13.00 = 150 por L 1,650.00 → promedio L 11.00.
- El orden del kardex es el orden en que se registra (no la fecha).

**Existencia negativa:** no se permite, salvo que el dueño la active para
la empresa (`configurar_empresa`, `permite_existencia_negativa`) o el
usuario tenga `inventario.negativo` (solo dueño por defecto). Si pasa,
queda una fila en `inventario_alerta`. La anulación de compras nunca deja
negativo.

| Función | Qué hace | Permiso |
|---|---|---|
| `ajustar_inventario(empresa, bodega, fecha, lineas, motivo, id_operacion)` | conteo físico: `[{"producto_id","cantidad_contada","costo_unitario"?}]`. Faltante: Dr 5.1.01.02 / Cr 1.1.03.01. Sobrante: Dr 1.1.03.01 / Cr 4.2.01.02 | inventario.ajustar |
| `trasladar_inventario(empresa, origen, destino, fecha, lineas, id_operacion, nota?)` | `[{"producto_id","cantidad"}]`, sale a costo promedio y entra con ese valor. Sin asiento | inventario.trasladar |
| `cargar_saldo_inicial(empresa, bodega, fecha, lineas, id_operacion, motivo?)` | `[{"producto_id","cantidad","costo_unitario"}]`. Dr 1.1.03.01 / Cr 3.1.01.01. Una vez por producto y bodega; repetir pide `inventario.carga_inicial_repetir` y motivo | inventario.carga_inicial |
| `buscar_producto_por_codigo(empresa, codigo)` | para escáner o cámara: busca por código de barras y luego por código interno; `{"encontrado":false}` si no hay | miembro |

Ajustes, traslados y cargas quedan en `inventario_documento` (+ líneas), con
número propio por tipo. Todas usan `id_operacion` (reintento = mismo
documento) y el candado de la empresa.

**Lectura:**
- `v_existencia`: cantidades por bodega con `bajo_minimo`. Pide
  `inventario.ver`; costo y valor salen vacíos sin `inventario.costos`.
  Es una vista "del sistema" (no security_invoker) para poder ocultar esas
  columnas; filtra con `puede_leer()`.
- `v_kardex`: movimientos con saldo por bodega y saldo acumulado del
  producto en todas las bodegas. Pide `inventario.costos`.

**Cuadre con la contabilidad:** el valor del kardex es igual al saldo de
1.1.03.01. Por eso, con el módulo activo, esa cuenta no acepta asientos
manuales (`CUENTA_CONTROLADA`) y los asientos de un módulo no se anulan con
`anular_asiento` (se anulan desde su documento). Cuentas en
`interno.cuenta_sistema`.

Permisos por defecto: ver cantidades: dueño, admin, cajero, vendedor. Ver
costos, ajustar, trasladar, carga inicial: dueño y admin. Negativo y
repetir carga: solo dueño.
