-- PRUEBA: el proveedor NO ve cifras ni registra movimientos, ni aunque intenten darle permisos
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  x uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  x := (public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid())->>'asiento_id')::uuid;

  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'SIN_PERMISO', 'proveedor registra');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', x, 'soy proveedor'), 'SIN_PERMISO', 'proveedor anula');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 1)', e), 'SIN_PERMISO', 'proveedor cierra mes');

  -- Sin acceso de soporte no lee ninguna cifra.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 0, 'proveedor no ve asientos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE empresa_id = e) = 0, 'proveedor no ve líneas');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e) = 0, 'proveedor no ve bitácora');
  PERFORM pruebas.afirmar(coalesce((SELECT sum(saldo_centavos) FROM public.v_saldo_cuenta WHERE empresa_id = e), 0) = 0, 'proveedor no ve saldos');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.saldo_cuentas(%L, NULL, %L)', e, '2026-12-31'), 'SIN_PERMISO', 'proveedor pide saldos');
  PERFORM pruebas.debe_fallar(format('SELECT * FROM public.verificar_bitacora(%L)', e), 'SIN_PERMISO', 'proveedor verifica bitácora');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('contabilidad.ver', e), 'sin contabilidad.ver');
  -- Sí ve lo que no es financiero (para instalar y dar soporte).
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.empresa WHERE id = e) = 1, 've la empresa');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.licencia WHERE empresa_id = e) = 1, 've la licencia');

  -- La plantilla de una empresa nueva no le da nada al proveedor.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.rol_permiso WHERE rol = 'proveedor'), 'proveedor sin permisos en rol_permiso');

  -- Ni el dueño ni el superusuario pueden darle permisos por la tabla.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'proveedor', 'asientos.registrar', 'para que ayude'), 'PROHIBIDO', 'dueño da permiso de movimiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'proveedor', 'contabilidad.ver', 'para que revise'), 'PROHIBIDO', 'dueño da contabilidad.ver');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.rol_permiso VALUES (%L, %L, %L)', e, 'proveedor', 'asientos.anular'), 'PROHIBIDO', 'super da permiso al proveedor');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.rol_permiso VALUES (%L, %L, %L)', e, 'proveedor', 'bitacora.ver'), 'PROHIBIDO', 'super da bitacora.ver al proveedor');
END $$;
