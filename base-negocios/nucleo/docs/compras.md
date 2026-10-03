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

**`anular_compra(compra, motivo, id_operacion, fecha?)`** (compras.anular):
cada línea sale del kardex a lo que costó; contra-asiento enlazado al
original. Se rechaza si dejaría existencia negativa, si ya se anuló o si
la compra tiene pagos. Si la bodega queda vacía sale todo su valor y la
diferencia contra el costo original va a 5.1.01.02 (ajuste de costo).

**`pagar_proveedor(empresa, compra, monto_centavos, fecha, forma_pago, id_operacion, referencia?, cuenta_pago?)`**
(compras.pagar): abono a una compra al crédito. Nunca más que su saldo
(`PAGO_EXCEDE_SALDO`). Asiento Dr 2.1.01.01 / Cr la cuenta de pago (caja, bancos o
la subcuenta indicada, ej. "Banco Atlántida").

**Lectura** (piden `compras.ver`):
- `v_cxp_documento`: facturas al crédito con saldo: total, pagado, saldo,
  `dias` (desde la fecha de la factura) y `dias_vencido`.
- `v_cxp_proveedor`: saldo por proveedor y antigüedad: `de_0_a_30`,
  `de_31_a_60`, `de_61_a_90`, `mas_de_90` (por días desde la factura) y
  `vencido_centavos` (pasado el vencimiento).

**Cuadre:** la suma de CxP por proveedor = saldo de 2.1.01.01. Con el
módulo activo esa cuenta no acepta asientos manuales.

Permisos por defecto: dueño y admin (ver, registrar, anular, pagar).
Cajero y vendedor no ven compras.
