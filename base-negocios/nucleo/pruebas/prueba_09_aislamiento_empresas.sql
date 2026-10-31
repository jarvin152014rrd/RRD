-- PRUEBA: un usuario de la empresa B no ve ni toca nada de la empresa A
DO $$
DECLARE
  a  uuid := pruebas.empresa('A');
  b  uuid := pruebas.empresa('B');
  op uuid := 'abababab-0000-0000-0000-000000000001';
  ra jsonb; rb jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  ra := public.registrar_asiento(a, '2026-01-10', 'Venta A', pruebas.lineas('1.1.01.01', '4.1.01.01', 4000), op);

  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.empresa) = 1, 'B solo ve su empresa');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.empresa WHERE id = a) = 0, 'B no ve la empresa A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = a) = 0, 'B no ve asientos de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE empresa_id = a) = 0, 'B no ve líneas de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta WHERE empresa_id = a) = 0, 'B no ve cuentas de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = a) = 0, 'B no ve bitácora de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.usuario_empresa WHERE empresa_id = a) = 0, 'B no ve usuarios de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.licencia WHERE empresa_id = a) = 0, 'B no ve licencia de A');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_saldo_cuenta WHERE empresa_id = a) = 0, 'B no ve saldos de A');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('asientos.registrar', a), 'B no tiene permisos en A');

  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(a, '2026-01-10', pruebas.lineas('1.1.01.01', '4.1.01.01', 100)),
    'NO_PERTENECE', 'B registra en A');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', ra->>'asiento_id', 'sabotaje'), 'NO_PERTENECE', 'B anula en A');
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_periodo(%L, 2026, 1)', a), 'NO_PERTENECE', 'B cierra mes de A');

  -- El mismo id_operacion en B crea un asiento propio de B (no devuelve el de A).
  rb := public.registrar_asiento(b, '2026-01-10', 'Venta B', pruebas.lineas('1.1.01.01', '4.1.01.01', 300), op);
  PERFORM pruebas.afirmar((rb->>'duplicado')::boolean = false AND rb->>'asiento_id' <> ra->>'asiento_id', 'id_operacion separado por empresa');
  PERFORM pruebas.afirmar(pruebas.saldo(b, '1.1.01.01') = 300, 'saldo de B correcto');

  -- Y A sigue igual.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(pruebas.saldo(a, '1.1.01.01') = 4000, 'saldo de A intacto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = b) = 0, 'A no ve asientos de B');

  -- Un usuario sin empresa no ve nada.
  PERFORM pruebas.como('sin_empresa');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.empresa) = 0, 'usuario sin empresa no ve nada');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta) = 0, 'usuario sin empresa no ve cuentas');
END $$;
