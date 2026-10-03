-- PRUEBA: los meses se cierran en orden (no meses futuros ni el mes en curso) y se reabren del último hacia atrás
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  hoy date;
  r   jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  hoy := public.hoy_local(e);
  PERFORM pruebas.afirmar(hoy >= '2026-05-01', 'esta prueba usa enero a abril de 2026 como meses pasados');

  -- Movimientos en enero y marzo; febrero vacío.
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Venta enero', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());
  PERFORM public.registrar_asiento(e, '2026-03-05', 'Venta marzo', pruebas.lineas('1.1.01.01', '4.1.01.01', 2000), gen_random_uuid());

  -- No se salta un mes con movimientos.
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 3)', e), 'MES_ANTERIOR_ABIERTO: primero cierre el mes 01/2026', 'cerrar marzo con enero abierto');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 2)', e), 'MES_ANTERIOR_ABIERTO', 'cerrar febrero con enero abierto');

  -- Mes en curso, mes futuro, antes del inicio, mes inválido.
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, %s, %s)', e, extract(year FROM hoy), extract(month FROM hoy)), 'MES_NO_TERMINADO', 'mes en curso');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, %s, %s)', e, extract(year FROM hoy + 40), extract(month FROM hoy + 40)), 'MES_NO_TERMINADO', 'mes futuro');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2025, 12)', e), 'FECHA_ANTERIOR_AL_INICIO', 'antes del inicio');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 13)', e), 'PERIODO_INVALIDO', 'mes 13');

  -- En orden: enero, luego marzo (febrero vacío se cierra solo).
  r := public.cerrar_periodo(e, 2026, 1);
  PERFORM pruebas.afirmar((r->>'meses_vacios_cerrados')::int = 0, 'enero sin vacíos previos');
  r := public.cerrar_periodo(e, 2026, 3);
  PERFORM pruebas.afirmar((r->>'meses_vacios_cerrados')::int = 1, 'febrero vacío cerrado solo');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 2) = 'cerrado', 'febrero cerrado');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-02-15', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'PERIODO_CERRADO', 'febrero ya no recibe');

  -- Reabrir: solo el último cerrado (marzo), luego hacia atrás.
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L)', e, 'corregir enero'), 'REABRIR_EN_ORDEN: primero reabra el mes 03/2026', 'reabrir enero primero');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 2, %L)', e, 'corregir febrero'), 'REABRIR_EN_ORDEN', 'reabrir febrero primero');
  PERFORM public.reabrir_periodo(e, 2026, 3, 'Falta una factura de marzo');
  PERFORM public.reabrir_periodo(e, 2026, 2, 'Falta una compra de febrero');
  PERFORM public.registrar_asiento(e, '2026-02-15', 'Compra tardía', pruebas.lineas('5.1.01.01', '2.1.01.01', 500), gen_random_uuid());

  -- Ahora febrero tiene movimientos: marzo no cierra antes que febrero.
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 3)', e), 'MES_ANTERIOR_ABIERTO: primero cierre el mes 02/2026', 'marzo antes que febrero');
  PERFORM public.cerrar_periodo(e, 2026, 2);
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 4)', e), 'MES_ANTERIOR_ABIERTO: primero cierre el mes 03/2026', 'abril con marzo abierto');
  r := public.cerrar_periodo(e, 2026, 3);
  PERFORM pruebas.afirmar((r->>'meses_vacios_cerrados')::int = 0 AND NOT (r->>'ya_estaba')::boolean, 'marzo cerrado en orden');
END $$;

-- Empresa B (sin movimientos): al cerrar abril, enero a marzo se cierran solos
-- y queda en bitácora con su motivo.
DO $$
DECLARE
  b uuid := pruebas.empresa('B');
  r jsonb;
BEGIN
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(b, '2026-04-10', 'Venta abril', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  r := public.cerrar_periodo(b, 2026, 4);
  PERFORM pruebas.afirmar((r->>'meses_vacios_cerrados')::int = 3, 'enero a marzo cerrados solos');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.periodo WHERE empresa_id = b AND anio = 2026 AND mes BETWEEN 1 AND 4 AND estado = 'cerrado') = 4, 'enero a abril cerrados');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = b AND tabla = 'periodo'
                           AND motivo LIKE 'Cierre automático: mes sin movimientos, al cerrar 04/2026') = 3, 'cierres automáticos en bitácora con motivo');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = b AND tabla = 'periodo'
                           AND (despues->>'mes')::int = 4 AND despues->>'estado' = 'cerrado' AND motivo IS NULL), 'el cierre pedido no hereda el motivo automático');
END $$;
