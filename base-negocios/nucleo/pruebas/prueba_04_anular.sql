-- PRUEBA: anular crea contra-asiento, deja saldo en cero y no se anula dos veces
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  r  jsonb;
  an jsonb;
  x  uuid;
  c  uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_asiento(e, '2026-01-15', 'Aporte del dueño',
         pruebas.lineas('1.1.01.01', '3.1.01.02', 50000), gen_random_uuid());
  x := (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.01') = 50000, 'caja = 50000 antes de anular');

  -- Sin motivo: rechazado.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', x, ''), 'FALTA_MOTIVO', 'sin motivo');

  an := public.anular_asiento(x, 'Error de digitación');
  c  := (an->>'asiento_id')::uuid;

  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.01') = 0, 'caja debe quedar en 0');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '3.1.01.02') = 0, 'aportes debe quedar en 0');

  -- Enlace, motivo y estados.
  PERFORM pruebas.afirmar((SELECT anula_asiento_id FROM public.asiento WHERE id = c) = x, 'contra-asiento enlazado');
  PERFORM pruebas.afirmar((SELECT motivo_anulacion FROM public.asiento WHERE id = c) = 'Error de digitación', 'motivo guardado');
  PERFORM pruebas.afirmar((SELECT origen FROM public.asiento WHERE id = c) = 'anulacion', 'origen anulacion');
  PERFORM pruebas.afirmar((SELECT creado_por FROM public.asiento WHERE id = c) = pruebas.usuario('dueno_a'), 'quién anuló');
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_asiento WHERE id = x) = 'anulado', 'original queda anulado');
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_asiento WHERE id = c) = 'anulacion', 'contra-asiento marcado');
  -- El original sigue existiendo, intacto.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE asiento_id = x) = 2, 'original intacto');

  -- No se anula dos veces, ni se anula una anulación.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', x, 'otra vez'), 'YA_ANULADO', 'anular dos veces');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', c, 'anular la anulación'), 'NO_PERMITIDO', 'anular anulación');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', gen_random_uuid(), 'no existe'), 'NO_EXISTE', 'asiento inexistente');

  -- Reintento con el mismo id_operacion: devuelve lo mismo, no duplica.
  r := public.registrar_asiento(e, '2026-01-16', 'Otro', pruebas.lineas('1.1.01.01', '4.1.01.01', 700), gen_random_uuid());
  an := public.anular_asiento((r->>'asiento_id')::uuid, 'Cliente devolvió', 'dddddddd-0000-0000-0000-000000000001');
  PERFORM pruebas.afirmar((public.anular_asiento((r->>'asiento_id')::uuid, 'Cliente devolvió',
                           'dddddddd-0000-0000-0000-000000000001')->>'asiento_id') = an->>'asiento_id', 'reintento de anulación idempotente');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE anula_asiento_id = (r->>'asiento_id')::uuid) = 1, 'una sola anulación');
END $$;
