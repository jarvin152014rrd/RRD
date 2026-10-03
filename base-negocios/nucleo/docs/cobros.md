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

## Anular un cobro — `anular_cobro(cobro, motivo, id_operacion, fecha?, cuenta_salida_id?)` (`cobros.anular`)

Patrón "anular un abono" (CONVENCIONES): motivo de 5 letras o más; fecha por defecto
hoy (nunca antes del cobro); mes abierto; una sola vez (`YA_ANULADO`); contra-asiento
enlazado; el dinero **sale de la misma cuenta** a la que entró (una transferencia ya
confirmada, del banco donde quedó; si no hay dinero ahí: `SALDO_INSUFICIENTE`); el
**efectivo** sigue la regla de turnos de abajo (0.9.1); el
saldo a favor usado vuelve a su lote; el excedente que quedó a favor se anula (si ya
se usó: `SALDO_FAVOR_USADO`); las facturas recuperan su saldo; las comisiones se ajustan.

**Efectivo de una anulación (0.9.1, decisión del dueño):** sale del **turno abierto de
quien anula, a su nombre**, con referencia al turno donde había entrado
(`dinero_movimiento.turno_origen_id`). Si ese turno original sigue abierto y es de quien
anula, sale de ahí mismo. **Nadie saca dinero del turno de otro cajero:** si el efectivo
está en el turno abierto de otro y quien anula no tiene turno propio → `TURNO_AJENO`.
Sin turno propio y con turnos obligatorios → `SIN_TURNO_ABIERTO` (abra su turno; si hace
falta, traiga el fondo con `cuenta_origen_id`). Sin turnos obligatorios y sin turnos
abiertos, sale de la misma caja como antes. Lo mismo vale para anular una venta
(`ventas.md`), devolver dinero (`devoluciones.md`) y devolver un anticipo de apartado.
Ejemplo (prueba 107): el cajero cobra 4,500 en su turno T1 y lo cierra; el admin abre su
turno T2 con 10,000 y anula: los 4,500 salen de T2 (`turno_origen_id` = T1); T1 no se toca.

**Cuenta de salida elegida (0.9.2):** en un negocio de una sola caja ocupada por el turno de
otro cajero, quien anula (con `cobros.anular`) puede indicar `cuenta_salida_id`: la caja
fuerte, un banco, la caja chica o la caja de su propio turno. El efectivo sale de ahí (con
`turno_origen_id` = el turno donde entró, si es una caja). Sigue prohibido elegir la caja
del turno de otro cajero (`TURNO_AJENO`). Ejemplo (prueba 115): el cajero tiene la única
caja con 7,500; el admin anula un cobro de 4,500 desde la caja fuerte (300,000 → 295,500)
y el dueño aprueba anular una venta de 3,000 desde el banco; la caja del cajero sigue con
7,500 y cierra sin diferencia.

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
  lotes más viejos primero) y en cobros. **0.9.1:** la venta NO acepta `"saldo_favor_id"`
  desde la app (solo el cambio de producto usa por dentro su propio lote) y un lote solo
  paga ventas de su misma empresa y su mismo cliente (`VALE_INVALIDO`). Se consume al EMITIR la venta (una pendiente
  de aprobación no consume) con el lote bloqueado: dos usos a la vez no pasan del saldo
  (prueba 100). No alcanza: `SALDO_FAVOR_INSUFICIENTE`.
- `consultar_vale(empresa, codigo)` (`ventas.vender`): saldo, vencimiento y estado.
- El pasivo 2.1.04.02 = suma de los saldos de todos los lotes (vencidos incluidos,
  hasta que el dueño los da de baja).

### Dar de baja vales vencidos (0.9.1, opción del dueño)

`dar_baja_vales_vencidos(empresa, {"vales":["VALE-..."] (opcional), "fecha"?}, motivo, id_operacion)`
(`cobros.baja_vales`, **solo el dueño**). Sin `"vales"`: todos los vales SIN cliente,
vencidos a la fecha y con saldo; con la lista: esos (uno vigente: `DATO_INVALIDO`). Cada
vale queda "usado" por la baja (saldo 0) y el total pasa a otros ingresos:
Dr 2.1.04.02 Saldos a favor / Cr 4.2.01.04 Vales vencidos no reclamados. Motivo de 5
letras o más (queda en la bitácora), una sola vez por `id_operacion`; nada vencido con
saldo: `SIN_VALES_VENCIDOS`. Se guarda en `saldo_favor_baja` (no se edita ni se borra).
Un vale vencido sigue sin poder usarse (`VALE_VENCIDO`), dado de baja o no.

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
| cobros.baja_vales (0.9.1) | ✓ | | | | |

Con "ventas" apagado se pueden anular cobros, condonaciones y saldos iniciales; con
"dinero" apagado, confirmar una transferencia ya cobrada.
