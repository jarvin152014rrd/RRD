-- PRUEBA: el cajero no puede anular sin permiso; el dueño puede darle y quitarle permisos
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  x uuid; y uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  x := (public.registrar_asiento(e, '2026-01-10', 'Venta 1', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid())->>'asiento_id')::uuid;
  y := (public.registrar_asiento(e, '2026-01-10', 'Venta 2', pruebas.lineas('1.1.01.01', '4.1.01.01', 2000), gen_random_uuid())->>'asiento_id')::uuid;

  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', x, 'me equivoqué'), 'SIN_PERMISO', 'cajero anula');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_PERMISO', 'cajero registra asiento manual');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'cajero', 'asientos.anular', 'me lo doy yo'), 'SIN_PERMISO', 'cajero se da permisos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento) = 0, 'cajero no ve la contabilidad');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('asientos.anular'), 'tiene_permiso sin empresa usa la única del usuario');

  -- El dueño le da permiso de anular.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'asientos.anular', true, 'Cajero de confianza');

  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(public.tiene_permiso('asientos.anular'), 'ahora sí tiene permiso');
  PERFORM public.anular_asiento(x, 'Cliente canceló la compra');

  -- El dueño se lo quita otra vez.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'asientos.anular', false, 'Ya no hace falta');
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_asiento WHERE id = x) = 'anulado', 'x quedó anulado por el cajero');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'rol_permiso' AND accion = 'DELETE'
                                  AND antes->>'rol' = 'cajero'), 'cambio de permisos auditado');

  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', y, 'me equivoqué'), 'SIN_PERMISO', 'cajero sin permiso otra vez');

  -- Al dueño no se le puede quitar el permiso de editar permisos.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, false, %L)', e, 'dueno', 'permisos.editar', 'probar el candado'), 'PROHIBIDO', 'dueño se queda sin llave');
END $$;
