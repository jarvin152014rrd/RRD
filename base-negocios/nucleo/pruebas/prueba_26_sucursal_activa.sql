-- PRUEBA: solo se registra en una sucursal activa de la empresa; sin sucursal activa el error es claro
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s001 uuid;
  s002 uuid;
  sb   uuid;
  r    jsonb;
  x    uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  SELECT id INTO sb   FROM public.sucursal WHERE empresa_id = pruebas.empresa('B');

  PERFORM pruebas.como('dueno_a');
  s002 := (public.crear_sucursal(e, '002', 'Sucursal Centro')->>'sucursal_id')::uuid;

  -- Indicando la sucursal 002 (activa): se guarda en esa.
  r := public.registrar_asiento(e, '2026-01-10', 'Venta en Centro', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid(), s002);
  PERFORM pruebas.afirmar((SELECT sucursal_id FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = s002, 'guardado en 002');
  -- Sin indicar: la primera activa (001).
  r := public.registrar_asiento(e, '2026-01-10', 'Venta en Principal', pruebas.lineas('1.1.01.01', '4.1.01.01', 2000), gen_random_uuid());
  x := (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar((SELECT sucursal_id FROM public.asiento WHERE id = x) = s001, 'por defecto 001');

  -- Sucursal de otra empresa o inventada: rechazada.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L::jsonb, gen_random_uuid(), %L)',
    e, '2026-01-10', 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), sb), 'SUCURSAL_INVALIDA', 'sucursal de B');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L::jsonb, gen_random_uuid(), %L)',
    e, '2026-01-10', 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid()), 'SUCURSAL_INVALIDA', 'sucursal inventada');

  -- Desactivada: rechazada.
  PERFORM public.desactivar_sucursal(e, s002, 'Se cerró el local del centro');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L::jsonb, gen_random_uuid(), %L)',
    e, '2026-01-10', 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), s002), 'SUCURSAL_INVALIDA', 'sucursal desactivada');

  -- La última activa no se puede desactivar por la app.
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_sucursal(%L, %L, %L)', e, s001, 'cerrar todo'), 'ULTIMA_SUCURSAL', 'última sucursal');

  -- Si aun así no queda ninguna activa (a la fuerza): error claro.
  PERFORM pruebas.como('superusuario');
  UPDATE public.sucursal SET activa = false WHERE id = s001;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_SUCURSAL_ACTIVA', 'sin sucursal activa');

  -- Anular un asiento de una sucursal ya desactivada SÍ se puede (corregir siempre es posible).
  r := public.anular_asiento(x, 'Venta duplicada');
  PERFORM pruebas.afirmar((SELECT sucursal_id FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = s001, 'anulación en la sucursal original');
END $$;
