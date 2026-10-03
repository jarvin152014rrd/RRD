# Devoluciones y notas de crédito (035_devoluciones) — módulo "ventas"

**Decisión técnica:** las devoluciones son parte de "ventas" (no un módulo aparte):
todo negocio que vende necesita poder corregir una venta, y la nota de crédito es la
única forma de corregir una venta de un mes cerrado. Lo que el dueño decide es QUÉ
tipos permite.

## Registrar — `registrar_devolucion(venta, datos, id_operacion)` (`ventas.devolver`)

```json
{"lineas":[{"linea":1,"cantidad":4}], "motivo":"Venían oxidados",
 "destino":"dinero"|"saldo_favor"|"cambio", "cuenta_dinero_id":"...",
 "caja_id":"...", "fecha":"...",
 "cambio":{"lineas":[...],"pagos":[...],"descuento_factura":{...},"tipo_documento":"..."}}
```

- **Parcial o total por línea** (número de línea de la venta). Cantidad ≤ vendida − ya
  devuelta (las pendientes de aprobación cuentan): si no, `DEVOLUCION_INVALIDA`.
- **Montos (0.9.1: por cantidad ACUMULADA):** se calcula lo que corresponde a TODO lo
  devuelto de la línea (lo de antes + esta) y se le resta lo ya devuelto:
  total = round(total de la línea × acumulado / vendida) − total ya devuelto;
  base = round(base × acumulado / vendida) − base ya devuelta; ISV = total − base; el
  costo igual. Así devolver en partes da lo mismo que devolver de una vez y la última
  toma lo que falte (nunca se pierden ni se ganan centavos de ISV). Ejemplo (prueba 104):
  10 kg a L 11.50 + ISV (13,225 = 11,500 + 1,725) devueltos de 0.5 en 0.5: cada nota lleva
  575 de base y 86 u 87 de ISV; a 1 kg el ISV devuelto es 173 (antes 172) y al final 1,725.
- **Inventario al costo de la venta original** (entrada `devolucion_venta` en el kardex,
  al costo proporcional de la línea). Los **servicios** no tocan inventario y no se
  devuelven como cambio de producto (solo nota de crédito o dinero).
- **Nota de crédito:** si la venta fue factura y `fiscal_hn` está activo, número del
  rango CAI de tipo `nota_credito` de la caja (`registrar_cai` con `"tipo_documento":"nota_credito"`;
  sin rango: `SIN_CAI`); si no, numeración interna `NC-001-001-00000001`.
  `documento_nota_credito(devolucion)` da lo que se imprime (factura que modifica, CAI, leyendas).
- **A dónde va el valor (NUNCA dos veces — corrige el error de RRD):**
  1. Si la venta tiene saldo por cobrar, primero **rebaja la CxC** (sin dinero por esa parte).
  2. Lo que quede (lo que el cliente ya pagó) va al `destino`: `dinero` (sale de la cuenta
     elegida: caja, caja chica o banco), `saldo_favor` (nota de crédito al cliente; sin
     cliente = VALE con código) o `cambio`. Si queda algo y no hay destino: `DATO_INVALIDO`.
  3. **Efectivo (0.9.1, decisión del dueño):** de una caja solo sale del turno abierto de
     quien registra o aplica la devolución (o de quien la pidió, si su turno sigue
     abierto). La caja con el turno de otro cajero: `TURNO_AJENO`; una caja sin turno con
     turnos obligatorios: `SIN_TURNO_ABIERTO`. El movimiento lleva `turno_origen_id` = el
     turno donde se cobró la venta. Banco y caja chica, como antes.
- **Tipos que permite el dueño:** `empresa.devolucion_tipos` (`devolver_dinero`,
  `cambio_producto`, `nota_credito`; por defecto los tres, A CONFIRMAR). Otro:
  `DEVOLUCION_NO_PERMITIDA`. La rebaja de CxC siempre se permite.

### Asiento

| | Debe | Haber |
|---|---|---|
| Ingreso (sin ISV) | 4.1.01.04 Devoluciones sobre ventas | |
| Impuesto (cada uno a su cuenta) | 2.1.02.01 ISV por pagar | |
| Rebaja de lo que debe | | 1.1.02.01 Clientes |
| Dinero devuelto | | cuenta de dinero elegida (con rastro) |
| Nota de crédito / cambio | | 2.1.04.02 Saldos a favor |
| Mercadería (bienes) | 1.1.03.01 Inventario | 5.1.01.01 Costo de ventas |

Así **ISV por pagar = ISV de ventas − ISV de notas de crédito** (prueba 99).

Ejemplo (prueba 97): 10 tornillos (15,000 = 13,043 + 1,957; costo 10,000), devolver 4:
6,000 = 5,217 + 783; costo 4,000. Venta al crédito de 90,000 con 30,000 cobrados:
devolver 45,000 rebaja la CxC 45,000 (sin dinero); devolver los otros 45,000 rebaja
15,000 y devuelve 30,000.

## Cambio de producto

`"destino":"cambio"` + `"cambio"`: devolución y **venta nueva enlazadas**
(`devolucion.venta_cambio_id`). La venta nueva se paga con el valor devuelto (un lote de
saldo a favor que se consume en el acto) y:
- si vale más, se cobra la diferencia con `"pagos"` del cambio;
- si vale menos, la diferencia se devuelve de `"cuenta_dinero_id"`.
La venta nueva debe salir de una vez (si pidiera aprobación: `APROBACION_REQUERIDA`).

## Tope y aprobación

Tope por puesto `configurar_tope_rol(..., 'devolucion', sin_aprobacion, aprueba_hasta, motivo)`.
Valores iniciales (A CONFIRMAR): el admin registra y aprueba hasta L 5,000.00; el cajero
siempre pide aprobación; el dueño no tiene tope. Sobre el tope la devolución queda
**pendiente_aprobacion** sin mover nada (sí reserva sus cantidades); `resolver_aprobacion`
la aplica (con la doble aprobación si la empresa la tiene) o la rechaza con motivo.
Un cambio de producto sobre el tope no queda pendiente (`APROBACION_REQUERIDA`): se hace
como nota de crédito pendiente y después se vende con ese saldo.

### Pendiente que se atasca (0.9.1)

Si mientras espera aprobación el cliente paga (la devolución se pidió sin destino porque
todo iba a rebajar la deuda) o se cierra el turno de la caja elegida, aprobar da un
error claro. Se destraba con
`definir_destino_devolucion(devolucion, {"destino":"dinero"|"saldo_favor","cuenta_dinero_id"?}, motivo)`
(`ventas.devolver` de quien la pidió, o quien tiene `ventas.aprobar`): solo mientras está
pendiente, con motivo (bitácora), respetando los tipos que permite el dueño y la regla del
efectivo. Después se vuelve a aprobar con `resolver_aprobacion` (o se rechaza con motivo).
Ejemplo (prueba 109).

**0.9.2:** si el destino cambia de verdad, el texto de la solicitud de aprobación termina en
`| Destino: devolver dinero de "Caja fuerte"` o `| Destino: saldo a favor del cliente (nota de
crédito)` con el motivo del cambio, para que quien aprueba vea el destino actual. Con doble
aprobación, una primera aprobación ya dada (era para el destino anterior) **se reinicia** y hay
que aprobar otra vez (la respuesta trae `aprobacion_reiniciada`). Poner el mismo destino no
cambia nada. Queda en la bitácora con el motivo. Prueba 117.

## Con otras partes

- Una venta con devoluciones ya no se anula completa (`VENTA_CON_DEVOLUCIONES`).
- Las comisiones del vendedor se ajustan solas (`comisiones.md`).
- El cajero (sin `inventario.costos`) no ve costos en ningún nivel de la respuesta,
  tampoco en la venta nueva de un cambio (0.9.1, prueba 103).
- `v_devolucion` (con `ventas.ver` todas; si no, las que uno registró; costo solo con
  `inventario.costos`). La tabla `devolucion` la leen quienes ven ventas y costos.
- Permiso `ventas.devolver`: dueño, admin y cajero (el vendedor no).
