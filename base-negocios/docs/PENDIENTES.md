# Pendientes (núcleo 0.9.1, 113 pruebas OK)

Estado: etapa 2 terminada. Las correcciones de la revisión de la etapa 2 están
HECHAS en la migración 038 (núcleo 0.9.1), cada una con su prueba (falla
contra 0.9.0 y pasa con 0.9.1). Falta que el revisor las confirme antes de la
etapa 3.

## Corregir de la revisión de la etapa 2

GRAVE
1. HECHO (prueba 102). Saldo a favor de otro cliente u otra empresa: la venta
   ya no acepta `saldo_favor_id` desde la app (solo el cambio de producto usa
   su lote) y `usar_saldo_favor_lote` exige misma empresa y mismo cliente.

IMPORTANTE
2. HECHO (prueba 103). Cajero ve costos en cambio de producto:
   `ocultar_costos` limpia todos los niveles (`interno.quitar_claves`).
3. HECHO (prueba 104). Devoluciones parciales por cantidad acumulada (10 kg a
   L 11.50 devueltos de 0.5 en 0.5: ISV 86/87 por nota, exacto al final).
4. HECHO (prueba 105). Tope de descuento también por línea (vender, apartar y
   aprobar). 100 % en L 500 dentro de L 20,000 pide aprobación.
5. HECHO (prueba 106). Comisión solo sobre lo realmente cobrado (se resta la
   parte sin ISV de lo condonado). Decisión del dueño.
6. HECHO (prueba 107). Efectivo de anulaciones y devoluciones: sale del turno
   abierto de quien hace la operación, a su nombre, con referencia al turno
   original (`dinero_movimiento.turno_origen_id`); nadie saca dinero del turno
   de otro cajero (`TURNO_AJENO`). Decisión del dueño.

MENOR
- HECHO (prueba 108). Vales vencidos: `dar_baja_vales_vencidos` (solo el
  dueño, permiso `cobros.baja_vales`, motivo y bitácora; asiento a 4.2.01.04).
- HECHO (prueba 109). Devolución pendiente atascada:
  `definir_destino_devolucion` y se vuelve a aprobar (o se rechaza; el error
  lo explica).
- HECHO (prueba 110). Descuento de factura en monto: exacto al centavo.
- HECHO (prueba 111). `vendedor_id`: solo usuarios activos con puesto que vende.
- HECHO (prueba 112). Porcentaje de comisión no retroactivo (desde >= hoy).
- HECHO (nucleo/docs/comisiones.md). Aviso al dueño: con base "ganancia" el
  vendedor puede deducir el costo.

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
- 0.9.1: la baja de vales vencidos la hace el dueño a mano cuando decide (no es
  automática) y no se anula; confirmar que así lo quiere.
- 0.9.1: una anulación pedida por un cajero cuyo turno sigue abierto saca el
  efectivo de ese turno al aprobarla (el cajero lo entrega); si ya cerró, sale
  del turno de quien aprueba. Confirmar.
