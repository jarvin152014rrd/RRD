# Sucursales: usuarios, reportes, envíos y precios (047, núcleo 0.13.0)

## Usuarios por sucursal

`asignar_sucursales_usuario(empresa, usuario, sucursales uuid[], motivo)` (`usuarios.administrar`).

- Lista con sucursales = el usuario solo ve y trabaja en esas. Lista vacía = sin restricción (todas).
- El dueño y el proveedor nunca se restringen. Nadie cambia sus propias sucursales.
- El admin solo cambia cajeros y vendedores (como al desactivar). Si el admin está restringido, solo
  da sucursales que él tiene y nunca "todas" (no amplía su alcance).
- Queda en la bitácora con el motivo (tabla `usuario_sucursal`, nunca se borra: se desactiva).

**Lecturas (en el servidor):** política RLS restrictiva en venta, líneas y pagos de venta, cobro,
turno, gasto, apartado, devolución, compra, caja, bodega, cuenta de dinero, operación de dinero, rastro
del dinero, existencias, kardex, documentos de inventario y conteos. Las vistas "del sistema"
(`v_venta`, `v_existencia`, `v_cobro`, `v_apartado`, etc.) quedan filtradas igual. Lo que es de toda la
empresa (cuentas de dinero sin sucursal, como el banco) se sigue viendo.

**Operaciones (en el servidor):** un trigger revisa la sucursal en cada venta, cobro, turno, gasto,
apartado, devolución, compra, movimiento de kardex y movimiento de dinero. Así toda RPC (vender, cobrar,
abrir turno, gastar, ajustar, trasladar, anular) da `SUCURSAL_NO_PERMITIDA` fuera de su sucursal.
Excepción: la ENTRADA de un traslado a otra sucursal (la manda quien trabaja en el origen).

Para la app: `mi_estado_sesion(empresa)->'sucursales'` (null = todas). Funciones para políticas:
`sucursales_permitidas()`, `bodegas_permitidas()`, `cajas_permitidas()`, `cuentas_dinero_permitidas()`.

## Reporte por sucursal y consolidado

`reporte_sucursales(empresa, desde, hasta)` (máximo un año). Una fila por sucursal que el usuario ve,
la fila "de toda la empresa" (gastos y dinero sin sucursal; solo sin restricción) y `total`:

| dato | cómo se calcula | permiso |
|---|---|---|
| ventas | total con ISV de ventas emitidas no anuladas | ventas.ver |
| ventas sin ISV, costo, ganancia bruta | total − ISV; costo de lo vendido | + inventario.costos |
| gastos | gastos aplicados, sin ISV (sucursal del gasto o de su cuenta) | dinero.ver |
| ganancia | ventas sin ISV − costo − gastos | los tres |
| dinero | saldo al "hasta" de cajas, caja chica y bancos | dinero.ver |

`participacion_ventas_porcentaje` sirve para comparar sucursales lado a lado.

## Envío de dinero entre sucursales

- `enviar_dinero_sucursal(empresa, {"origen_id","destino_id","monto_centavos","fecha"?,"referencia"?,"nota"?,"comprobante"?}, id_operacion)`
  (`dinero.trasladar`): de una caja/caja chica/banco de una sucursal a una de OTRA sucursal. Sale del
  origen y queda en "Envíos entre sucursales" (tránsito). Asiento Dr tránsito / Cr origen, con rastro.
- `recibir_dinero_sucursal(operacion, id_operacion, fecha?, referencia?)`: la sucursal destino confirma
  (Dr destino / Cr tránsito). Una vez. Solo quien trabaja en el destino (o sin restricción).
- Antes de recibirlo se anula con `anular_operacion_dinero` (vuelve al origen).
- `pendientes_entre_sucursales(empresa)`: envíos de dinero y traslados de mercadería sin recibir
  (con días de espera y `puedo_recibir`).

## Traslados de mercadería entre sucursales

`trasladar_inventario` (ya existía) deja en el kardex la salida en el origen y la entrada en el destino,
con el mismo documento. Nuevo: `confirmar_recepcion_traslado(documento, id_operacion, nota?)`
(`inventario.trasladar`, quien trabaja en el destino): solo traslados entre sucursales distintas, una
vez. Si llegó menos, se anota en la nota y se hace un ajuste en la bodega destino.

## Precios por sucursal (opcional)

- `activar_precios_sucursal(empresa, true|false, motivo)`: solo el dueño. Apagado = todos usan el general.
- `fijar_precio_sucursal(empresa, producto, sucursal, precio_centavos, motivo, incluye_isv?)`
  (`productos.precios`). Precio NULL = quitar (vuelve al general). Cada cambio queda en
  `producto_precio` con `sucursal_id` (historial, con motivo).
- `precio_en_sucursal(empresa, producto, sucursal)`: el que se usa y su origen (`sucursal` / `general`).
- Las ventas, apartados y devoluciones con cambio toman el precio de la sucursal de su caja.
  Cotizaciones: precio general.

## Pendiente (honesto)

- HECHO en 0.13.1: `resumen_hoy`, `alertas_activas` y `exportar_plantilla` ya filtran por sucursal (ver
  `alertas.md` y `excel.md`; cuentas por cobrar = ventas al crédito emitidas en sus sucursales) y la
  conciliación exige la sucursal del banco.
- Los demás reportes de toda la empresa (estado de resultados, libros de ISV, `donde_esta_mi_dinero`,
  cierres) NO se filtran por sucursal: dé esos permisos solo a usuarios sin restricción. Vistas que solo suman (`v_ventas_por_dia`, `v_ventas_por_vendedor`, `v_cxc_cliente`,
  `v_saldo_favor`, `v_comision_vendedor`) tampoco.
- Los envíos de dinero sin recibir no salen todavía en `alertas_activas` (sí en `pendientes_entre_sucursales`).
- Traslados entre sucursales: la mercadería cuenta en el destino desde que sale (no hay bodega "en camino").
