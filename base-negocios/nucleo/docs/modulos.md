# Módulos (030_modulos_dependencias) — encender y apagar sin romper los números

Cada empresa tiene sus módulos en `modulo_activo` (sí/no). Los activa y apaga
**solo el proveedor** (ficha + `herramientas/aplicar_ficha.sh`, ver
PROCEDIMIENTOS P-09). El dueño no los cambia desde la app (puede pedirlos con
`solicitar_al_proveedor`, ver `limites.md`).

## Lista de módulos

| Código | Para qué sirve | Necesita | Detalle |
|---|---|---|---|
| `contabilidad` | Núcleo: catálogo de cuentas, asientos, meses, reportes, bitácora. Siempre activo. | — | `asientos.md`, `periodos.md`, `reportes.md` |
| `inventario` | Catálogo de productos, bodegas, kardex con costo promedio, ajustes, traslados, carga inicial. | contabilidad | `productos.md`, `inventario.md` |
| `dinero` | Cuentas de dinero (cajas, bancos, caja chica), rastro, depósitos, turnos de caja, gastos, pagos fijos. | contabilidad | `dinero.md`, `caja.md`, `gastos.md` |
| `ventas` | Ventas (bienes y servicios), descuentos, promociones, crédito, cotizaciones, CxC. | contabilidad | `ventas.md` |
| `compras` | Compras al kardex, cuentas por pagar, pagos y saldos iniciales de proveedores. | inventario | `compras.md` |
| `fiscal_hn` | Régimen fiscal de Honduras: CAI por caja, facturas numeradas, leyendas. | ventas | `cai.md` |
| `apartados` (0.9.0) | Apartados con anticipo: reservan mercadería; anticipos como pasivo; se completan como venta. | ventas, inventario | `apartados.md` |
| `comisiones` (0.9.0) | Comisiones de vendedores: devengo al cobrar, ajustes, pago por período. | ventas | `comisiones.md` |

Cobros, saldos iniciales de clientes, saldo a favor / vales y devoluciones (notas de
crédito) son parte de `ventas` (decisión 0.9.0: todo negocio que vende necesita cobrar
y corregir; el dueño elige qué tipos de devolución permite en Ajustes).

Las dependencias están **como datos** en `public.modulo_dependencia` (la app y
el proveedor las leen de ahí). Son las mínimas: lo que sale de otra (compras
necesita contabilidad porque necesita inventario) no se repite.

### Lo que NO es dependencia (decisiones)

- **Ventas sin inventario:** un negocio de solo servicios (salón, taller de
  mano de obra, consultorio) vende sin inventario. Con `inventario` apagado (o
  nunca activado) la venta **solo acepta servicios**; un bien da
  `MODULO_INACTIVO: ... esta venta solo puede llevar servicios`. No hay modo
  "bienes sin control de existencias": un bien siempre lleva kardex, así el
  kardex y el inventario contable nunca se separan. El catálogo (productos,
  categorías, unidades, precios) se edita con `ventas` o con `inventario`
  (`interno.modulo_alterno`); bodegas, ajustes y traslados son solo de inventario.
- **Ventas sin dinero:** sin el módulo `dinero` solo se vende **al crédito**
  (queda en Clientes, CxC). El contado, la tarjeta y la transferencia necesitan
  una cuenta de dinero: `MODULO_INACTIVO: el módulo "dinero" no está activo...`.
  Así se puede apagar `dinero` a mitad de mes sin apagar ventas.
- Compras de contado y pagos a proveedores sin `dinero` siguen como antes de
  0.5.0: a 1.1.01.01 (caja) o 1.1.01.03 (bancos), sin rastro por cuenta.

## Reglas (las hace cumplir la base)

1. **No se activa un módulo sin los que necesita:** `MODULO_DEPENDENCIA: el
   módulo "fiscal_hn" necesita "ventas", que no está activo. Active primero "ventas".`
2. **No se apaga un módulo del que dependen otros activos:** `MODULO_DEPENDENCIA:
   no se puede apagar "inventario" porque lo usa "compras", que está activo.
   Apague primero "compras".` (Tampoco se borra su fila.)
3. Se revisa al **final de cada sentencia**: activar varios en un solo INSERT
   funciona en cualquier orden. `aplicar_ficha` además los ordena (apaga
   primero los que dependen; enciende primero los necesarios).
4. Activar un módulo con saldo en su cuenta que no explica sigue dando
   `MODULO_CON_SALDO` (P-07).

## Apagar un módulo = solo impide operaciones NUEVAS

Nunca se borra nada. Con el módulo apagado:

- **Siguen:** todas las lecturas, vistas, reportes, la contabilidad, cerrar y
  reabrir meses, la bitácora.
- **Se rechaza lo nuevo** (`MODULO_INACTIVO`): vender, cotizar, comprar, pagar
  a proveedores, gastos, traslados, abrir turnos, ajustes, CAI nuevos...
- **Se permite corregir y terminar lo ya registrado** (lista como datos en
  `interno.modulo_apagado_permite`; solo si el módulo estuvo activo alguna vez):

| Módulo apagado | Qué se puede hacer todavía |
|---|---|
| compras | `anular_compra`, `anular_pago_proveedor`, `anular_saldo_inicial_cxp` |
| inventario | `anular_documento_inventario` (ajuste, traslado, carga inicial) |
| dinero | `anular_operacion_dinero`, `anular_gasto`, `cerrar_turno` (un turno que quedó abierto), `resolver_diferencia`, `confirmar_deposito`, `confirmar_transferencia_venta` |
| ventas | `solicitar_anulacion_venta` y aprobarla (`resolver_aprobacion`), `cancelar_venta` (pendiente), `anular_cotizacion`, `anular_cobro`, `anular_condonacion`, `anular_saldo_inicial_cxc` |
| dinero (0.9.0) | además `confirmar_transferencia_cobro` |
| apartados | `cancelar_apartado` (libera la reserva y resuelve el anticipo) |
| comisiones | `anular_pago_comisiones` |

  Decisión: **pagar** a un proveedor o **aprobar** una venta o un gasto
  pendiente son operaciones nuevas (mueven dinero o inventario): con su módulo
  apagado no se hacen. Para pagar lo que se debe, el proveedor deja `compras`
  activo hasta saldar, o lo enciende un rato.
  Igual, aprobar una venta pendiente la emite: si lleva bienes pide
  `inventario`, y si se cobra al contado pide `dinero` (rechazarla o
  cancelarla sí se puede).
- **Las cuentas del módulo siguen sin asientos manuales** aunque esté apagado
  (Inventario 1.1.03.01, Clientes 1.1.02.01, Proveedores 2.1.01.01,
  Diferencias de caja 1.1.02.04; desde 0.9.0 también Saldos a favor 2.1.04.02
  (ventas), Anticipos de clientes 2.1.04.01 (apartados) y Comisiones por pagar
  2.1.03.04 (comisiones)): `CUENTA_CONTROLADA: ... (ahora apagado)`. Así
  el kardex, la CxC y la CxP siguen iguales a sus cuentas y el módulo se puede
  volver a encender sin `MODULO_CON_SALDO`. `modulo_activo.estuvo_activo` lo
  recuerda (al actualizar a 0.8.0 toda fila que ya existía cuenta como usada).

## Cómo se prueba

`prueba_88_dependencias_modulos.sql` (reglas, servicios sin inventario,
apagar y corregir) y `prueba_89_combinaciones_modulos.sql`: 20 combinaciones
(solo contabilidad, solo servicios, servicios con dinero, ventas sin
inventario con CAI, ventas + inventario sin compras, sin dinero, sin ventas,
todo encendido, y apagar compras / inventario / dinero / fiscal_hn / ventas a
mitad de mes, y encender otros a mitad de mes). En cada una se opera, se
corrige lo apagado y se revisa el cuadre global: debe = haber (total y por
asiento), dinero = subcuentas con rastro, kardex = inventario contable, CxC y
CxP = sus cuentas, ISV por pagar = ventas no anuladas − notas de crédito,
saldo a favor, anticipos y comisiones = sus pasivos, bitácora intacta. Desde
0.9.0 son 20 combinaciones (también todo con apartados y comisiones, apagar
apartados, comisiones o ventas con ellos a mitad de mes, servicios con
comisiones y encenderlos a mitad de mes); en cada una se cobra, se condona, se
devuelve, se aparta y se pagan comisiones. Si una falla, `probar.sh` falla.

## Para un módulo nuevo (por ejemplo comisiones u órdenes de trabajo)

1. `INSERT INTO public.modulo` y sus filas en `public.modulo_dependencia`
   (ejemplo real: comisiones -> ventas; apartados -> ventas e inventario).
2. Sus RPC con `interno.exigir_escritura(empresa, permiso, 'su_modulo')`.
3. Sus correcciones en `interno.modulo_apagado_permite`.
4. Su cuenta controlada (si tiene) en `interno.cuenta_sistema` y su rama en
   `interno.revisar_activacion_modulo` (`MODULO_CON_SALDO`).
5. Sumarlo a `prueba_89` con su cuadre.
