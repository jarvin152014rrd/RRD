-- PRUEBA: reabrir (o cerrar) un mes sin permiso falla; con permiso queda en bitácora con motivo
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_periodo(e, 2026, 4);

  PERFORM pruebas.como('admin_a');     -- el admin cierra pero NO reabre
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 4, %L)', e, 'quiero reabrir'), 'SIN_PERMISO', 'admin reabre');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 4, %L)', e, 'quiero reabrir'), 'SIN_PERMISO', 'cajero reabre');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 5)', e), 'SIN_PERMISO', 'cajero cierra');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 4, %L)', e, 'quiero reabrir'), 'SIN_PERMISO', 'vendedor reabre');

  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 4, %L)', e, ''), 'FALTA_MOTIVO', 'reabrir sin motivo');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 4) = 'cerrado', 'sigue cerrado');

  PERFORM public.reabrir_periodo(e, 2026, 4, 'Corrección autorizada por el contador');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 4) = 'abierto', 'reabierto');

  -- Cierre y reapertura auditados (quién, motivo).
  PERFORM pruebas.afirmar(EXISTS (
    SELECT 1 FROM public.bitacora b
    WHERE b.empresa_id = e AND b.tabla = 'periodo' AND b.accion = 'UPDATE'
      AND b.despues->>'estado' = 'cerrado' AND b.usuario_id = pruebas.usuario('dueno_a')), 'cierre en bitácora');
  PERFORM pruebas.afirmar(EXISTS (
    SELECT 1 FROM public.bitacora b
    WHERE b.empresa_id = e AND b.tabla = 'periodo' AND b.accion = 'UPDATE'
      AND b.antes->>'estado' = 'cerrado' AND b.despues->>'estado' = 'abierto'
      AND b.motivo = 'Corrección autorizada por el contador'
      AND b.usuario_id = pruebas.usuario('dueno_a')), 'reapertura en bitácora con motivo');
END $$;
