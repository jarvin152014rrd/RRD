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

### 0.16.0: la diferencia a favor del cliente y el cálculo previo

**Si el producto nuevo vale menos**, dentro de `"cambio"` va `"diferencia"`:

- `"dinero"`: se devuelve de `"cuenta_dinero_id"` (como antes; con la regla del efectivo del turno propio).
  Exige que el dueño permita `devolver_dinero`.
- `"saldo_favor"`: queda a favor del cliente (o en un **VALE** con código si la venta fue a consumidor
  final). No lleva `"cuenta_dinero_id"` (`DATO_INVALIDO`). Exige que el dueño permita `nota_credito`.
- Sin `"diferencia"`: es `"dinero"` (como antes; sin cuenta: `DATO_INVALIDO`). Revisión: con `"cuenta_dinero_id"`
  o si la diferencia sale en dinero, también exige `devolver_dinero` (si no: `DEVOLUCION_NO_PERMITIDA`). Otro valor:
  `DATO_INVALIDO`. Un cambio que vale más o igual no saca dinero y no lo exige.

Contablemente el lote de saldo a favor de la devolución es de (cambio + diferencia); la venta nueva usa
la parte del cambio y lo demás queda en 2.1.04.02 (prueba 136: galón 45,000 por 2 tornillos 3,000 →
saldo a favor 42,000; sin cliente: vale de 43,500 por 1 tornillo). La respuesta trae
`saldo_favor_centavos` y `saldo_favor.codigo` (el vale).

**`calcular_cambio_previo(venta, {"lineas", "cambio": {"lineas", "descuento_factura"?}, "fecha"?})`**
(`ventas.devolver` y, para la venta nueva, `ventas.vender` o `ventas.cotizar`): no guarda nada. Con la
misma regla de la devolución (cantidad acumulada) y de la venta (`calcular_venta_previa`) da
`devuelto.total_centavos` (y por línea), `rebaja_deuda_centavos` (lo que la venta todavía debe),
`para_el_cambio_centavos`, `nuevo` (la venta calculada), `total_nuevo_centavos`, `a_cobrar_centavos`,
`a_favor_cliente_centavos`, `opciones_diferencia` (solo las que el dueño permite, con su texto) y
`pasa_tope` (el cajero siempre: un cambio no queda pendiente). Sin costos para quien no los ve. Una venta
de otra sucursal (usuario limitado): `SUCURSAL_NO_PERMITIDA`. Si el dueño no permite el cambio:
`DEVOLUCION_NO_PERMITIDA`.

Técnico: `registrar_devolucion` de 038 pasó a `interno.registrar_devolucion_base` sin cambios; la pública
valida `"diferencia"` y la pasa a `interno.aplicar_devolucion` (reemplazada, mismo código + la rama del
saldo a favor) con `app.cambio_diferencia`, local a la transacción.

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

## 0.19.0 (migración 055): ajuste por perder el precio mayorista (decisión del dueño)

Caso: un cliente que **no es mayorista** compró con precio mayorista porque llegó a "desde cantidad" y después devuelve
unidades. Si lo que **se queda** (vendido − devuelto acumulado) es mayor que cero y **menor** que "desde cantidad", lo
que conserva vale a **precio normal**, y esa diferencia se descuenta de lo que se le devuelve.

- Cuenta (en `interno.montos_devolucion`, la misma para registrar, `calcular_devolucion_previa` y `calcular_cambio_previo`):
  con R = devuelto acumulado y K = vendido − R,
  ajuste acumulado = `precio_con_tasa(round(K × precio normal))` − (total de la línea − round(total × R / vendido)), con
  ISV (la base igual, sin ISV). Lo que corresponde devolver en total es round(total × R / vendido) − ese ajuste; esta
  devolución = eso − lo ya devuelto. Así varias devoluciones seguidas dan lo mismo que una sola y, si al final devuelve
  todo (K = 0), el ajuste anterior vuelve al cliente (los ajustes suman cero).
- Si el ajuste se come todo lo que se le devolvería (≤ 0): `DEVOLUCION_INVALIDA` con la explicación ("se quedaría con K y
  el precio mayorista es desde D ... devuelva más unidades (o todas) o no haga la devolución"). No se guarda nada.
- Contabilidad: la nota de crédito lleva el **neto** (base e ISV ya rebajados); el asiento es el de siempre. ISV por
  pagar = ISV de ventas − ISV de notas de crédito (al devolver todo, las notas suman exactamente la venta).
- Sin ajuste: cliente mayorista (la línea fue mayorista "por cliente"), líneas sin precio mayorista y **garantías**
  (`resolver_reclamo_garantia` lo anota con `app.devolucion_garantia`: el producto vino malo; A CONFIRMAR con el dueño).
- La línea vendida guarda por qué fue mayorista: `venta_linea.mayorista_por` (`cliente` | `cantidad`) y
  `mayorista_desde` (el "desde cantidad" de ese momento). Líneas de antes de 0.19.0 (en null): se usa si el cliente es
  mayorista hoy y el "desde cantidad" del producto hoy.
- El precio normal es el de la venta (`venta_linea.precio_normal_centavos`), sin promociones (decisión: mayorista y
  promociones no se suman).
- Se guarda en `devolucion.ajuste_mayorista_centavos` y `devolucion_linea.ajuste_mayorista_centavos` (positivo: se
  descontó; negativo: se devolvió un ajuste anterior). La respuesta de `registrar_devolucion` trae
  `ajuste_mayorista_centavos`, `valor_centavos` (lo que pagó por esas unidades) y `ajuste_mayorista_texto`
  ("Ajuste por perder precio mayorista: L 18.00"); igual `documento_nota_credito` (por línea y arriba) y `v_devolucion`.
- **Pendiente de aprobación (revisión 0.19.0):** si la línea tiene otra devolución esperando aprobación, una nueva se
  rechaza (`DEVOLUCION_INVALIDA`: "resuélvala primero"). Ejemplo (prueba 151): 10 a L 90.00 (normal L 100.00 desde 10);
  A pendiente por 2; B por 3 se rechaza; rechazada A, B da L 200.00 (no L 300.00).
- **Garantía después de una devolución con ajuste:** solo el valor proporcional de las unidades de la garantía; el ajuste
  ya cobrado se mantiene (prueba 151: devolvió 2 y recibió L 100.00; la garantía de 1 da L 90.00, no L 170.00).
- Líneas de antes de 0.19.0 vendidas con menos que "desde cantidad": "por cliente" (sin ajuste).
- Registrar vuelve a calcular los montos con el candado puesto: si otra devolución de la misma venta entró mientras
  tanto, `DEVOLUCION_INVALIDA` ("revise las cantidades").

Ejemplo (prueba 147): tornillo L 15.00 con ISV, mayorista L 12.00 desde 12; venta de 12 = 14,400 (base 12,522, ISV
1,878). Devolver 2: el ajuste (3,000) pasa lo devuelto (2,400): rechazo. Devolver 6: se queda 6 a 15.00 = 9,000; se le
devuelve 14,400 − 9,000 = 5,400 (lo devuelto valía 7,200; ajuste 1,800; base 4,696, ISV 704). Después 3 más: 4,500
(vuelven 900 del ajuste); las últimas 3: 4,500. Total 14,400, base 12,522, ISV 1,878.

`calcular_devolucion_previa(venta, {"lineas"})` (`ventas.devolver`): no guarda nada; `valor_centavos`,
`ajuste_mayorista_centavos`, `total_centavos` (base e ISV), `rebaja_deuda_centavos`, `para_el_cliente_centavos`, por
línea `conserva` y `mayorista_desde`, y el texto. Sin costos. Usuario de otra sucursal: `SUCURSAL_NO_PERMITIDA`.

## 0.19.0 (migración 055): cambio exacto (regla del dueño)

Regla de la empresa `empresa.cambio_exacto` (**encendida por defecto**: para las empresas que ya existían y las
nuevas). Con la regla:

- Un cambio de producto se hace por **uno o varios** productos cuyo total sea **exactamente** lo devuelto (después del
  ajuste mayorista, si hay). Si no: `CAMBIO_NO_EXACTO` con "falta L X" o "sobra L X". La otra salida es devolver todo el
  dinero (`"destino": "dinero"`).
- Nunca hay diferencia: un cambio no lleva `"pagos"`, `"diferencia"` ni `"cuenta_dinero_id"` (`CAMBIO_NO_EXACTO`).
- Venta al crédito todavía sin pagar: la devolución primero rebaja la deuda (como siempre) y esa parte se vuelve a
  deber en la venta nueva (pago `credito`); el cliente debe lo mismo que antes (como el cambio por garantía). Ese
  crédito "de vuelta" no pide aprobación de crédito ni cuenta para el límite, y la venta nueva vence cuando vencía la
  original (revisión 0.19.0, prueba 151).
- `calcular_cambio_previo` acepta `"reclamo_id"` (de esa venta): el cambio por garantía se calcula sin ajuste mayorista,
  igual que al resolver el reclamo.
- El cambio por garantía con "precio de garantía" (mismo producto y cantidad) sigue igual: ya vale lo pagado. Por otro
  producto, también debe dar exacto (si no, se resuelve como "devuelto").
- `calcular_cambio_previo` trae `cambio_exacto`, `exacto`, `falta_centavos`, `sobra_centavos` (contra lo devuelto),
  `a_credito_centavos`, `puede_devolver_dinero` y `opciones_diferencia` vacía. Desde 0.19.0 calcula la venta nueva con
  el cliente de la venta (así un cliente mayorista ve lo mismo que se registra).

Apagarla (solo el dueño, `empresa.configurar`, con motivo y bitácora):
`configurar_empresa(empresa, '{"cambio_exacto": false}', 'motivo')`. Apagada, el cambio funciona como en 0.16.0 (con
diferencia a cobrar o a favor). `configurar_empresa` devuelve siempre `cambio_exacto`. Ejemplo (prueba 149): galón
L 450.00 por 8 tornillos (L 120.00) + 15 lb de arroz (L 330.00) = exacto; por 2 tornillos: "falta L 420.00".
