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

## Cuándo se ganan

- Se **devengan cuando la venta queda cobrada completa**: al contado, al emitir; al
  crédito, cuando su saldo llega a 0 (cobros, saldo a favor, condonación).
- Se **ajustan solas** (`comision_movimiento`, tipo `ajuste`) con devoluciones, cobros
  anulados y anulación de la venta, **aunque ya se hayan pagado**: queda saldo a
  descontar del próximo pago.
- Con el interruptor o el módulo apagado no se devengan comisiones nuevas; las ya
  devengadas se siguen ajustando.
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
