# Gastos, aprobaciones, caja chica y pagos fijos (024_gastos) — módulo "dinero"

## Categorías de gasto (dinero.administrar)

`crear_categoria_gasto(empresa, nombre, cuenta)`: cada categoría va a una
cuenta de detalle activa de gasto (6...) o costo (5...).
`desactivar_categoria_gasto` / `reactivar_categoria_gasto (empresa, categoria, motivo)`.

## Gastos — `registrar_gasto(empresa, datos, id_operacion)` (gastos.registrar)

```json
{"cuenta_dinero_id":"<de dónde sale>","categoria_id":"...","monto_centavos":115000,
 "isv_centavos":15000,"descripcion":"Energía de enero","fecha":"2026-01-15",
 "proveedor_id":"...","documento":{"numero":"F-1001","fecha":"2026-01-14","rtn":"0801-1999-000123","cai":"..."},
 "comprobante":{"ruta":"<empresa_id>/gastos/luz.jpg","tipo":"image/jpeg","sha256":"..."}}
```
- Sale de una caja de efectivo, caja chica o banco. Todo o nada.
- `monto_centavos` es el TOTAL pagado; el ISV crédito fiscal va dentro y solo
  con número de factura y RTN del emisor (o proveedor con RTN).
- Asiento: Dr cuenta de la categoría (total − ISV) + Dr 1.1.04.01 ISV crédito
  fiscal / Cr la cuenta de dinero. Ejemplo: 115,000 con ISV 15,000 → 100,000 + 15,000.
- **Topes por puesto:** si el monto pasa lo que el puesto registra sin
  aprobación, el gasto queda `pendiente_aprobacion` **sin mover dinero** y se
  crea su solicitud. El dueño no tiene tope.
- `anular_gasto(gasto, motivo, id_operacion, fecha?)` (gastos.anular):
  aplicado → contra-asiento (el dinero vuelve a su cuenta); pendiente → se
  cancela (también lo cancela quien lo pidió).

## Aprobaciones (tabla genérica `aprobacion`)

Tipo, documento, monto, solicitante, aprobador, estado (`pendiente`,
`aprobada`, `rechazada`, `cancelada`) y motivo. Hoy la usa el gasto; la
etapa 2b-2 la usará para crédito, descuentos y anulación de ventas.

`resolver_aprobacion(aprobacion, aprobar, motivo, id_operacion, fecha?)` (0.9.2: un sexto parámetro opcional, `cuenta_salida_id`, solo para anular ventas; ver `caja.md`):
- Gasto: pide gastos.aprobar y el monto dentro de lo que su puesto aprueba
  (`TOPE_APROBACION`); el dueño sin tope. Nadie resuelve lo que él pidió (salvo el dueño).
- Rechazar pide motivo. Aprobar mueve el dinero con la fecha del gasto (o
  `fecha`, si ese mes ya cerró). Una sola vez (`YA_RESUELTO`).
- Vistas `v_gasto` y `v_aprobacion` (dinero.ver / aprobaciones.ver; cada
  quien ve lo que pidió).

**Topes** — `configurar_tope_rol(empresa, rol, 'gasto', sin_aprobacion_centavos, aprueba_hasta_centavos, motivo)`
(solo el dueño). Por defecto: admin registra y aprueba hasta L 5,000.00; los
demás puestos 0 (todo gasto suyo pide aprobación y no aprueban).

## Caja chica

- Cuenta de dinero `caja_chica` con fondo fijo (tope). Nunca pasa su fondo.
- Gastos de caja chica: `registrar_gasto` con esa cuenta (con o sin comprobante).
- `cuadre_caja_chica(cuenta, contado?)` (dinero.ver), desde la última reposición:
  fondo, efectivo esperado (saldo), gastos del ciclo con y sin comprobante,
  fondo − gastos, por reponer y diferencia contra lo contado.
  Ejemplo (prueba 65): fondo 200,000; gastos 30,000 (con comprobante) + 20,000
  (sin) → esperado 150,000; por reponer 50,000.
- Reposición: `trasladar_dinero` tipo `reposicion_caja_chica` (sin monto repone lo gastado).

## Pagos fijos (dinero.administrar para plantillas, gastos.registrar para pagar)

- `crear_pago_fijo(empresa, datos)` / `editar_pago_fijo(empresa, id, datos, motivo)`
  (`"activo": false` lo desactiva):
  ```json
  {"nombre":"Alquiler del local","categoria_id":"...","monto_estimado_centavos":500000,
   "frecuencia":"mensual","cada":1,"dia":5,"fecha_inicio":"2026-01-01","cuenta_dinero_id":"<sugerida>"}
  ```
  `mensual`: día del mes (si el mes es más corto, el último día) cada 1-12
  meses. `semanal`: día de la semana (1 lunes .. 7 domingo) cada 1-52 semanas.
- `pagos_fijos_proximos(empresa)` (dinero.ver): próximo vencimiento sin pagar,
  días (negativo = vencido), cuántos atrasados y estado (`vencido`,
  `proximo` = 7 días o menos, `al_dia`).
- `registrar_pago_fijo(pago_fijo, datos, id_operacion)`: genera un **gasto real
  con el monto real** (`monto_centavos` obligatorio; nunca se descuenta solo).
  Paga el vencimiento más antiguo sin pagar o el indicado en `vence_el`; un
  vencimiento se paga una sola vez. Respeta los topes como cualquier gasto.
- `reporte_pagos_fijos(empresa, año, mes)`: total mensual estimado (mensual =
  monto / cada; semanal = monto × 52 / 12 / cada) y lo pagado en el mes.

## 0.7.0

- `"impuesto": "ISV15"` (código de la tabla de impuestos) en vez de `"isv_centavos"`: el crédito
  fiscal se calcula del total (115,000 → 15,000). Sigue pidiendo factura y RTN.
- **Doble aprobación** (`empresa.doble_aprobacion`): una solicitud nueva necesita dos personas
  distintas (ninguna es quien pidió); la primera queda anotada (`falta_segunda_aprobacion`) y el
  dinero no se mueve hasta la segunda; el dueño aprueba solo; un rechazo basta. Las solicitudes de
  antes de activarla siguen con una. `v_aprobacion` muestra la primera aprobación.
- `resolver_aprobacion` también resuelve ventas (descuento / crédito) y anulaciones de venta (ver `ventas.md`).
