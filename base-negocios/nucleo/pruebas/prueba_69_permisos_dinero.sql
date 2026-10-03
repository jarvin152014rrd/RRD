-- PRUEBA: permisos y módulo "dinero" (REQUISITOS): admin opera y aprueba dentro de topes; contador solo lee; cajero opera su turno; vendedor no ve bancos; el proveedor solo lee con soporte; sin el módulo o con licencia vencida no se mueve dinero (leer sí); políticas RLS rápidas en las tablas nuevas
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  cont uuid;
  p    jsonb;
  f    text;
BEGIN
  INSERT INTO auth.users (email) VALUES ('contador@prueba.hn') RETURNING id INTO cont;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('contador', cont);
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES (cont, e, 'contador');

  -- 1) Sin el módulo "dinero": nada se mueve ni se crea.
  PERFORM pruebas.como('dueno_a');
  FOREACH f IN ARRAY ARRAY[
      format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"transito","nombre":"T"}'),
      format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, '{"tipo":"traslado"}'),
      format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', e, '{}'),
      format('SELECT public.abrir_turno(%L, %L, 0, gen_random_uuid())', e, gen_random_uuid()),
      format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, '{}'),
      format('SELECT public.crear_categoria_gasto(%L, %L, %L)', e, 'Luz', '6.1.02.02'),
      format('SELECT public.crear_pago_fijo(%L, %L)', e, '{}')] LOOP
    PERFORM pruebas.debe_fallar(f, 'MODULO_INACTIVO', 'sin módulo: ' || left(f, 40));
  END LOOP;

  PERFORM pruebas.preparar_dinero();

  -- 2) Permisos por puesto (mi_perfil).
  PERFORM pruebas.como('admin_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'permisos' @> '["dinero.ver", "dinero.administrar", "dinero.trasladar", "dinero.anular", "adjuntos.agregar",
    "caja.turno", "caja.supervisar", "gastos.registrar", "gastos.aprobar", "gastos.anular", "aprobaciones.ver"]'
    AND NOT p->'permisos' ? 'dinero.saldo_inicial', 'admin: ' || (p->'permisos')::text);
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(public.mi_perfil()->'permisos' = '["adjuntos.agregar", "caja.turno", "inventario.ver", "terceros.editar", "terceros.ver", "ventas.cobrar", "ventas.cotizar", "ventas.solicitar_anulacion", "ventas.vender"]',
    'cajero: su turno y comprobantes');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar(public.mi_perfil()->'permisos' = '["inventario.ver", "terceros.editar", "terceros.ver", "ventas.cotizar", "ventas.solicitar_anulacion", "ventas.vender"]', 'vendedor: nada de dinero');
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar(public.mi_perfil()->'permisos' = '["aprobaciones.ver", "bitacora.ver", "compras.ver", "contabilidad.ver", "dinero.ver", "inventario.costos", "inventario.ver", "terceros.ver", "ventas.ver"]',
    'contador: solo lectura');

  -- 3) Vendedor: no ve bancos ni movimientos ni turnos ni gastos.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) + (SELECT count(*) FROM public.dinero_movimiento)
    + (SELECT count(*) FROM public.operacion_dinero) + (SELECT count(*) FROM public.turno_caja) + (SELECT count(*) FROM public.gasto)
    + (SELECT count(*) FROM public.pago_fijo) = 0, 'vendedor no ve dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 0, gen_random_uuid())', e, pruebas.id('CAJA001')), 'SIN_PERMISO', 'vendedor abre turno');

  -- 4) Contador: ve todo, no mueve nada (ni el dueño le puede dar permisos de movimiento).
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) = 4 AND (SELECT count(*) FROM public.dinero_movimiento) = 2, 'contador ve');
  PERFORM pruebas.afirmar((public.donde_esta_mi_dinero(e)->>'total_centavos')::bigint = 1300000, 'contador: dónde está mi dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'SIN_PERMISO', 'contador traslada');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 0, gen_random_uuid())', e, pruebas.id('CAJA001')), 'SIN_PERMISO', 'contador abre turno');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', e, '{"tipo":"transito","nombre":"T"}'), 'SIN_PERMISO', 'contador crea cuentas');
  PERFORM pruebas.como('dueno_a');
  FOREACH f IN ARRAY ARRAY['dinero.trasladar', 'dinero.administrar', 'caja.turno', 'gastos.registrar', 'gastos.aprobar', 'adjuntos.agregar'] LOOP
    PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', f, 'Que ayude con el dinero'),
      'PROHIBIDO', 'contador con ' || f);
  END LOOP;

  -- 5) Proveedor: sin soporte no ve; con soporte solo lee.
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) = 0, 'proveedor sin soporte no ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.donde_esta_mi_dinero(%L)', e), 'SIN_PERMISO', 'proveedor sin soporte');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '1 hour', 'Revisar cuentas de dinero');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero) = 4, 'con soporte ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'SIN_PERMISO', 'proveedor mueve');

  -- 6) Licencia vencida: no se mueve dinero, pero se consulta.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) - 30 WHERE empresa_id = e;
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_dinero(%L, %L, gen_random_uuid())', e, jsonb_build_object('tipo', 'traslado',
    'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 1)), 'LICENCIA_VENCIDA', 'licencia vencida');
  PERFORM pruebas.afirmar((public.donde_esta_mi_dinero(e)->>'total_centavos')::bigint = 1300000, 'consulta con licencia vencida');

  -- 7) Estructura: RLS rápido en las tablas nuevas y funciones internas cerradas.
  PERFORM pruebas.como('superusuario');
  FOREACH f IN ARRAY ARRAY['cuenta_dinero', 'operacion_dinero', 'dinero_movimiento', 'adjunto', 'turno_caja', 'gasto', 'aprobacion', 'pago_fijo'] LOOP
    PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM pg_policies x WHERE x.schemaname = 'public' AND x.tablename = f
      AND x.qual LIKE '%ANY (ARRAY( SELECT empresas_con_permiso(%' AND x.qual NOT LIKE '%tiene_permiso%'), 'política de ' || f);
  END LOOP;
  PERFORM pruebas.afirmar(NOT has_function_privilege('authenticated', 'interno.rastrear_dinero(uuid,text,text,uuid,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'interno.registrar_gasto_base(uuid,jsonb,uuid,uuid,date)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'interno.aplicar_gasto(public.gasto,date,uuid)', 'EXECUTE'), 'internas cerradas');
  PERFORM pruebas.afirmar(NOT has_table_privilege('authenticated', 'public.dinero_movimiento', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.gasto', 'UPDATE'), 'sin escritura directa');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.modulo WHERE codigo = 'dinero') = 1, 'módulo dinero');
END $$;
