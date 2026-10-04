# Reportes (011_reportes)

`saldo_cuentas(empresa, desde, hasta)` — por cada cuenta de detalle:
`saldo_inicial_centavos` (antes de `desde`), `debe_centavos`,
`haber_centavos`, `movimiento_centavos` y `saldo_final_centavos` (hasta
`hasta`, incluido). Saldos positivos según la naturaleza de la cuenta.
`desde` vacío = desde el principio.

- Estado de resultados del mes: `movimiento` de ingreso, costo y gasto.
- Balance al cierre del mes: `saldo_final` de activo, pasivo y patrimonio
  (+ resultado acumulado).
- Una anulación cuenta en la fecha del contra-asiento.

Permiso `contabilidad.ver` (o `service_role`).

**0.10.0:** estados del mes ya armados (resultados, balance, flujo, CxC, CxP, inventario,
dinero, ISV), comparativo y exportación: `estados.md`. Proyección: `proyecciones.md`.
