# Comisiones de vendedores (036_comisiones) — módulo "comisiones"

Necesita **ventas**. Además del módulo (lo activa el proveedor), el dueño tiene su
**interruptor** y elige la **base**.

## Configurar (solo el dueño, `comisiones.configurar`)

- `configurar_comisiones(empresa, {"activas": true|false, "base": "ganancia"|"precio"}, motivo)`:
  - `ganancia` (defecto, recomendado) = precio sin ISV − costo (bienes: costo del kardex;
    servicios: costo estimado);
  - `precio` = precio sin ISV.
  **Nunca sobre el ISV.** Queda en la bitácora.
- `fijar_porcentaje_comision(empresa, usuario, porcentaje, desde, motivo)`: porcentaje
  por empleado con fecha desde (historial; vale el de la fecha de la venta).
  **0.9.1: no es retroactivo:** `desde` es hoy (por defecto) o una fecha futura; una fecha
  pasada da `FECHA_INVALIDA` (lo ya vendido conserva su porcentaje).
  **0.9.2: el porcentaje queda guardado en la venta al emitirla** (`venta.comision_porcentaje`) y
  ese es el que se usa al devengar: si el dueño cambia hoy el porcentaje, una venta al crédito
  emitida hoy y cobrada después conserva el de su emisión (prueba 116: 10 % → 130; la venta
  nueva al 20 % → 261). Las ventas de antes de 0.9.2 (sin porcentaje guardado) siguen con la
  regla anterior: el vigente en su fecha al momento de cobrarse (prueba 119).

> **Aviso para el dueño (base "ganancia"):** con esta base la comisión depende del
> **costo** de lo vendido (ganancia = precio sin ISV − costo). El vendedor no ve costos
> en el sistema (`v_mis_comisiones` solo muestra monto y %), pero sabiendo su porcentaje
> y el precio de venta **puede deducir el costo** (precio − comisión ÷ %). Si el costo es
> información sensible para el negocio, use la base "precio" o no comparta el
> porcentaje con el detalle de cada venta.

## Cuándo se ganan

- Se **devengan cuando la venta queda cobrada completa**: al contado, al emitir; al
  crédito, cuando su saldo llega a 0 (cobros, saldo a favor, condonación).
- **Solo sobre lo realmente cobrado (0.9.1, decisión del dueño):** si se condonó parte
  de la factura, a la base se le resta la parte sin ISV de lo condonado:
  round(condonado × base sin ISV / total con ISV). Ejemplo (prueba 106): venta de 90,000
  (76,271 + ISV 18 %), cobran 89,000 y condonan 1,000 → se restan round(1,000 × 76,271 /
  90,000) = 847; base 75,424; al 10 % = 7,542 (antes 7,627). Si se anula la condonación,
  la comisión vuelve a 0 hasta que se cobre todo (entonces 7,627).
- Se **ajustan solas** (`comision_movimiento`, tipo `ajuste`) con devoluciones, cobros
  anulados y anulación de la venta, **aunque ya se hayan pagado**: queda saldo a
  descontar del próximo pago.
- Con el interruptor o el módulo apagado no se devengan comisiones nuevas; las ya
  devengadas se siguen ajustando.
- **Vendedor dado de baja (0.9.2, recomendado):** la venta que viene de un apartado o una
  cotización suya queda a su nombre y su comisión **se genera igual** (la ganó cuando hizo
  el documento). El dueño decide al liquidar: `pagar_comisiones` funciona aunque el usuario
  ya no esté activo (prueba 114). Si decide no pagarla, hoy queda en Comisiones por pagar
  (no hay una función para condonarla: la corrige el contador con un asiento).
- Cada movimiento tiene asiento: Dr 6.1.01.04 Comisiones sobre ventas / Cr 2.1.03.04
  Comisiones por pagar (al revés si baja).

Ejemplo (prueba 98, 10 %): 10 tornillos al crédito (13,043 − 10,000 = 3,043) → 304 al
cobrarla completa; 2 h de servicio (40,000 − 16,000) → 2,400; devolución de 1 h → −1,200;
pago 1,504; devolución de 4 tornillos después de pagar → −121 a descontar.

## Pagar (`comisiones.pagar`, dueño y admin)

`pagar_comisiones(empresa, {"vendedor_id","hasta","cuenta_dinero_id","fecha","referencia","equipo"}, id_operacion)`:
paga todo lo pendiente hasta `hasta` (los ajustes negativos se descuentan). Si el neto
no es positivo: `NADA_QUE_PAGAR`. Dr Comisiones por pagar / Cr cuenta de dinero
elegida, con rastro. `anular_pago_comisiones(liquidacion, motivo, id_operacion, fecha?)`:
el dinero vuelve a la misma cuenta y lo pagado vuelve a quedar pendiente (se puede con
el módulo apagado).

## Lecturas

- `v_comision` (`comisiones.ver`: dueño, admin, contador): cada movimiento; la base
  "ganancia" solo con `inventario.costos`.
- `v_comision_vendedor`: devengado, pagado y por pagar (negativo = a descontar).
- `v_mis_comisiones`: **el vendedor ve solo las suyas** (venta, monto, %, pagada), sin
  base ni costos.

Activar "comisiones" con saldo en 2.1.03.04 que el módulo no explica: `MODULO_CON_SALDO`.
