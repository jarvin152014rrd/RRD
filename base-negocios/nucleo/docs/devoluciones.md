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
- **Montos:** total = round(total de la línea × cantidad / vendida); base sin ISV en
  proporción; ISV = la diferencia. La última devolución de una línea toma lo que falte
  (nunca se pierden centavos).
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

## Con otras partes

- Una venta con devoluciones ya no se anula completa (`VENTA_CON_DEVOLUCIONES`).
- Las comisiones del vendedor se ajustan solas (`comisiones.md`).
- `v_devolucion` (con `ventas.ver` todas; si no, las que uno registró; costo solo con
  `inventario.costos`). La tabla `devolucion` la leen quienes ven ventas y costos.
- Permiso `ventas.devolver`: dueño, admin y cajero (el vendedor no).
