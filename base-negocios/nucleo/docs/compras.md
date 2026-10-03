# Compras y cuentas por pagar (016_compras) — módulo "compras"

Necesita también el módulo "inventario" activo.

**`registrar_compra(empresa, datos, id_operacion)`** (compras.registrar). Todo o nada:
documento + entradas al kardex + asiento.
```json
{"proveedor_id":"...","bodega_id":"...","numero_documento":"000-001-01-00001234",
 "fecha":"2026-01-15","condicion":"credito","fecha_vencimiento":"2026-02-14",
 "lineas":[{"producto_id":"...","cantidad":10,"costo_unitario":1250.5}]}
```
- Contado: `"condicion":"contado","forma_pago":"caja"|"banco"` y, si se quiere,
  `"cuenta_pago":"1.1.01.04"` (qué caja o banco: subcuenta de detalle activa de 1.1.01).
  Sin ella: caja = 1.1.01.01, banco = 1.1.01.03. La anulación devuelve a la misma cuenta.
- Crédito: vence en `fecha_vencimiento` o en fecha + plazo del proveedor.
- Línea: subtotal = round(cantidad × costo_unitario); ISV = round(subtotal × 15% / 18%)
  según el producto (EXENTO = 0). Se puede mandar `"isv_centavos"` para cuadrar
  con la factura (entre 0 y el subtotal).
- Asiento: Dr 1.1.03.01 Inventario (subtotal), Dr 1.1.04.01 ISV crédito fiscal
  (ISV) / Cr 1.1.01.01 Caja o 1.1.01.03 Bancos (contado) o 2.1.01.01 Proveedores (crédito).
- La misma factura del mismo proveedor no entra dos veces (salvo anulada).
- Ejemplo: 10 × 1250.5 = 12,505 + ISV 1,876 = 14,381 centavos.
- Devuelve subtotal, ISV y total de la FACTURA (los escribió quien registra y
  debe cuadrarlos con el papel). No devuelve costos promedio del kardex.

**`anular_compra(compra, motivo, id_operacion, fecha?)`** (compras.anular):
cada línea sale del kardex a lo que costó; contra-asiento enlazado al
original. Se rechaza si dejaría existencia negativa, si ya se anuló o si
la compra tiene pagos VIGENTES (anúlelos antes con `anular_pago_proveedor`).
Si la bodega queda vacía sale todo su valor y la diferencia contra el costo
original va a 5.1.01.02 (ajuste de costo; sale en null a quien no tiene
`inventario.costos`). Fecha por defecto: hoy (nunca antes de la compra).

**`pagar_proveedor(empresa, documento, monto_centavos, fecha, forma_pago, id_operacion, referencia?, cuenta_pago?, cuenta_dinero_id?)`**
(compras.pagar): abono a una compra al crédito o a un saldo inicial
(`documento` = `documento_id` de `v_cxp_documento`). Nunca más que su saldo
(`PAGO_EXCEDE_SALDO`; los pagos anulados no cuentan). Asiento Dr 2.1.01.01 /
Cr la cuenta de pago (caja, bancos o la subcuenta indicada, ej. "Banco Atlántida").

**`anular_pago_proveedor(pago, motivo, id_operacion, fecha?)`** (compras.anular):
contra-asiento Dr la MISMA cuenta de dinero del pago / Cr 2.1.01.01, enlazado
al asiento del pago. Fecha por defecto hoy, nunca antes del pago; mes
abierto; una sola vez (`YA_ANULADO`); queda en `pago_proveedor_anulacion` y en
la bitácora. La factura recupera el saldo. Ejemplo: compra 115,000; pagos
40,000 (caja) y 30,000 (Atlántida); se anula el de 30,000 → el Atlántida
vuelve a 0 y la factura debe 75,000.

**Saldos iniciales (facturas pendientes al empezar)** (`compras.saldo_inicial`, solo dueño):
- `registrar_saldo_inicial_cxp(empresa, datos, id_operacion)` con
  `{"proveedor_id","numero_documento","fecha_documento","fecha_vencimiento"?,"monto_centavos","fecha"?,"notas"?}`.
  `fecha` es la del asiento (si falta: inicio de la empresa) y no puede ser
  anterior a la factura. Vencimiento por defecto: factura + plazo del proveedor.
  Asiento Dr 3.3.01.03 Saldos de apertura / Cr 2.1.01.01. La misma factura
  del mismo proveedor no entra dos veces (ni como compra).
- `anular_saldo_inicial_cxp(saldo_inicial, motivo, id_operacion, fecha?)`: solo
  sin pagos vigentes; contra-asiento a la misma cuenta de apertura.
- Salen en las vistas de CxP y antigüedad; se pagan con `pagar_proveedor`.

**Lectura** (piden `compras.ver`; el nombre del proveedor sale con `terceros.ver`):
- `v_cxp_documento`: compras al crédito y saldos iniciales con saldo: total,
  pagado (sin pagos anulados), saldo, `dias` (desde la fecha de la factura),
  `dias_vencido`, `origen` ('compra' | 'saldo_inicial'), `documento_id` (lo
  que se pasa a `pagar_proveedor`) y `fecha_documento`.
- `v_cxp_proveedor`: saldo por proveedor y antigüedad: `de_0_a_30`,
  `de_31_a_60`, `de_61_a_90`, `mas_de_90` (por días desde la factura) y
  `vencido_centavos` (pasado el vencimiento).

**Cuadre:** la suma de CxP por proveedor = saldo de 2.1.01.01. Con el
módulo activo esa cuenta no acepta asientos manuales, y el módulo no se
activa si 2.1.01.01 ya tiene saldo que no explica (`MODULO_CON_SALDO`, ver
PROCEDIMIENTOS P-07).

**Cuentas de dinero (0.5.0, ver `dinero.md`):** una compra de contado acepta
`"cuenta_dinero_id"` (la forma de pago sale del tipo de cuenta) y
`pagar_proveedor` el último parámetro `cuenta_dinero_id` (forma de pago puede
ir en NULL). Pagar desde una cuenta de dinero (o con el código de su
subcuenta) deja su rastro y nunca la deja en negativo; las anulaciones
devuelven el dinero a esa misma cuenta. No se paga desde tránsito, POS ni
transferencias por confirmar. Las llamadas de antes siguen igual.

**Reintentos:** el `id_operacion` solo se reconoce como reintento si es del
mismo tipo (compra, pago, anulación...); si ya se usó en otra cosa: `ID_OPERACION_USADO`.

Permisos por defecto: dueño y admin (ver, registrar, anular, pagar); saldos
iniciales solo el dueño; el contador solo ve. Cajero y vendedor no ven compras.
