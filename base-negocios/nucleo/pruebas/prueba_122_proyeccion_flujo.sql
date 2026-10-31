-- PRUEBA: proyección de flujo de caja a 30 y 60 días por semana (cifras a mano): dinero disponible hoy sin tránsito ni por confirmar (aparte); cobros de CxC según vencimiento (los vencidos aparte, no se asumen); pagos de CxP según vencimiento (vencidos en la semana 1); pagos fijos próximos; saldo por semana y alerta cuando una semana queda en negativo; permisos y datos inválidos
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  hoy  date;
  p    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  hoy := public.hoy_local(e);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de proyección');
  -- Hoy: depósito de 100,000 de la caja fuerte al banco (queda en tránsito).
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 100000, 'referencia', 'Boleta 7'), gen_random_uuid());
  -- CxC: venta al crédito a CLI1 (2 galones = 90,000, vence hoy + 30); saldo inicial vencido de CLI2 (12,345)
  -- y saldo inicial de CLI1 que vence hoy + 10 (20,000).
  PERFORM public.registrar_venta(e, pruebas.venta('P3', 2, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-OLD-2',
    'fecha_documento', '2025-12-01', 'monto_centavos', 12345), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'F-OLD-3',
    'fecha_documento', to_char(hoy - 5, 'YYYY-MM-DD'), 'fecha_vencimiento', to_char(hoy + 10, 'YYYY-MM-DD'), 'fecha', to_char(hoy, 'YYYY-MM-DD'),
    'monto_centavos', 20000), gen_random_uuid());
  -- CxP: F-INI-1 (544,000, venció el 04/02) y una compra de hoy a PROV2 de 600 lb de arroz exento = 900,000 que vence hoy + 16.
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'bodega_id', pruebas.id('B1'), 'numero_documento', 'PX-1',
    'fecha', to_char(hoy, 'YYYY-MM-DD'), 'condicion', 'credito', 'fecha_vencimiento', to_char(hoy + 16, 'YYYY-MM-DD'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 600, 'costo_unitario', 1500))), gen_random_uuid());
  -- Pago fijo mensual de 500,000 que vence hoy + 8 (el siguiente pasa de los 30 días).
  PERFORM public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Alquiler', 'categoria_id', pruebas.id('CAT_ALQ'), 'monto_estimado_centavos', 500000,
    'frecuencia', 'mensual', 'dia', extract(day FROM hoy + 8)::integer, 'fecha_inicio', to_char(hoy, 'YYYY-MM-DD')));

  -- A mano (30 días, 5 semanas): disponible = BANCO 1,000,000 + FUERTE 200,000 = 1,200,000 (100,000 en tránsito, aparte).
  --   S1: - 544,000 (CxP vencida)          -> 656,000
  --   S2: + 20,000 (F-OLD-3) - 500,000      -> 176,000
  --   S3: - 900,000 (PX-1)                  -> -724,000  ALERTA
  --   S4:                                   -> -724,000  ALERTA
  --   S5: + 90,000 (venta, hoy + 30)        -> -634,000  ALERTA
  --   cobros vencidos aparte: 12,345.
  p := public.proyeccion_flujo(e, 30);
  PERFORM pruebas.afirmar((p->>'disponible_hoy_centavos')::bigint = 1200000 AND (p->>'no_disponible_aun_centavos')::bigint = 100000
    AND (p->>'cobros_vencidos_centavos')::bigint = 12345 AND jsonb_array_length(p->'semanas') = 5, 'encabezado de la proyección: ' || left(p::text, 600));
  PERFORM pruebas.afirmar((SELECT string_agg((s->>'saldo_final_centavos'), ',' ORDER BY (s->>'semana')::integer) FROM jsonb_array_elements(p->'semanas') s)
    = '656000,176000,-724000,-724000,-634000', 'saldos por semana: ' || (p->'semanas')::text);
  PERFORM pruebas.afirmar((p->'semanas'->1->>'cobros_centavos')::bigint = 20000 AND (p->'semanas'->1->>'pagos_fijos_centavos')::bigint = 500000
    AND (p->'semanas'->0->>'pagos_proveedores_centavos')::bigint = 544000 AND (p->'semanas'->2->>'pagos_proveedores_centavos')::bigint = 900000
    AND (p->'semanas'->4->>'cobros_centavos')::bigint = 90000, 'detalle por semana');
  PERFORM pruebas.afirmar((p->>'alerta')::boolean AND jsonb_array_length(p->'alertas') = 3 AND (p->'alertas'->0->>'semana')::integer = 3,
    'alerta en las semanas negativas: ' || (p->'alertas')::text);
  -- 60 días (9 semanas): entra el segundo alquiler (hoy + 8 + un mes): -634,000 - 500,000 = -1,134,000.
  p := public.proyeccion_flujo(e, 60);
  PERFORM pruebas.afirmar(jsonb_array_length(p->'semanas') = 9 AND (p->>'saldo_final_proyectado_centavos')::bigint = -1134000, 'a 60 días: ' || (p->'semanas')::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.proyeccion_flujo(%L, 45)', e), 'DATO_INVALIDO', '30, 60 o 90 días');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.proyeccion_flujo(%L, 30)', e), 'SIN_PERMISO', 'cajero no ve la proyección');
END $$;
