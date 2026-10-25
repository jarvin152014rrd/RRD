# Abonos con cheque (054_mayorista_garantias_cheques_antiguedad, núcleo 0.18.0) — módulos "ventas" y "dinero"

## Recibir — `registrar_cobro` con la forma "cheque"

```json
{"cliente_id": "...", "pagos": [{"forma": "cheque", "monto_centavos": 45000, "numero_cheque": "000123",
  "banco_emisor": "Banco Atlántida", "fecha_cheque": "2026-11-05"}], "aplicar": [...]}
```

- **El cheque NO es efectivo disponible.** Su valor entra a la cuenta de dinero **"Cheques por depositar"**
  (tipo `cheques_por_depositar`, su subcuenta 1.1.01.NN; se crea sola la primera vez). Asiento: Dr Cheques por
  depositar / Cr Clientes. La factura baja su saldo como con cualquier cobro.
- Reglas (`CHEQUE_INVALIDO`): va **solo** en el cobro (si paga parte en efectivo, son dos cobros), solo como abono a
  lo que debe (no anticipo ni apartado) y **no deja saldo a favor** (si rebota no habría con qué devolverlo); número,
  banco que lo emitió y fecha (de 6 meses atrás a un año adelante: puede ser **posfechado**).
- Cada cheque queda en `cheque_recibido` (vista `v_cheque_recibido`): `por_depositar` → `depositado` → (`rechazado`),
  o `anulado` si se anula el cobro. Bitácora en cada cambio.
- **Ventas con cheque: no** (decisión técnica). Una venta de contado no tiene a quién volver a cobrar si el cheque
  rebota (puede ser Consumidor final). Para vender con cheque: venta al crédito y cobro con cheque.

## Depositar — `depositar_cheque(cheque, banco, fecha?, referencia?, id_operacion)` (`dinero.trasladar`)

Un depósito de siempre (`operacion_dinero` "deposito"): Dr Depósitos en tránsito / Cr Cheques por depositar; queda
**en tránsito** con su alerta hasta `confirmar_deposito` (Dr banco / Cr tránsito). Ahí aparece el movimiento en el
banco y se cuadra en la **conciliación** como cualquier depósito. Un cheque posfechado no se deposita antes de su
fecha (`CHEQUE_POSFECHADO`). Si se anula el depósito (en tránsito) con `anular_operacion_dinero`, el cheque vuelve a
"por depositar". La cuenta "Cheques por depositar" no se mueve con `trasladar_dinero` (`CUENTA_DINERO_INVALIDA`).

## Rebotó — `registrar_cheque_rechazado(cheque, {"motivo", "fecha"?, "cargo_banco"?}, id_operacion)` (`cobros.anular`)

1. El valor vuelve a "Cheques por depositar": si el depósito sigue en tránsito, se anula ese depósito; si el banco
   ya lo había acreditado, el banco lo devuelve (operación "traslado": Dr Cheques por depositar / Cr banco).
2. Se anula el cobro con su contrapartida (`anular_cobro`): Dr Clientes / Cr Cheques por depositar. **El cliente
   vuelve a deber**; las comisiones se ajustan solas.
3. Opcional `"cargo_banco": {"categoria_id", "monto_centavos", "cuenta_dinero_id"?}`: el cargo del banco como gasto
   (`registrar_gasto`, desde el banco del depósito o el indicado).
Todo junto o nada; reintento con el mismo `id_operacion` = lo mismo. `anular_cobro` de un cobro con cheque solo se
permite mientras el cheque está por depositar (`CHEQUE_DEPOSITADO`).

## Dónde se ve

- `donde_esta_mi_dinero`: la cuenta "Cheques por depositar" con su saldo y además `cheques_por_depositar` (total,
  cantidad, posfechados y cada cheque).
- `proyeccion_flujo`: los cheques por depositar **entran en la semana de su fecha** (los de hoy o antes, en la
  semana 1); por semana `cheques_centavos`; nunca cuentan como disponible hoy.
- Conciliación: al confirmar el depósito (y, si rebota ya confirmado, la devolución del banco).

Ejemplo (prueba 143): galón 45,000 al crédito pagado con cheque: CxC 0 y cheques por depositar 45,000. Depositado y
confirmado: BAC +45,000. Rebota con cargo de L 25.00: BAC −45,000 −2,500, la factura vuelve a deber 45,000.
