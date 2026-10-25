# Antigüedad de saldos (054_mayorista_garantias_cheques_antiguedad, núcleo 0.18.0)

`antiguedad_saldos(empresa, al?, tipo?)` — lectura.

- `tipo`: `"cxc"` (por defecto: lo que deben los clientes; pide `ventas.ver` o `cobros.ver_saldos`) o `"cxp"` (lo que
  se debe a proveedores; `compras.ver`). `al`: fecha de corte (por defecto hoy).
- Documentos tal como estaban a esa fecha (`interno.cxc_al` / `interno.cxp_al`): ventas o compras al crédito y
  **saldos iniciales**, menos cobros / pagos / condonaciones / notas de crédito hasta esa fecha.
- Tramos por días **VENCIDO** a la fecha de corte (vencimiento = el del documento; sin vencimiento, su fecha):
  `corriente` (todavía no vence, incluido el día que vence), `de_1_a_30`, `de_31_a_60`, `de_61_a_90`, `mas_de_90`.
- Respuesta: `terceros` (por cliente o proveedor, del mayor saldo al menor, con cada tramo, `vencido_centavos` y
  `dias_vencido_max`), `totales`, `documentos` (cada factura con su tramo), `tramos` (títulos), y para quien ve toda
  la empresa `cuenta_libros`, `saldo_libros_centavos` y **`cuadra`** (total = saldo de Clientes 1.1.02.01 o de
  Proveedores en los libros a esa fecha).
- Usuario limitado a su sucursal: solo documentos de sus sucursales, sin saldos iniciales (son de toda la empresa),
  `solo_mis_sucursales: true` y sin `cuadra`.

Diferencia con `v_cxc_cliente` (0-30, 31-60... desde la FECHA de la factura): aquí se cuenta desde el VENCIMIENTO.

Ejemplo (prueba 144): V_ENE_2 vence el 11/02 con saldo 25,000; saldo inicial de 30,000 vencido el 20/12/2025. Al
01/03/2026: 1-30 = 25,000 (18 días) y 61-90 = 30,000 (71 días); total 55,000 = Clientes en los libros.
