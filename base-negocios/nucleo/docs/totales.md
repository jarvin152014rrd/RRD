# Lecturas de totales (052, núcleo 0.16.0)

Para que la app no sume en el navegador (allí solo llegan 300 o 1,000 filas). Son solo de lectura,
`SECURITY DEFINER`, revisan empresa y permiso (`exigir_lectura`) y, a un usuario limitado a su sucursal, cuentan
solo sus sucursales (`solo_mis_sucursales: true`). Fechas `desde`/`hasta` obligatorias (`FECHA_INVALIDA`).

## `totales_compras(empresa, desde, hasta, proveedor?)` — compras.ver

Compras con fecha en el rango.

| clave | qué es |
|---|---|
| `cantidad`, `vigentes`, `anuladas` | cuántas compras |
| `total_centavos`, `subtotal_centavos`, `isv_centavos` | de las NO anuladas |
| `contado_centavos`, `credito_centavos` | de las no anuladas, por condición |
| `por_pagar_centavos` (`por_pagar_cantidad`) | lo que falta pagar de las no anuladas al crédito (pagos anulados no cuentan) |
| `vencido_centavos` | la parte de eso ya vencida hoy |

Ejemplo (prueba 133): F-INI-1 al crédito 544,000 (475,000 + ISV 69,000; su pago de 100,000 se anuló) y F-N-1 de la
Norte 11,500 con 1,500 pagados: el dueño ve 555,500 comprado y 554,000 por pagar; el admin de la Norte, 11,500 y
10,000. Cuadra con la suma de `compra` y `v_cxp_documento` que cada uno ve.

## `totales_gastos(empresa, desde, hasta, categoria?, cuenta_dinero?)` — dinero.ver

Gastos con fecha en el rango (los mismos que ve `v_gasto`): `gastado_centavos` (aplicados, con ISV),
`gastado_sin_isv_centavos`, `gastado_isv_centavos`, `aplicados`; `en_espera_centavos` / `en_espera` (pendientes de
aprobación: todavía no sale dinero); `rechazados`, `anulados`, `cantidad`.

Ejemplo (prueba 133): admin de la Norte 1,000 (caja Norte) y 700 en espera; dueño 500 (Caja 1) y 2,000 (banco de
toda la empresa). El admin ve 3,000 gastado y 700 en espera; el dueño 3,500 y 700.

## `mas_vendido(empresa, desde, hasta, limite 10)` — ventas.ver (máximo un año)

Por producto, con ISV: `cantidad_vendida` / `total_vendido_centavos` (ventas emitidas con fecha en el rango; las
anuladas no), `cantidad_devuelta` / `total_devuelto_centavos` (devoluciones aplicadas con fecha en el rango) y
`cantidad_neta` / `total_neto_centavos`. `filas` ordenadas por total neto (hasta `limite`, 1 a 1000); `total` es de
TODOS los productos; `hay_mas` si quedaron productos fuera.

Ejemplo (prueba 133): tornillos 2 + 4 + 2 + 1 = 9 (13,500) y 1 devuelto (1,500): neto 8 (12,000); mano de obra
23,000. Total neto 35,000. El admin de la Norte: tornillos 5, neto 6,000; total 29,000.
