-- PRUEBA: permisos y módulo "ventas": vendedor vende y solicita (no cobra, no ve costos); cajero cobra; admin aprueba; contador solo lee (no recibe permisos de venta); proveedor solo lee con soporte; sin el módulo o con licencia vencida no se vende (leer sí); una empresa no ve las ventas de otra; activar ventas con saldo en Clientes que el módulo no explica se rechaza; políticas RLS rápidas
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  b    uuid := pruebas.empresa('B');
  v    jsonb;
  plan text := '';
  ln   text;
  t    text;
BEGIN
  PERFORM pruebas.preparar_ventas();
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');

  -- 1) Contador: no recibe permisos que venden ni aprueban.
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'ventas.vender', 'Que venda'),
    'PROHIBIDO', 'contador sin ventas.vender');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'contador', 'ventas.anular', 'Que anule'),
    'PROHIBIDO', 'contador sin ventas.anular');

  -- 2) Proveedor: sin soporte no ve; con soporte lee pero no vende.
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 0 AND (SELECT count(*) FROM public.venta) = 0, 'proveedor sin soporte');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '1 day', 'Revisar ventas');
  PERFORM pruebas.como('proveedor');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 1, 'proveedor con soporte lee');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)), 'SIN_PERMISO', 'proveedor no vende');

  -- 3) Otra empresa no ve nada.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 0 AND (SELECT count(*) FROM public.cai_rango) = 0, 'B no ve A');
  PERFORM pruebas.debe_fallar(format('SELECT public.seguir_venta(%L)', v->>'venta_id'), 'NO_PERTENECE', 'B no sigue ventas de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.documento_venta(%L)', v->>'venta_id'), 'NO_PERTENECE', 'B no imprime ventas de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', b, '{}'), 'MODULO_INACTIVO', 'B sin módulo ventas');

  -- 4) Sin el módulo: no se vende; leer sí.
  PERFORM pruebas.como('superusuario');
  -- (0.8.0: fiscal_hn depende de ventas: se apaga primero)
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'fiscal_hn';
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'ventas';
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)), 'MODULO_INACTIVO', 'módulo apagado');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta) = 1, 'el cajero sigue viendo su venta');
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = true WHERE empresa_id = e AND modulo = 'ventas';
  UPDATE public.modulo_activo SET activo = true WHERE empresa_id = e AND modulo = 'fiscal_hn';
  -- Licencia vencida: solo lectura.
  UPDATE public.licencia SET vence_el = public.hoy_local(e) - 30 WHERE empresa_id = e;
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)), 'LICENCIA_VENCIDA', 'licencia');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((public.documento_venta((v->>'venta_id')::uuid)->>'numero_documento') = '001-001-01-00000001', 'leer sí');
  PERFORM pruebas.como('superusuario');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) + 30 WHERE empresa_id = e;

  -- 5) Configuración de ventas: solo el dueño.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"credito_politica":"segun_limite"}', 'Cambio admin'),
    'SIN_PERMISO', 'admin no configura');

  -- 6) Activar "ventas" en B con saldo en Clientes que el módulo no explica.
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(b, '2026-01-10', 'Venta a crédito vieja', pruebas.lineas('1.1.02.01', '4.1.01.01', 5000), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', b, 'ventas'),
    'MODULO_CON_SALDO', 'ventas con saldo en clientes');

  -- 7) RLS: filtro por permiso una vez por consulta.
  FOREACH t IN ARRAY ARRAY['venta', 'venta_linea', 'venta_pago', 'venta_anulacion', 'cai_rango', 'cotizacion', 'servicio_costo'] LOOP
    PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = t
      AND p.qual LIKE '%ANY (ARRAY( SELECT empresas_con_permiso(%'), 'política de ' || t);
  END LOOP;
  PERFORM pruebas.como('dueno_a');
  FOR ln IN EXECUTE 'EXPLAIN SELECT count(*) FROM public.v_venta' LOOP
    plan := plan || ln || E'\n';
  END LOOP;
  PERFORM pruebas.afirmar(plan LIKE '%InitPlan%', 'v_venta calcula el permiso una vez: ' || plan);
END $$;
