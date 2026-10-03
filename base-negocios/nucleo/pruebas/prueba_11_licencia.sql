-- PRUEBA: licencia vencida bloquea escribir pero permite leer; días de gracia funcionan
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  x uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  x := (public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), gen_random_uuid())->>'asiento_id')::uuid;

  -- El usuario no puede tocar su licencia.
  PERFORM pruebas.debe_fallar(format('UPDATE public.licencia SET vence_el = %L WHERE empresa_id = %L', '2099-01-01', e), '42501', 'dueño se extiende la licencia');

  -- El proveedor (service_role) la deja vencida hace 30 días (gracia 5).
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() - 30, dias_gracia = 5 WHERE empresa_id = e;
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.licencia WHERE empresa_id = %L', e), '42501', 'service_role no borra licencia');

  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(NOT public.licencia_activa(e), 'licencia inactiva');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-11', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'LICENCIA_VENCIDA', 'registrar');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', x, 'por prueba'), 'LICENCIA_VENCIDA', 'anular');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 1)', e), 'LICENCIA_VENCIDA', 'cerrar mes');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true)', e, 'cajero', 'asientos.anular'), 'LICENCIA_VENCIDA', 'editar permisos');

  -- Leer y exportar nunca se bloquea.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) = 1, 'puede leer asientos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE empresa_id = e) = 2, 'puede leer líneas');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.01') = 1000, 'puede leer saldos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e) > 0, 'puede leer bitácora');

  -- Dentro de los días de gracia (venció hace 3 días, gracia 5): sí escribe.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() - 3 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-01-12', 'En gracia', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());

  -- Suspendida: bloquea aunque esté vigente.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() + 30, suspendida = true WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-13', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)), 'LICENCIA_VENCIDA', 'suspendida');

  -- La empresa B no se afectó.
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(pruebas.empresa('B'), '2026-01-13', 'B sigue', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
END $$;
