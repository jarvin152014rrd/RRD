-- PRUEBA: un id_operacion repetido (reintento / sin internet) no duplica el asiento
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  op uuid := 'eeeeeeee-0000-0000-0000-000000000001';
  r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  r1 := public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 2500), op);
  r2 := public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 2500), op);
  -- Aunque el reintento traiga otros datos, se devuelve lo ya guardado.
  r3 := public.registrar_asiento(e, '2026-01-10', 'Venta cambiada', pruebas.lineas('1.1.01.01', '4.1.01.01', 9999), op);

  PERFORM pruebas.afirmar((r1->>'duplicado')::boolean = false, 'el primero no es duplicado');
  PERFORM pruebas.afirmar((r2->>'duplicado')::boolean = true,  'el segundo es duplicado');
  PERFORM pruebas.afirmar(r2->>'asiento_id' = r1->>'asiento_id' AND r3->>'asiento_id' = r1->>'asiento_id', 'mismo asiento');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE id_operacion = op) = 1, 'un solo asiento');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.01') = 2500, 'el saldo no se duplicó');

  -- El contador no saltó números por los reintentos.
  r4 := public.registrar_asiento(e, '2026-01-10', 'Otra venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  PERFORM pruebas.afirmar((r4->>'numero')::bigint = 2, 'numeración sin huecos');

  -- Sin id_operacion: rechazado.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L::jsonb, NULL)',
    e, '2026-01-10', 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'FALTA_ID_OPERACION', 'sin id_operacion');
END $$;
