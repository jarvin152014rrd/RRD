# Apartados con anticipo (034_apartados) — módulo "apartados"

Necesita **ventas** e **inventario** (`modulo_dependencia`). El cliente deja un
anticipo, la mercadería queda reservada y se lleva cuando termina de pagar.

## Crear — `crear_apartado(empresa, datos, id_operacion)` (`apartados.registrar`)

```json
{"cliente_id":"...","lineas":[{"producto_id":"...","cantidad":4}],"descuento_factura":{...},
 "pagos":[{"forma":"efectivo","monto_centavos":50000}],
 "caja_id":"...","bodega_id":"...","fecha":"...","vence_el":"...","referencia":"...","nota":"...","equipo":"..."}
```

- **Requiere cliente** (`CLIENTE_REQUERIDO`) y al menos un bien.
- Precios, promociones y descuentos del día **quedan fijos** (se guardan en el apartado).
  Un descuento sobre el tope del puesto: `APROBACION_REQUERIDA` (que lo haga quien pueda).
  0.9.1: el tope vale también **por línea** (como en ventas).
- **Reserva** las existencias: lo apartado no está disponible para otras ventas ni
  traslados (`EXISTENCIA_RESERVADA`); un ajuste por conteo físico sí lo toca (refleja la
  realidad). No sale del kardex ni reconoce ingreso ni ISV.
- **Anticipo inicial obligatorio**: es un cobro tipo "apartado" (mismas formas de pago y
  reglas de turno que `registrar_cobro`; quien lo recibe necesita `ventas.cobrar` o ser
  vendedor que cobra). Asiento Dr dinero / Cr **2.1.04.01 Anticipos de clientes** (pasivo), con rastro.
- **Vence** en `empresa.apartado_dias_vigencia` días (defecto 30, lo cambia el dueño) o en
  `vence_el`. Un apartado vencido ya **no reserva** (la mercadería se puede vender).

## Abonar — `abonar_apartado(apartado, {"pagos","caja_id","fecha","referencia","equipo"}, id_operacion)`

Otro anticipo (cobro tipo apartado). No más de lo que falta (`COBRO_EXCEDE_SALDO`). Un
abono se anula con `anular_cobro` mientras el apartado esté vigente.

## Completar — `completar_apartado(apartado, {"pagos","caja_id","tipo_documento","fecha",...}, id_operacion)`

Cobra lo que falta y lo convierte en **venta** (factura CAI si fiscal_hn) con los precios
del apartado, aplicando los anticipos como forma de pago `anticipo` (Dr Anticipos de
clientes). En ese momento sale del kardex y se reconocen ingreso e ISV. La venta queda a
nombre del vendedor del apartado (0.9.2: aunque hoy esté dado de baja; su comisión se genera igual y
el dueño decide al liquidar, ver `comisiones.md`). Un apartado vencido se puede completar si todavía hay
existencia. Si la venta pidiera aprobación (por ejemplo crédito sobre el límite):
`APROBACION_REQUERIDA`.

Si después se anula esa venta, el anticipo pasa a **saldo a favor del cliente** (el
apartado ya se entregó).

## Cancelar — `cancelar_apartado(apartado, motivo, datos, id_operacion)` (`apartados.cancelar`)

Libera la reserva. El anticipo, según el dueño (`empresa.apartado_cancelacion`):
- `saldo_favor` (defecto): queda como saldo a favor del cliente (Dr Anticipos / Cr Saldos a favor);
- `devolver`: se devuelve de la cuenta elegida (`"cuenta_dinero_id"`; Dr Anticipos / Cr dinero, con rastro;
  0.9.1: de una caja, solo la del turno propio — `TURNO_AJENO` / `SIN_TURNO_ABIERTO`, ver `caja.md`);
- `elegir`: quien cancela elige con `"destino"`.
Se puede cancelar con el módulo apagado (corrige lo ya registrado).

Ejemplo (prueba 96): 4 galones = 180,000 con 50,000 de anticipo; de 10 en bodega solo
6 se pueden vender; abono de 30,000; al completar se cobran 100,000: factura de 180,000
(152,542 + 27,458 de ISV) con 80,000 de anticipo aplicado.

## Lecturas y permisos

`v_apartado` (estado `vencido` calculado, anticipos, saldo, líneas). Permisos:
`apartados.registrar` (dueño, admin, cajero, vendedor), `apartados.cancelar` (dueño, admin).
Activar "apartados" con saldo en 2.1.04.01 que los apartados no explican: `MODULO_CON_SALDO`.
Pendiente: penalidad por cancelación (no pedida).
