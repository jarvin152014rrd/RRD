-- PRUEBA: la fecha contable no puede ser anterior al inicio de la empresa ni más de N días al futuro (N por empresa, 3 por defecto)
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  hoy date;
  r   jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  hoy := public.hoy_local(e);
  PERFORM pruebas.afirmar((SELECT dias_futuro_max FROM public.empresa WHERE id = e) = 3, 'defecto 3 días');

  -- Antes del inicio (01/01/2026).
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2025-12-31', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FECHA_ANTERIOR_AL_INICIO', 'un día antes del inicio');
  r := public.registrar_asiento(e, '2026-01-01', 'Primer día', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'numero')::int = 1, 'el día de inicio sí');

  -- Futuro: hoy + 3 sí, hoy + 4 no.
  PERFORM public.registrar_asiento(e, hoy + 3, 'Cheque posfechado', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, hoy + 4, pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FECHA_MUY_FUTURA', 'hoy + 4');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2099-01-01', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FECHA_MUY_FUTURA', 'año 2099');
  -- Anular con fecha fuera de rango tampoco.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L, NULL, %L)', r->>'asiento_id', 'fecha mala', '2025-06-01'), 'FECHA_ANTERIOR_AL_INICIO', 'anular antes del inicio');

  -- Configurable por empresa: 0 días = solo hasta hoy.
  PERFORM pruebas.como('superusuario');
  UPDATE public.empresa SET dias_futuro_max = 0 WHERE id = e;
  PERFORM pruebas.debe_fallar(format('UPDATE public.empresa SET dias_futuro_max = 40 WHERE id = %L', e), '23514', 'más de 31 días no');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, hoy, 'Hoy', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, hoy + 1, pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FECHA_MUY_FUTURA', 'mañana con 0 días');
  -- La otra empresa conserva sus 3 días.
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(pruebas.empresa('B'), public.hoy_local() + 3, 'B posfechado', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());

  -- Ni a la fuerza (superusuario sin funciones).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format(
    'INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion, id_operacion, total_centavos)
     SELECT %L, id, 999, %L, %L, gen_random_uuid(), 1 FROM public.sucursal WHERE empresa_id = %L',
     e, '2020-05-05', 'trampa', e), 'FECHA_ANTERIOR_AL_INICIO', 'superusuario antes del inicio');
END $$;
