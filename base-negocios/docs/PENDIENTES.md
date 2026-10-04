# Pendientes (núcleo 0.11.0, 126 pruebas OK)

Estado: etapa 2 terminada. Las correcciones de la revisión de la etapa 2 están
HECHAS en la migración 038 (núcleo 0.9.1) y las de la revisión de 0.9.1 en la
migración 039 (núcleo 0.9.2), cada una con su prueba (falla contra la versión
anterior y pasa con la nueva). Falta que el revisor las confirme antes de la
etapa 3.

## Etapa 3a (HECHA en 0.10.0, migraciones 040-042, pruebas 120-123)

- HECHO: cierre de mes con foto inmutable, advertencias, versiones al reabrir (`cierres.md`).
- HECHO: selector de meses (foto o "preliminar"), comparativo, utilidad cobrada vs facturada,
  exportación JSON para PDF/Excel (`estados.md`).
- HECHO: módulo `fondos` (socios, fondos con meta, regla, reparto, uso con aprobación del dueño,
  dividendos) (`fondos.md`).
- HECHO: proyección de flujo por semana con alerta (`proyecciones.md`).
- HECHO: prueba 89 con 25 combinaciones (fondos encendido, apagado y a mitad de mes) y cierre de enero
  en cada una cuadrando con los libros.
- FALTA: que el revisor revise 0.10.0 y que un contador hondureño valide los formatos (resultados,
  balance, flujo, ISV para la SAR).
- FALTA (menor): anular un uso de fondo ya aplicado (hoy lo corrige el contador con un asiento); cierre
  anual (pasar el resultado del año a utilidades acumuladas).
- Siguiente (etapa 3b): ver "Etapa 3b-1" arriba.

## Etapa 3b-1 (HECHA en 0.11.0, migraciones 043-045, pruebas 124-126)

- HECHO: conciliación bancaria (módulo `conciliacion`): cargar estado de cuenta, emparejar automático y a mano,
  deshacer con motivo, diferencias, crear comisión e intereses, cierre por mes (`conciliacion.md`).
- HECHO: libros de ISV de ventas y compras por mes, cuadrados con `isv_mes` (`libros_isv.md`).
- HECHO: alertas en un solo lugar con permisos y preferencias por usuario; "Mi negocio hoy" con ganancia de hoy
  y del mes (`alertas.md`).
- FALTA: que el revisor revise 0.11.0 y que un contador valide los libros de ISV (formato SAR).
- FALTA (menor): emparejar varias filas del banco contra un movimiento; anular un movimiento creado desde la
  conciliación; guardar el CAI del proveedor en las compras.
- Siguiente (etapa 3b-2): Excel de ida y vuelta, crecimiento por sucursal, resto del centro de control del dueño.

## Decisiones del dueño para el final

- Precio de venta del producto: se decide al final, decisión del dueño.

## Corregir de la revisión de 0.9.1 (todo HECHO en 0.9.2)

IMPORTANTE
1. HECHO (prueba 114). Vendedor heredado: la regla de `vendedor_id` solo vale
   cuando se elige en el momento; al completar un apartado o convertir una
   cotización se respeta el vendedor del documento (aunque esté dado de baja o
   su puesto solo cotice). Su comisión se genera igual; el dueño decide al liquidar.

MENOR
2. HECHO (prueba 115). Cuenta de salida elegida: `anular_cobro` y
   `resolver_aprobacion` (anular venta) aceptan `cuenta_salida_id` (caja fuerte,
   banco, caja chica o turno propio); nunca el turno de otro cajero.
3. HECHO (prueba 116; 119 para ventas de antes). El porcentaje de comisión
   queda guardado en la venta al emitirla y se usa al devengar.
4. HECHO (prueba 117). `definir_destino_devolucion` pone el destino actual en
   la solicitud de aprobación y reinicia una primera aprobación.
5. HECHO (prueba 118). Tope por línea con 2 centavos de tolerancia.

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
2. Etapa 3: 3a HECHA en 0.10.0 y 3b-1 en 0.11.0 (ver arriba). Falta 3b-2: Excel
   de ida y vuelta, crecimiento por sucursal, resto del centro de control del dueño.
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
- 0.9.2: la comisión de un vendedor dado de baja se genera igual (recomendado) y
  el dueño decide al liquidar; si no la paga, hoy la corrige el contador con un
  asiento (no hay función para anularla). Confirmar.
- 0.10.0 [DINERO]: utilidad cobrada = utilidad neta − aumento de la utilidad por cobrar (margen
  proporcional al saldo de cada factura al crédito). Confirmar que así se quiere repartir.
- 0.10.0 [DINERO]: el reparto usa la foto del cierre; si el mes se reabre y cambia, el reparto queda y el
  nuevo cierre lo advierte (el dueño decide anular y repartir otra vez). Confirmar.
- 0.10.0 [DINERO]: usar un fondo lo decide solo el dueño (otro puesto solo lo pide si el dueño le da el
  permiso); el gasto pasa por los resultados del mes. Confirmar.
- 0.10.0 [DINERO]: proyección conservadora (CxP vencidas, comisiones y dividendos en la semana 1; cobros
  vencidos no se asumen; POS por liquidar no cuenta como disponible). Confirmar.
- 0.10.0: el cierre bloquea solo con descuadre contable; un módulo que no cuadra con su cuenta sale como
  "alerta de cuadre" sin bloquear (así lo dice REQUISITOS). Confirmar.
- 0.11.0: conciliación uno a uno con 3 días de tolerancia; una conciliación cerrada no se reabre. Confirmar.
- 0.11.0 [DINERO]: "ganancia de hoy" = ventas sin ISV − costo; "ganancia del mes" = ventas − costo − gastos del 1 a
  hoy (de los libros); "ventas de hoy" con ISV. Confirmar.
- 0.11.0: alertas — cierre del mes pasado se espera hasta el día 10; licencia avisa 15 días antes. Confirmar.
