-- PRUEBA: la bitácora registra quién, cuándo y qué; nadie la puede editar ni borrar
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  op uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  r  jsonb;
  b  public.bitacora;
BEGIN
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_asiento(e, '2026-01-20', 'Pago de luz', pruebas.lineas('6.1.02.02', '1.1.01.01', 85000), op);

  SELECT * INTO b FROM public.bitacora WHERE tabla = 'asiento' AND registro_id = r->>'asiento_id';
  PERFORM pruebas.afirmar(b.id IS NOT NULL, 'hay registro en bitácora');
  PERFORM pruebas.afirmar(b.accion = 'INSERT', 'acción INSERT');
  PERFORM pruebas.afirmar(b.usuario_id = pruebas.usuario('dueno_a'), 'quién');
  PERFORM pruebas.afirmar(b.ocurrido_en IS NOT NULL, 'cuándo (servidor)');
  PERFORM pruebas.afirmar(b.id_operacion = op, 'id_operacion');
  PERFORM pruebas.afirmar(b.empresa_id = e, 'empresa');
  PERFORM pruebas.afirmar((b.despues->>'total_centavos')::bigint = 85000, 'contenido después');

  -- Usuario: no puede escribir la bitácora.
  PERFORM pruebas.debe_fallar('DELETE FROM public.bitacora', '42501', 'usuario borra bitácora');
  PERFORM pruebas.debe_fallar('UPDATE public.bitacora SET motivo = ''x''', '42501', 'usuario edita bitácora');
  PERFORM pruebas.debe_fallar('INSERT INTO public.bitacora (accion, tabla) VALUES (''x'', ''y'')', '42501', 'usuario inventa bitácora');

  -- El cajero no tiene permiso de verla.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora) = 0, 'cajero no ve la bitácora');

  -- Ni el superusuario la toca.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.bitacora WHERE id = %s', b.id), 'PROHIBIDO', 'super borra');
  PERFORM pruebas.debe_fallar(format('UPDATE public.bitacora SET motivo = %L WHERE id = %s', 'x', b.id), 'PROHIBIDO', 'super edita');
  PERFORM pruebas.debe_fallar('TRUNCATE public.bitacora', 'PROHIBIDO', 'super vacía');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE id = b.id), 'el registro sigue ahí');

  -- La instalación también quedó auditada (empresa creada por service_role).
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora
    WHERE tabla = 'empresa' AND accion = 'INSERT' AND empresa_id = e AND rol_sesion = 'service_role'), 'instalación auditada');
END $$;
