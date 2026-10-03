# Ventas (028_ventas, 029_cotizaciones_lecturas) — módulo "ventas"

Necesita solo "contabilidad" (0.8.0, ver `modulos.md`). Sin "inventario" la
venta **solo acepta servicios** (un bien da `MODULO_INACTIVO`); el catálogo se
edita igual con "ventas". Sin "dinero" solo se vende **al crédito** (el
contado necesita una cuenta de dinero). La factura con CAI es del régimen
fiscal (`cai.md`, módulo `fiscal_hn`, que necesita ventas); sin régimen activo
toda venta sale con **ticket interno** (T-001-001-00000001).

## Registrar — `registrar_venta(empresa, datos, id_operacion)`

TODO o NADA: documento + salida del kardex a costo promedio + asiento + rastro del dinero.

```json
{"lineas":[{"producto_id":"...","cantidad":10,"promocion_id":"..."},
           {"producto_id":"...","cantidad":1,"descuento_porcentaje":5},
           {"producto_id":"<servicio>","cantidad":2}],
 "pagos":[{"forma":"efectivo","monto_centavos":10000,"recibido_centavos":20000},
          {"forma":"tarjeta","monto_centavos":5000,"referencia":"Voucher 123"},
          {"forma":"transferencia","monto_centavos":5000},
          {"forma":"credito","monto_centavos":3000}],
 "cliente_id":"...", "caja_id":"...", "bodega_id":"...", "fecha":"2026-01-15",
 "tipo_documento":"factura"|"ticket", "descuento_factura":{"porcentaje":5}|{"monto_centavos":1000},
 "vendedor_id":"...", "nota":"...", "equipo":"Caja 1"}
```

- **Cliente opcional:** sin cliente = "Consumidor final". El crédito exige cliente (`CLIENTE_REQUERIDO`).
- **Caja:** la indicada, la del turno abierto del usuario o la única activa. **Bodega:** la indicada o la primera activa de la sucursal de la caja (no hace falta si solo hay servicios).
- **Formas de pago** (la suma = el total exacto, si no `PAGO_NO_CUADRA`; un solo pago sin monto = el total):
  | forma | entra a | nota |
  |---|---|---|
  | efectivo | caja de la venta (`interno.cuenta_efectivo_cobro`: turno abierto del usuario; sin turno solo si la empresa no los exige) | `recibido_centavos` da el vuelto |
  | tarjeta | cuenta "POS por liquidar" (la indicada, la única, o se crea) | se liquida al banco con `trasladar_dinero` |
  | transferencia | cuenta "Transferencias por confirmar" | `confirmar_transferencia_venta` la pasa al banco elegido |
  | credito | Clientes 1.1.02.01 (CxC) | vence = fecha + plazo del cliente (fecha local) |
| saldo_favor (0.9.0) | Dr Saldos a favor 2.1.04.02 | saldo a favor del cliente o `"vale":"VALE-..."` (sin cliente); se consume al emitir (`cobros.md`) |
| anticipo (0.9.0) | Dr Anticipos de clientes 2.1.04.01 | solo al completar un apartado (`apartados.md`) |
- **Quién cobra:** con efectivo, tarjeta o transferencia se pide además `ventas.cobrar` (cajero, admin, dueño). El vendedor vende al crédito o hace una **cotización** que el cajero cobra, salvo que la empresa tenga **vendedor que cobra** (ver abajo).
- **Existencia:** la política de siempre (negativo solo con la configuración de la empresa o el permiso `inventario.negativo`). Los **servicios** no tocan el kardex.
- **Respuesta:** venta_id, número, estado, documento, totales, vuelto, aprobación; el costo solo a quien tiene `inventario.costos`.

### Asiento

| | Debe | Haber |
|---|---|---|
| Cobro | caja / POS / transferencias por confirmar / Clientes | |
| Descuentos (sin ISV) | 4.1.01.03 Descuentos sobre ventas | |
| Ventas (precio sin ISV, antes de descuentos) | | 4.1.01.01 |
| Impuesto (cada impuesto gravado a SU cuenta de la tabla) | | 2.1.02.01 ISV por pagar |
| Costo (kardex, solo bienes) | 5.1.01.01 | 1.1.03.01 |

Ejemplo (prueba 79): 10 tornillos a L 15.00 con ISV + 2.5 lb de arroz exento a L 22.00:
15,000 → 13,043 + 1,957; arroz 5,500; total 20,500; costo 10 x 1,000 + 2.5 x 1,500 = 13,750.

## Promociones: nunca descuento sobre descuento (0.8.0, decisión del dueño)

- Cada línea lleva **a lo más un descuento**: promoción, o descuento manual de
  la línea, o su parte del descuento de factura. Nunca dos.
- Si a una línea le aplican **varias promociones** vigentes (de su categoría o
  de una categoría madre), la venta **no elige sola**: quien vende ve la lista
  con `promociones_aplicables(empresa, producto, fecha?, cantidad?)` (de la que
  más descuenta a la que menos) y manda `"promocion_id"` en la línea. Sin
  elegir: `PROMOCION_A_ELEGIR` con los nombres, ids y descuento de cada una.
  Si aplica **una sola**, se aplica sola. Una promoción que no aplica a ese
  producto en esa fecha: `PROMOCION_INVALIDA`.
- Una línea con promoción **no admite** descuento manual (`DESCUENTO_DOBLE`).
- El **descuento de factura** (porcentaje o monto) se reparte **solo entre las
  líneas sin otro descuento**; las de promoción o descuento manual quedan
  fuera (decisión: excluirlas, no rechazar la venta). Si ninguna línea queda
  libre: `DESCUENTO_DOBLE`. Un monto mayor que esas líneas: `DATO_INVALIDO`.
- Ejemplo (prueba 90): tornillos con promoción 13,500; galón con 2 % manual
  44,100; servicio sin descuento 23,000; factura 10 % → solo el servicio:
  round(23,000 × 10 %) = 2,300 → total 13,500 + 44,100 + 20,700 = 78,300.
- La cotización usa la misma regla. Una cotización de antes de 0.8.0 con
  "precios respetados" se convierte con lo que se cotizó.

## Vendedor que cobra (0.8.0, decisión del dueño)

`empresa.vendedor_cobra` (por defecto **false**): con `true` el vendedor recibe
efectivo, tarjeta y transferencia como el cajero, con las mismas reglas de
turno (`interno.cuenta_efectivo_cobro`: si la empresa exige turnos, sin turno
abierto da `SIN_TURNO_ABIERTO`). Con `false`, como siempre: cobra el cajero.
Lo cambia **solo el dueño** con `configurar_empresa(empresa,
'{"vendedor_cobra": true}', motivo)` (queda en la bitácora). El perfil
**pequeño** lo sugiere en `true`; mediano y grande en `false`. `mi_perfil()`
lo trae en `empresa.vendedor_cobra`.

## Cálculo por línea (`interno.calcular_venta`)

En los términos del precio (con impuesto si el precio lo incluye):
1. bruto = round(cantidad × precio)
2. **promoción** de su categoría o de una categoría madre, vigente en la fecha: la única que aplica o la elegida con `promocion_id` (% o monto por unidad)
3. **artículo** (solo si la línea no tiene promoción): `descuento_porcentaje` o `descuento_centavos`
4. **factura** (solo líneas sin promoción ni descuento de artículo): porcentaje (por línea) o monto con impuesto, repartido por el total con impuesto de cada línea libre (resto mayor, al centavo); si el precio no incluye impuesto se pasa a sin impuesto con round(parte / (1 + tasa)) (puede variar ±1 centavo)
5. neto → regla de siempre (`public.precio_con_tasa`, tasa de la tabla de impuestos): base sin impuesto, impuesto y total. El impuesto se calcula sobre el precio ya rebajado.

`descuento_manual_porcentaje` = (artículo + factura, sin impuesto) / (precio con promoción, sin impuesto) × 100: es lo que se compara con el tope del puesto. Las promociones no cuentan (las autorizó el admin al crearlas).
Ejemplo (prueba 80, 0.8.0): 10 tornillos con promoción 10 % → 13,500 con ISV (descuento 1,304 sin ISV, todo de promoción); con además 5 % del artículo → `DESCUENTO_DOBLE`.

## Topes y aprobaciones

- Topes de descuento por puesto (`configurar_tope_descuento(empresa, rol, sin_aprobacion %, aprueba_hasta %, motivo)`, solo el dueño). **Confirmados por el dueño (0.8.0):** cajero y vendedor 5 %; admin 10 % y aprueba hasta 20 %.
- Crédito y anulación (`configurar_tope_rol(..., 'credito' | 'anulacion_venta', 0, aprueba_hasta, motivo)`): admin aprueba hasta L 5,000.00 (**confirmado**).
- Sobre el tope (o crédito que lo pide) la venta queda **pendiente_aprobacion** SIN mover dinero, inventario ni número CAI. `resolver_aprobacion(aprobacion, true/false, motivo, id_operacion)` (`ventas.aprobar`): aprobar la EMITE en ese momento (fecha de hoy) con las formas de pago registradas (el efectivo entra al mismo turno; si ese turno ya cerró: `TURNO_CERRADO`); rechazar pide motivo. `cancelar_venta(venta, motivo, id)`: quien la registró o quien aprueba.
- Nadie aprueba lo que pidió (salvo el dueño). El dueño no tiene topes.
- **Doble aprobación** (`empresa.doble_aprobacion`, perfil grande): se fija al pedir; dos personas distintas (la primera queda anotada y la solicitud sigue pendiente); **el dueño aprueba solo**; un rechazo basta. Vale para gastos, ventas y anulaciones.

## Crédito (`empresa.credito_politica`)

- `segun_limite` (defecto): directo si el cliente tiene límite y (saldo + este crédito) no lo pasa; si lo pasa o el cliente no tiene límite (cliente nuevo), pide aprobación.
- `siempre_aprobacion`: todo crédito pide aprobación (salvo el dueño).
- Vence en fecha + plazo del cliente (fechas locales, nunca UTC).

## Anular — el vendedor solo SOLICITA

`solicitar_anulacion_venta(venta, motivo, id_operacion)` (`ventas.solicitar_anulacion`): solo ventas emitidas, de un mes abierto, sin cobros ni condonaciones vigentes (`VENTA_CON_COBROS`: anúlelos primero con `anular_cobro` / `anular_condonacion`) y sin devoluciones (`VENTA_CON_DEVOLUCIONES`). Aprueba admin (hasta su tope) o dueño con `resolver_aprobacion` y **motivo**:
- la factura conserva su número y queda **ANULADA** (el documento sale marcado);
- contra-asiento enlazado (`anula_asiento_id`);
- la mercadería vuelve a lo que costó;
- el dinero vuelve a salir de la **MISMA cuenta** a la que entró (una transferencia ya confirmada, del banco donde quedó). Si esa cuenta ya no tiene el dinero: `SALDO_INSUFICIENTE` (primero se trae el dinero a esa cuenta);
- la CxC se revierte; el saldo a favor usado vuelve a su lote y un anticipo de apartado queda a favor del cliente;
- las comisiones del vendedor se revierten.
Mes cerrado: `PERIODO_CERRADO`: se corrige con una devolución / nota de crédito (`devoluciones.md`).

## Transferencias — `confirmar_transferencia_venta(pago, {"banco_id","referencia","fecha"?}, id)`

`dinero.trasladar`. Dr banco / Cr transferencias por confirmar, con rastro. Una vez.

## Cotizaciones

`crear_cotizacion(empresa, {"lineas","descuento_factura","cliente_id","vigente_hasta"}, id)` (`ventas.cotizar`):
no mueve inventario, dinero ni número; vigencia por defecto `empresa.cotizacion_dias_vigencia` (15).
`convertir_cotizacion_a_venta(cotizacion, {"pagos","caja_id",...}, id)`: la venta queda a nombre del
vendedor de la cotización. Vigencia de 15 días (configurable, **confirmado por el dueño**). **Decisión:** `cotizacion_precios = 'respetar'` (defecto): vigente → precios y descuentos COTIZADOS; vencida → precios del día. `'recalcular'`: siempre precios del día. El tope de descuento se revisa con el puesto de quien la convierte. `anular_cotizacion`. Si su venta se rechaza o cancela, se puede convertir otra vez.

## Lecturas

- `v_venta`, `v_venta_linea`, `v_venta_pago`: con `ventas.ver` todas; si no, las que uno registró o vendió. Costo y utilidad bruta (venta sin impuesto − costo − costo estimado de servicios) solo con `ventas.ver` + `inventario.costos`. La tabla `venta` la leen solo quienes ven costos.
- `v_ventas_por_dia`, `v_ventas_por_vendedor`, `v_ventas_por_caja` (`ventas.ver`).
- `v_cxc_documento` y `v_cxc_cliente` (saldo, antigüedad 0-30/31-60/61-90/+90 desde la factura, vencido, crédito disponible). Desde 0.9.0 incluyen los saldos iniciales de clientes (`origen = 'saldo_inicial'`) y descuentan cobros, condonaciones y notas de crédito (columnas `cobrado_centavos`, `condonado_centavos`, `devuelto_centavos`). Estado de cuenta: `estado_cuenta_cliente` (`cobros.md`).
- `documento_venta(venta)`: lo que se imprime (emisor y cliente con RTN, líneas, desglose de impuestos, total en letras, pagos, datos fiscales y leyendas del régimen). Sin costos.
- `seguir_venta(venta)` (`ventas.ver`; el detalle de cuentas con `dinero.ver`): venta → forma de pago → cuenta de dinero y su rastro → turno, confirmación al banco o depósitos de esa caja desde la venta.

## Permisos por defecto

| | dueño | admin | cajero | vendedor | contador |
|---|---|---|---|---|---|
| ventas.ver | ✓ | ✓ | | | ✓ |
| ventas.vender | ✓ | ✓ | ✓ | ✓ | |
| ventas.cobrar | ✓ | ✓ | ✓ | | |
| ventas.cotizar | ✓ | ✓ | ✓ | ✓ | |
| ventas.aprobar / ventas.anular | ✓ | ✓ (topes) | | | |
| ventas.solicitar_anulacion | ✓ | ✓ | ✓ | ✓ | |
| ventas.promociones | ✓ | ✓ | | | |

Clientes (1.1.02.01) no acepta asientos manuales con el módulo activo; activar
"ventas" con saldo en Clientes que el módulo no explica: `MODULO_CON_SALDO`.

## Etapa 2b-2b (0.9.0)

- Cobros, saldos iniciales de clientes, condonación y saldo a favor / vales: `cobros.md`.
- Devoluciones, notas de crédito y cambio de producto: `devoluciones.md`.
- Apartados con anticipo (módulo "apartados"): `apartados.md`.
- Comisiones (módulo "comisiones"): `comisiones.md`.
- `registrar_venta` acepta `"vale"` / `"saldo_favor_id"` en un pago `saldo_favor`.
  `interno.registrar_venta_base` tiene un parámetro más (el apartado que se completa);
  `interno.emitir_venta` y `interno.anular_venta_base` se reemplazaron con la misma firma.
