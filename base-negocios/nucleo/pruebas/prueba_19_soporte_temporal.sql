-- PRUEBA: el dueño da acceso de soporte temporal al proveedor (con motivo y vencimiento); vence solo y queda en bitácora
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  r jsonb;
  v_acceso uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid());

  -- Solo el dueño lo da.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, now() + interval ''2 hours'', %L)', e, 'quiero ayuda'), 'SIN_PERMISO', 'admin otorga');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, now() + interval ''2 hours'', %L)', e, 'me lo doy yo'), 'SIN_PERMISO', 'proveedor se otorga');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'soporte.otorgar', 'delegar soporte'), 'SIN_PERMISO', 'proveedor edita permisos');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'soporte.otorgar', 'delegar soporte'), 'PROHIBIDO', 'soporte.otorgar solo del dueño');

  -- Validaciones.
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, now() + interval ''2 hours'', %L)', e, 'ayu'), 'FALTA_MOTIVO', 'motivo corto');
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, now() - interval ''1 hour'', %L)', e, 'ya pasó'), 'VENCIMIENTO_INVALIDO', 'vence en el pasado');
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, now() + interval ''31 days'', %L)', e, 'para siempre'), 'VENCIMIENTO_INVALIDO', 'más de 30 días');
  PERFORM pruebas.debe_fallar(format('SELECT public.otorgar_acceso_soporte(%L, NULL, %L)', e, 'sin fecha'), 'VENCIMIENTO_INVALIDO', 'sin vencimiento');

  -- Un acceso VENCIDO no sirve (vence solo).
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.acceso_soporte (empresa_id, motivo, otorgado_por, desde, vence_en)
  VALUES (e, 'Acceso viejo de la semana pasada', pruebas.usuario('dueno_a'), now() - interval '8 days', now() - interval '1 day');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 0, 'acceso vencido no da lectura');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('contabilidad.ver', e), 'vencido: sin contabilidad.ver');

  -- Acceso vigente por 2 horas.
  PERFORM pruebas.como('dueno_a');
  r := public.otorgar_acceso_soporte(e, now() + interval '2 hours', 'Revisar descuadre de enero');
  v_acceso := (r->>'acceso_id')::uuid;
  PERFORM pruebas.afirmar(r->>'vence_en' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', 'vence_en en ISO 8601');

  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 1, 'con soporte ve asientos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e) > 0, 'con soporte ve bitácora');
  PERFORM pruebas.afirmar((SELECT saldo_final_centavos FROM public.saldo_cuentas(e, NULL, '2026-12-31') WHERE codigo = '1.1.01.01') = 1000, 'con soporte ve saldos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'con soporte verifica bitácora');
  PERFORM pruebas.afirmar((public.mi_perfil(e)->'permisos') = '["bitacora.ver", "compras.ver", "contabilidad.ver", "inventario.costos", "terceros.ver"]'::jsonb, 'perfil del proveedor con soporte');
  -- Pero nunca mueve los libros.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_PERMISO', 'soporte no registra');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('asientos.anular', e), 'soporte no anula');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('permisos.editar', e), 'soporte no edita permisos');
  -- Y no ve otras empresas.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = pruebas.empresa('B')) = 0, 'no ve empresa B');

  -- Quedó en bitácora: quién, motivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'acceso_soporte' AND accion = 'INSERT'
    AND registro_id = v_acceso::text AND usuario_id = pruebas.usuario('dueno_a') AND motivo = 'Revisar descuadre de enero'), 'otorgamiento en bitácora');
  -- No se edita ni se borra.
  PERFORM pruebas.debe_fallar(format('UPDATE public.acceso_soporte SET vence_en = now() + interval ''300 days'' WHERE id = %L', v_acceso), 'PROHIBIDO', 'alargar a mano');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.acceso_soporte WHERE id = %L', v_acceso), 'PROHIBIDO', 'borrar acceso');

  -- Funciona aunque la licencia esté vencida (justo cuando se necesita).
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() - 60 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '1 hour', 'Licencia vencida, revisar datos');

  -- El dueño lo revoca antes de tiempo.
  PERFORM pruebas.debe_fallar(format('SELECT public.revocar_acceso_soporte(%L, %L)', e, ''), 'FALTA_MOTIVO', 'revocar sin motivo');
  r := public.revocar_acceso_soporte(e, 'Ya se resolvió el problema');
  PERFORM pruebas.afirmar((r->>'revocados')::int = 2, 'revoca los dos vigentes');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 0, 'revocado: ya no ve');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'acceso_soporte' AND accion = 'UPDATE'
    AND motivo = 'Ya se resolvió el problema' AND usuario_id = pruebas.usuario('dueno_a')), 'revocación en bitácora');
  PERFORM pruebas.debe_fallar(format('UPDATE public.acceso_soporte SET revocado_en = NULL WHERE id = %L', v_acceso), 'PROHIBIDO', 'des-revocar');
END $$;
