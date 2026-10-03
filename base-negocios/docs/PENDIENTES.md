# Pendientes al pausar (núcleo 0.9.0, 101 pruebas OK)

Estado: etapa 2 terminada. Revisión del revisor hecha. NO pasar a la etapa 3
hasta corregir lo siguiente (en una migración nueva 038+, con pruebas).

## Corregir de la revisión de la etapa 2

GRAVE
1. Saldo a favor de otro cliente u otra empresa: `usar_saldo_favor_lote`
   (034_apartados.sql:70-91) y la venta aceptan `saldo_favor_id` desde la app
   sin revisar cliente ni empresa (034:384-385, 423-434, 606). No aceptar
   `saldo_favor_id` desde la app (solo uso interno del cambio de producto) o
   exigir misma empresa y mismo cliente. Prueba con cliente A / otra empresa.

IMPORTANTE
2. Cajero ve costos en cambio de producto: ocultar `costo_centavos` dentro de
   `venta_cambio` (035:643-644, 028:952; ocultar_costos en 017:210-223 solo
   limpia el primer nivel).
3. Devoluciones parciales: base e ISV por cantidad acumulada (lo que
   corresponde a todo lo devuelto menos lo ya devuelto), 035:549-553. Prueba:
   10 kg a L 11.50 devueltos de 0.5 en 0.5.
4. Tope de descuento también por línea (031:306, 034:485). Prueba: 100 % en
   L 500 dentro de factura de L 20,000.
5. Comisión con condonación (DECIDIDO POR EL DUEÑO): la comisión se calcula
   solo sobre lo realmente cobrado (se resta lo condonado). 036:229.
6. Efectivo de anulaciones y devoluciones de un turno ya cerrado (DECIDIDO
   POR EL DUEÑO): sale del turno abierto de quien hace la operación, a su
   nombre, con referencia al turno original. Nadie puede sacar dinero del
   turno de otro cajero. 033:1003-1009, 035:505-509, 035:360, 025:100.

MENOR
- Vales vencidos: forma de darlos de baja con asiento (033:454-459).
- Devolución pendiente sin destino que queda atascada si el cliente paga antes
  (035:305-308).
- Descuento de factura en monto: diferencia de 1 centavo por línea con precio
  sin ISV (031:263-264).
- `vendedor_id` se puede poner a cualquier usuario activo (034:349): limitar.
- Porcentaje de comisión con fecha "desde" en el pasado (036:315): no permitir.
- Informar al dueño: con base "ganancia", el vendedor puede deducir el costo.

## Después de corregir

1. Revisor confirma las correcciones.
2. Etapa 3: cierre de mes con selector, estados descargables (sin emojis en
   PDF), fondos y reparto de utilidades sobre lo cobrado, proyección de
   cobros y pagos, conciliación bancaria, libros de ISV, Excel de ida y
   vuelta, crecimiento por sucursal, centro de control del dueño, alertas.
3. Etapas 4 a 7: pantallas (PWA), celular y sin internet, prueba real en
   Supabase, preparación para vender.

## Decisiones del dueño pendientes de confirmar

- Límites sugeridos por paquete en docs/PAQUETES.md (los inventó el
  constructor-maestro).
- Valores iniciales de devoluciones, apartados (30 días, anticipo sin mínimo)
  y vales (no vencen).
