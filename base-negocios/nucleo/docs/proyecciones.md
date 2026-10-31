# Proyección de flujo de caja (042_proyeccion_flujo) — `contabilidad.ver`

`proyeccion_flujo(empresa, dias 30|60|90, agrupar 'semana')`. Semana 1 = hoy a hoy + 6;
el horizonte llega a hoy + días.

- **Disponible hoy:** cajas, bancos y caja chica. Depósitos en tránsito, transferencias por
  confirmar y POS por liquidar van **aparte** (`no_disponible_aun`) y no se suman.
- **+ Cobros** de CxC (ventas al crédito y saldos iniciales) en la semana de su vencimiento.
  Los **vencidos** van aparte (`cobros_vencidos`) y **no se asumen**.
- **− Pagos** de CxP en la semana de su vencimiento; los vencidos se asumen en la semana 1.
- **− Pagos fijos** con su monto estimado (los atrasados en la semana 1).
- **− Comisiones** y **dividendos por pagar**: semana 1.
- Saldo por semana y `alertas` cuando una semana queda en negativo.

Ejemplo (prueba 122, 30 días): disponible 1,200,000 → 656,000 / 176,000 / −724,000 /
−724,000 / −634,000 con alerta desde la semana 3; 12,345 vencidos aparte.

## 0.16.0

Usuario limitado a su sucursal: dinero de sus cuentas (y las de toda la empresa), cobros de ventas de sus
sucursales, pagos de compras de sus sucursales y pagos fijos que no salen de una cuenta de otra sucursal.
Comisiones y dividendos (de toda la empresa) no entran: `ocultos: ["comisiones", "dividendos"]`,
`solo_mis_sucursales: true` y `nota_sucursal`. Para el dueño, igual que antes.
