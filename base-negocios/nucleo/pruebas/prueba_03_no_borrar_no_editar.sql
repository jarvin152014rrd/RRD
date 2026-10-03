-- PRUEBA: DELETE / UPDATE / INSERT / TRUNCATE directos fallan (usuario y dueño de tabla)
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  r  jsonb;
  v_id uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  r  := public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());
  v_id := (r->>'asiento_id')::uuid;

  -- Usuario con sesión: no tiene permiso de escribir tablas (42501 = permiso denegado).
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.asiento WHERE id = %L', v_id), '42501', 'delete asiento');
  PERFORM pruebas.debe_fallar(format('UPDATE public.asiento SET descripcion = %L WHERE id = %L', 'x', v_id), '42501', 'update asiento');
  PERFORM pruebas.debe_fallar('DELETE FROM public.asiento_linea', '42501', 'delete líneas');
  PERFORM pruebas.debe_fallar('UPDATE public.asiento_linea SET debe_centavos = 1', '42501', 'update líneas');
  PERFORM pruebas.debe_fallar(format(
    'INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion, id_operacion, total_centavos)
     SELECT %L, id, 99, %L, %L, gen_random_uuid(), 1 FROM public.sucursal LIMIT 1', e, '2026-01-10', 'trampa'),
    '42501', 'insert directo');
  PERFORM pruebas.debe_fallar('UPDATE public.cuenta SET nombre = ''x''', '42501', 'update cuenta');
  PERFORM pruebas.debe_fallar('UPDATE public.periodo SET estado = ''abierto''', '42501', 'update periodo');
  PERFORM pruebas.debe_fallar('INSERT INTO public.rol_permiso VALUES (''' || e || ''', ''cajero'', ''asientos.anular'')', '42501', 'insert permiso');

  -- Sin sesión (anon): ni leer.
  PERFORM pruebas.como('anon');
  PERFORM pruebas.debe_fallar('SELECT count(*) FROM public.asiento', '42501', 'anon lee asientos');

  -- Dueño de la tabla / superusuario: lo frenan los triggers.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.asiento_linea WHERE asiento_id = %L', v_id), 'PROHIBIDO', 'super borra líneas');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.asiento WHERE id = %L', v_id), 'PROHIBIDO', 'super borra asiento');
  PERFORM pruebas.debe_fallar(format('UPDATE public.asiento SET descripcion = %L WHERE id = %L', 'x', v_id), 'PROHIBIDO', 'super edita asiento');
  PERFORM pruebas.debe_fallar('UPDATE public.asiento_linea SET debe_centavos = debe_centavos + 1', 'PROHIBIDO', 'super edita líneas');
  PERFORM pruebas.debe_fallar('TRUNCATE public.periodo', 'PROHIBIDO', 'super vacía períodos');
  PERFORM pruebas.debe_fallar('TRUNCATE public.licencia', 'PROHIBIDO', 'super vacía licencias');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.cuenta WHERE empresa_id = %L', e), 'PROHIBIDO', 'super borra cuentas');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.empresa WHERE id = %L', e), 'PROHIBIDO', 'super borra empresa');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cuenta SET codigo = %L WHERE empresa_id = %L AND codigo = %L', '9', e, '1'), 'PROHIBIDO', 'super cambia código de cuenta');

  -- Todo sigue igual.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE asiento_id = v_id) = 2, 'las líneas siguen ahí');
END $$;
