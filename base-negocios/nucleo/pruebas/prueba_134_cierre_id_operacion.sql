-- PRUEBA: (0.16.0) cerrar_mes y reabrir_periodo con id_operacion opcional: el reintento con el mismo id devuelve lo mismo sin hacer nada (duplicado); el mismo id para otro mes u otra operación da ID_OPERACION_USADO; las llamadas de antes (sin id) siguen igual; queda el registro (periodo_operacion) que no se edita ni se borra; permisos de siempre
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  r   jsonb;
  r2  jsonb;
  id1 uuid := gen_random_uuid();
  id2 uuid := gen_random_uuid();
BEGIN
  PERFORM pruebas.preparar_enero();

  -- Cerrar enero con id: una vez; el reintento devuelve la misma foto.
  r := public.cerrar_mes(e, 2026, 1, 'Cierre de enero', id1);
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrado' AND NOT (r->>'duplicado')::boolean AND NOT (r->>'ya_estaba')::boolean, 'cerrado: ' || r::text);
  r2 := public.cerrar_mes(e, 2026, 1, 'Cierre de enero', id1);
  PERFORM pruebas.afirmar((r2->>'duplicado')::boolean AND r2->>'cierre_id' = r->>'cierre_id' AND (r2 - 'duplicado') = (r - 'duplicado'), 'reintento = lo mismo');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cierre WHERE empresa_id = e AND anio = 2026 AND mes = 1) = 1, 'una sola foto');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 2, NULL, %L)', e, id1), 'ID_OPERACION_USADO', 'mismo id para otro mes');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L, %L)', e, 'Corregir enero', id1), 'ID_OPERACION_USADO', 'mismo id para reabrir');
  -- La llamada de antes (sin id) sigue igual: ya estaba.
  r2 := public.cerrar_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((r2->>'ya_estaba')::boolean AND NOT r2 ? 'duplicado', 'sin id: como antes');

  -- Reabrir con id (solo el dueño): una vez; el reintento no hace nada más.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L, gen_random_uuid())', e, 'Corregir enero'), 'SIN_PERMISO', 'el admin no reabre');
  PERFORM pruebas.como('dueno_a');
  r := public.reabrir_periodo(e, 2026, 1, 'Corregir enero', id2);
  PERFORM pruebas.afirmar(r->>'estado' = 'abierto' AND NOT (r->>'ya_estaba')::boolean AND NOT (r->>'duplicado')::boolean, 'reabierto');
  r2 := public.reabrir_periodo(e, 2026, 1, 'Corregir enero', id2);
  PERFORM pruebas.afirmar((r2->>'duplicado')::boolean AND NOT (r2->>'ya_estaba')::boolean, 'reintento: la misma respuesta');
  PERFORM pruebas.afirmar((SELECT estado FROM public.cierre WHERE empresa_id = e AND anio = 2026 AND mes = 1) = 'superada', 'la foto queda superada');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 1, NULL, %L)', e, id2), 'ID_OPERACION_USADO', 'id de reabrir para cerrar');

  -- Sin id también se cierra y se reabre como antes; con un id nuevo, versión 2.
  r := public.cerrar_mes(e, 2026, 1, NULL, gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'version')::int = 2 AND NOT (r->>'duplicado')::boolean, 'versión 2');
  r := public.reabrir_periodo(e, 2026, 1, 'Otra corrección');
  PERFORM pruebas.afirmar(r->>'estado' = 'abierto' AND NOT r ? 'duplicado', 'reabrir sin id: como antes');

  -- El registro: 3 operaciones con id; no se edita ni se borra; lo lee quien ve la contabilidad.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.periodo_operacion) = 3, 'tres registros');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.periodo_operacion) = 0, 'el cajero no los ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_mes(%L, 2026, 1, NULL, gen_random_uuid())', e), 'SIN_PERMISO', 'el cajero no cierra');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar('UPDATE public.periodo_operacion SET mes = 2', 'PROHIBIDO', 'no se edita');
  PERFORM pruebas.debe_fallar('DELETE FROM public.periodo_operacion', 'PROHIBIDO', 'no se borra');
  PERFORM pruebas.afirmar(interno.tipo_operacion(e, id1) = 'cierre_mes' AND interno.tipo_operacion(e, id2) = 'reapertura_mes', 'tipos registrados');
  PERFORM pruebas.afirmar(NOT has_function_privilege('authenticated', 'interno.cerrar_mes_base(uuid,integer,integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'interno.reabrir_periodo_base(uuid,integer,integer,text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.cerrar_mes(uuid,integer,integer,text,uuid)', 'EXECUTE'), 'permisos de las funciones');
END $$;
