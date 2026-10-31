-- PRUEBA: hoy_local() usa la zona horaria de la empresa (America/Tegucigalpa por defecto)
DO $$
DECLARE
  a uuid := pruebas.empresa('A');
  b uuid := pruebas.empresa('B');
BEGIN
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT zona_horaria FROM public.empresa WHERE id = a) = 'America/Tegucigalpa', 'zona por defecto');
  PERFORM pruebas.afirmar(public.hoy_local() = (now() AT TIME ZONE 'America/Tegucigalpa')::date, 'sin empresa: Tegucigalpa');
  PERFORM pruebas.afirmar(public.hoy_local(a) = (now() AT TIME ZONE 'America/Tegucigalpa')::date, 'empresa A: Tegucigalpa');

  -- Dos zonas separadas por 25 horas: la fecha SIEMPRE es distinta.
  UPDATE public.empresa SET zona_horaria = 'Pacific/Kiritimati' WHERE id = a;   -- UTC+14
  UPDATE public.empresa SET zona_horaria = 'Pacific/Pago_Pago'  WHERE id = b;   -- UTC-11
  PERFORM pruebas.afirmar(public.hoy_local(a) = (now() AT TIME ZONE 'Pacific/Kiritimati')::date, 'A usa su zona');
  PERFORM pruebas.afirmar(public.hoy_local(b) = (now() AT TIME ZONE 'Pacific/Pago_Pago')::date, 'B usa su zona');
  PERFORM pruebas.afirmar(public.hoy_local(a) > public.hoy_local(b), 'A siempre va adelante de B');

  -- Sin indicar empresa, toma la del usuario conectado.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(public.hoy_local() = (now() AT TIME ZONE 'Pacific/Kiritimati')::date, 'usuario de A');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar(public.hoy_local() = (now() AT TIME ZONE 'Pacific/Pago_Pago')::date, 'usuario de B');
  -- La anulación sin fecha usa el "hoy" de la empresa.
  PERFORM public.anular_asiento((public.registrar_asiento(b, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 500), gen_random_uuid())->>'asiento_id')::uuid, 'Prueba de zona');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT fecha_contable FROM public.asiento WHERE empresa_id = b AND origen = 'anulacion')
                          = (now() AT TIME ZONE 'Pacific/Pago_Pago')::date, 'anulación con fecha local de B');

  -- Zona inexistente: rechazada.
  PERFORM pruebas.debe_fallar(format('UPDATE public.empresa SET zona_horaria = %L WHERE id = %L', 'Marte/Base_Alfa', a), 'ZONA_INVALIDA', 'zona inventada');
END $$;
