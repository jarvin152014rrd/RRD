-- PRUEBA: el proveedor puede ver pero NO registra movimientos, ni aunque le den el permiso
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
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 1, 'proveedor puede ver (soporte)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e) > 0, 'proveedor ve bitácora');

  -- Ni el dueño ni el superusuario pueden darle permisos de movimiento.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true)', e, 'proveedor', 'asientos.registrar'), 'PROHIBIDO', 'dueño da permiso al proveedor');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.rol_permiso VALUES (%L, %L, %L)', e, 'proveedor', 'asientos.anular'), 'PROHIBIDO', 'super da permiso al proveedor');
END $$;
