-- PRUEBA: (0.9.1, menor) el porcentaje de comisión no es retroactivo: "desde" es hoy o una fecha futura (FECHA_INVALIDA si es pasada); lo ya vendido conserva su porcentaje y una venta de hoy toma el vigente hoy
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  ven  uuid := pruebas.usuario('vendedor_a');
  hoy  date;
  v    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de porcentaje');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  hoy := public.hoy_local(e);
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "precio"}', 'Comisión sobre el precio');

  PERFORM pruebas.debe_fallar(format('SELECT public.fijar_porcentaje_comision(%L, %L, 10, %L, %L)', e, ven, hoy - 1, 'Desde ayer'),
    'FECHA_INVALIDA', 'no retroactivo (ayer)');
  PERFORM pruebas.debe_fallar(format('SELECT public.fijar_porcentaje_comision(%L, %L, 10, %L, %L)', e, ven, '2026-01-01', 'Desde enero'),
    'FECHA_INVALIDA', 'no retroactivo (enero)');
  PERFORM public.fijar_porcentaje_comision(e, ven, 10, NULL, 'Desde hoy');          -- hoy
  PERFORM public.fijar_porcentaje_comision(e, ven, 20, hoy + 10, 'Sube en 10 días'); -- futuro

  -- Venta de hoy, 1 tornillo (1,304 sin ISV): 10 % = round(130.4) = 130 (el 20 % todavía no vale).
  v := public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', ven), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v->>'venta_id')::uuid) = 130,
    'venta de hoy al 10 %');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.comision_porcentaje WHERE empresa_id = e AND user_id = ven AND desde < hoy) = 0,
    'nada quedó en el pasado');
END $$;
