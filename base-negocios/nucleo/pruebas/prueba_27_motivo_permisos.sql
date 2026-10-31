-- PRUEBA: cambiar permisos de un rol exige motivo (mínimo 5 letras) y queda en bitácora con quién y por qué
DO $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, NULL)', e, 'cajero', 'contabilidad.ver'), 'FALTA_MOTIVO', 'motivo nulo');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'cajero', 'contabilidad.ver', '    '), 'FALTA_MOTIVO', 'motivo en blanco');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'cajero', 'contabilidad.ver', 'abcd'), 'FALTA_MOTIVO', 'motivo de 4 letras');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, NULL, %L)', e, 'cajero', 'contabilidad.ver', 'sin decidir'), 'DATO_INVALIDO', 'otorgar nulo');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'jefe', 'contabilidad.ver', 'rol inventado'), 'NO_EXISTE', 'rol inexistente');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('contabilidad.ver'), 'nada cambió sin motivo');

  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'contabilidad.ver', true, '  Cuadra la caja al cierre  ');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(public.tiene_permiso('contabilidad.ver'), 'permiso dado');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'contabilidad.ver', false, 'Terminó la revisión');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'rol_permiso' AND accion = 'INSERT'
    AND despues->>'rol' = 'cajero' AND despues->>'permiso' = 'contabilidad.ver'
    AND motivo = 'Cuadra la caja al cierre' AND usuario_id = pruebas.usuario('dueno_a')), 'dar permiso en bitácora con motivo');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'rol_permiso' AND accion = 'DELETE'
    AND antes->>'rol' = 'cajero' AND motivo = 'Terminó la revisión' AND usuario_id = pruebas.usuario('dueno_a')), 'quitar permiso en bitácora con motivo');
  -- El motivo no se "pega" a lo siguiente que se haga en la misma transacción.
  PERFORM pruebas.afirmar(coalesce(current_setting('app.motivo', true), '') = '', 'motivo limpio después');
END $$;
