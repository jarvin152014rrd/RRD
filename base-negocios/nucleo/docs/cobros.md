# Cobros, saldos iniciales de clientes y saldo a favor (033_cobros_saldo_favor) — módulo "ventas"

Todo lo que el cliente debe (ventas al crédito y saldos iniciales) baja SOLO
con operaciones que dejan asiento: cobros, condonaciones y notas de crédito
(`devoluciones.md`). Cada una es una fila en `cxc_aplicacion`; el saldo de una
factura = monto − aplicaciones vigentes. La suma siempre es igual a Clientes
(1.1.02.01).

## Saldos iniciales de clientes (solo el dueño)

`registrar_saldo_inicial_cxc(empresa, datos, id_operacion)` (`ventas.saldo_inicial`):

```json
{"cliente_id":"...","numero_documento":"F-120","fecha_documento":"2025-12-10",
 "fecha_vencimiento":"2026-01-09","monto_centavos":250000,"fecha":"2026-01-01","notas":"..."}
```

- Asiento: Dr Clientes / Cr 3.3.01.03 Saldos de apertura (la misma de proveedores).
- Vence por defecto en fecha de la factura + plazo del cliente. La factura no se repite (`YA_EXISTE`).
- Se cobra igual que una venta al crédito (`"saldo_inicial_id"` en `aplicar`).
- `anular_saldo_inicial_cxc(saldo, motivo, id_operacion, fecha?)`: solo sin cobros ni condonaciones vigentes.
- Activar "ventas" con saldo en Clientes que el sistema no explica: `MODULO_CON_SALDO`
  (pase la diferencia a Saldos de apertura, active y cargue cada factura con esta función).

## Cobrar — `registrar_cobro(empresa, datos, id_operacion)`

Permiso: `ventas.cobrar` (o el vendedor si la empresa tiene "vendedor que cobra").

```json
{"cliente_id":"...",
 "pagos":[{"forma":"efectivo","monto_centavos":30000,"recibido_centavos":31000},
          {"forma":"tarjeta","monto_centavos":5000,"referencia":"Voucher 77"},
          {"forma":"transferencia","monto_centavos":25000,"referencia":"TRF-1"},
          {"forma":"saldo_favor","monto_centavos":2000,"vale":"VALE-..."}],
 "aplicar":[{"venta_id":"...","monto_centavos":5000},{"saldo_inicial_id":"...","monto_centavos":2000}],
 "excedente":"saldo_favor", "tipo":"cxc"|"anticipo",
 "caja_id":"...", "fecha":"2026-01-20", "referencia":"Recibo 15", "nota":"...", "equipo":"Caja 1"}
```

- **A una factura o consolidado:** sin `aplicar`, se aplica a la **más vieja primero**
  (fecha de la factura, vencimiento, número); con `aplicar`, a las elegidas.
- **Formas de pago** como en ventas: efectivo (`interno.cuenta_efectivo_cobro`: turno
  abierto del usuario; sin turno solo si la empresa no los exige), tarjeta (POS por
  liquidar), transferencia (por confirmar → `confirmar_transferencia_cobro`), mixto,
  y **saldo a favor** del cliente o un vale.
- **Nunca más del saldo sin decisión:** si lo recibido pasa lo que se debe →
  `COBRO_EXCEDE_SALDO`. Con `"excedente":"saldo_favor"` lo que sobra queda a favor
  del cliente (no se pierde como en RRD). El excedente no puede salir de un saldo a favor.
- `"tipo":"anticipo"`: todo lo recibido queda como saldo a favor del cliente.
- Asiento: Dr cuenta de dinero de cada pago (Dr Saldos a favor si paga con su saldo) /
  Cr Clientes (lo aplicado) y Cr 2.1.04.02 Saldos a favor (el excedente). Con rastro del dinero.
- Una factura cobrada completa devenga las comisiones de su vendedor (`comisiones.md`).
- Reintento con el mismo `id_operacion` = el mismo cobro (`"duplicado": true`).

Ejemplo (prueba 94): F-OLD-1 20,000 (saldo inicial), V1 15,000, V2 45,000. Cobro de
30,000 sin elegir: F-OLD-1 20,000 + V1 10,000. Tarjeta 5,000 a V2. Mixto 55,000 con
excedente: V1 5,000 + V2 40,000 + 10,000 a favor.

## Anular un cobro — `anular_cobro(cobro, motivo, id_operacion, fecha?)` (`cobros.anular`)

Patrón "anular un abono" (CONVENCIONES): motivo de 5 letras o más; fecha por defecto
hoy (nunca antes del cobro); mes abierto; una sola vez (`YA_ANULADO`); contra-asiento
enlazado; el dinero **sale de la misma cuenta** a la que entró (una transferencia ya
confirmada, del banco donde quedó; si no hay dinero ahí: `SALDO_INSUFICIENTE`); el
saldo a favor usado vuelve a su lote; el excedente que quedó a favor se anula (si ya
se usó: `SALDO_FAVOR_USADO`); las facturas recuperan su saldo; las comisiones se ajustan.

**Venta con cobros:** `solicitar_anulacion_venta` da `VENTA_CON_COBROS` mientras tenga
cobros o condonaciones vigentes: primero se anulan.

## Condonar (redondeo) — nunca en silencio

`condonar_saldo_cxc(empresa, {"venta_id"|"saldo_inicial_id","monto_centavos","fecha"?}, motivo, id_operacion)`
(`cobros.condonar`, dueño y admin): Dr 6.1.02.12 Saldos condonados / Cr Clientes, con
motivo y bitácora. No más que el saldo. `anular_condonacion(condonacion, motivo, id_operacion, fecha?)` (`cobros.anular`).

## Saldo a favor y vales (`saldo_favor`, pasivo 2.1.04.02)

- Se genera por excedente de cobro, anticipo (`"tipo":"anticipo"`), devolución (nota de
  crédito), apartado cancelado o anulación de una venta pagada con anticipo.
- Cada vez es un **lote**. Con cliente = saldo a favor del cliente. **Sin cliente = VALE**
  con código único `VALE-XXXXXXXXXX` (se imprime en la nota de crédito).
- Vencimiento opcional de los vales: `empresa.vale_dias_vigencia` (null = no vencen; lo
  cambia el dueño con `configurar_empresa`). Vencido: `VALE_VENCIDO`.
- Se usa como forma de pago `saldo_favor` en ventas (`"vale"` o el saldo del cliente,
  lotes más viejos primero) y en cobros. Se consume al EMITIR la venta (una pendiente
  de aprobación no consume) con el lote bloqueado: dos usos a la vez no pasan del saldo
  (prueba 100). No alcanza: `SALDO_FAVOR_INSUFICIENTE`.
- `consultar_vale(empresa, codigo)` (`ventas.vender`): saldo, vencimiento y estado.
- El pasivo 2.1.04.02 = suma de los saldos de todos los lotes (vencidos incluidos;
  pendiente: decidir qué hacer con lo vencido).

## Lecturas

- `v_cxc_documento` (ventas y saldos iniciales: cobrado, condonado, devuelto, saldo, días, vencido)
  y `v_cxc_cliente` (antigüedad 0-30 / 31-60 / 61-90 / +90, vencido, crédito disponible).
- `estado_cuenta_cliente(empresa, cliente, desde?, hasta?)` (`ventas.ver`): saldo anterior,
  cargos y abonos con saldo corrido, saldo final, facturas pendientes y saldo a favor.
- `v_cobro` (cada quien los suyos; `ventas.ver` todos), `v_cobros_por_caja` (cobros del
  día por caja y cajero, por forma de pago, sin anulados), `v_saldo_favor` (lote por lote).

## Permisos

| | dueño | admin | cajero | vendedor | contador |
|---|---|---|---|---|---|
| ventas.cobrar (cobros) | ✓ | ✓ | ✓ | si vendedor_cobra | |
| cobros.anular | ✓ | ✓ | | | |
| cobros.condonar | ✓ | ✓ | | | |
| ventas.saldo_inicial | ✓ | | | | |

Con "ventas" apagado se pueden anular cobros, condonaciones y saldos iniciales; con
"dinero" apagado, confirmar una transferencia ya cobrada.
