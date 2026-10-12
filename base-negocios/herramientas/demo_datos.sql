-- =====================================================================
-- demo_datos.sql  -  SOLO DEMO LOCAL. Datos falsos de una ferretería
-- para ver y probar la app (herramientas/demo_app.sh lo carga).
--
--   Ferretería El Roble (empezó el día 1 del mes pasado)
--   Usuarios (clave de la demo: la que imprime demo_app.sh):
--     dueno@demo.hn (María López, dueña)   admin@demo.hn (Carlos Mejía)
--     cajero@demo.hn (Ana Sosa)            vendedor@demo.hn (Juan Ramos)
--   Módulos: inventario, compras, dinero, ventas.
--   Cuentas: Caja 1, Caja fuerte, BAC cheques, Banco Atlántida, Caja chica.
--   Ventas de contado, con tarjeta y al crédito (una ya vencida), un cobro,
--   un depósito en tránsito, gastos, dos solicitudes de gasto pendientes y
--   dos promociones vigentes para la pintura (para ver la sugerida en Vender).
-- Todas las fechas son relativas a "hoy" para que la demo siempre se vea viva.
-- =====================================================================

CREATE SCHEMA demo;

CREATE TABLE demo.dato (clave text PRIMARY KEY, valor uuid NOT NULL);

-- "Quién soy" en esta transacción (igual que pruebas.como).
CREATE FUNCTION demo.como(p_correo text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM set_config('role', 'none', true);
  IF p_correo IS NULL THEN
    PERFORM set_config('role', 'none', true);
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN;
  END IF;
  SELECT id INTO v FROM auth.users WHERE email = p_correo;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  PERFORM set_config('role', 'authenticated', true);
END $$;

CREATE FUNCTION demo.g(p_clave text, p_valor uuid) RETURNS uuid LANGUAGE sql SECURITY DEFINER AS
  $$ INSERT INTO demo.dato VALUES (p_clave, p_valor) ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor RETURNING valor $$;
CREATE FUNCTION demo.id(p_clave text) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT valor FROM demo.dato WHERE clave = p_clave $$;

-- Una línea de venta.
CREATE FUNCTION demo.l(p_prod text, p_cant numeric) RETURNS jsonb LANGUAGE sql STABLE AS
  $$ SELECT jsonb_build_object('producto_id', demo.id(p_prod), 'cantidad', p_cant) $$;

GRANT USAGE ON SCHEMA demo TO authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO authenticated, service_role;

-- Usuarios de Supabase Auth.
INSERT INTO auth.users (email) VALUES
  ('dueno@demo.hn'), ('admin@demo.hn'), ('cajero@demo.hn'), ('vendedor@demo.hn');

DO $$
DECLARE
  e      uuid;
  inicio date := (date_trunc('month', (now() AT TIME ZONE 'America/Tegucigalpa')::date) - interval '1 month')::date;
  hoy    date;
  s001   uuid;
  caja1  uuid;
  lb     uuid;
BEGIN
  -- 1) La empresa la crea el proveedor (llave service_role).
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  SET LOCAL ROLE service_role;
  e := public.crear_empresa_inicial(jsonb_build_object(
    'nombre', 'Ferretería El Roble', 'rtn', '08011999123456', 'rubro', 'Ferretería',
    'fecha_inicio', inicio,
    'dueno', jsonb_build_object('user_id', (SELECT id FROM auth.users WHERE email = 'dueno@demo.hn'), 'nombre', 'María López')));
  INSERT INTO public.licencia (empresa_id, vence_el) VALUES (e, public.hoy_local() + 90);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM demo.g('EMPRESA', e);
  hoy := public.hoy_local(e);

  INSERT INTO public.modulo_activo (empresa_id, modulo)
  VALUES (e, 'inventario'), (e, 'compras'), (e, 'dinero'), (e, 'ventas')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  SELECT id INTO caja1 FROM public.caja WHERE empresa_id = e AND punto_emision = '001';
  SELECT id INTO lb FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'LB';

  -- 2) Como dueña: personal, configuración, cuentas, productos, terceros.
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.agregar_usuario_empresa(e, 'admin@demo.hn', 'admin', 'Carlos Mejía');
  PERFORM public.agregar_usuario_empresa(e, 'cajero@demo.hn', 'cajero', 'Ana Sosa');
  PERFORM public.agregar_usuario_empresa(e, 'vendedor@demo.hn', 'vendedor', 'Juan Ramos');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Demo: sin turnos obligatorios');

  PERFORM demo.g('B1', (public.crear_bodega(e, s001, 'B1', 'Bodega principal')->>'bodega_id')::uuid);
  PERFORM demo.g('CAJA1', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja',
    'nombre', 'Caja 1', 'caja_id', caja1))->>'cuenta_dinero_id')::uuid);
  PERFORM demo.g('FUERTE', (public.crear_cuenta_dinero(e, '{"tipo": "efectivo_caja", "nombre": "Caja fuerte"}')->>'cuenta_dinero_id')::uuid);
  PERFORM demo.g('BAC', (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "BAC cheques",
    "banco": "BAC Credomatic", "numero_cuenta": "7301-2345-6789", "tipo_cuenta": "cheques"}')->>'cuenta_dinero_id')::uuid);
  PERFORM demo.g('ATL', (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "Atlántida ahorro",
    "banco": "Banco Atlántida", "numero_cuenta": "2200-0012-1203", "tipo_cuenta": "ahorro"}')->>'cuenta_dinero_id')::uuid);
  PERFORM demo.g('CCHICA', (public.crear_cuenta_dinero(e, '{"tipo": "caja_chica", "nombre": "Caja chica",
    "fondo_fijo_centavos": 200000}')->>'cuenta_dinero_id')::uuid);
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', demo.id('BAC'),
    'monto_centavos', 9840000, 'fecha', inicio, 'referencia', 'Estado de cuenta'), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', demo.id('ATL'),
    'monto_centavos', 2769000, 'fecha', inicio), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', demo.id('FUERTE'),
    'monto_centavos', 1500000, 'fecha', inicio), gen_random_uuid());
  PERFORM demo.g('CAT_ALQ', (public.crear_categoria_gasto(e, 'Alquiler', '6.1.02.01')->>'categoria_id')::uuid);
  PERFORM demo.g('CAT_LUZ', (public.crear_categoria_gasto(e, 'Energía eléctrica', '6.1.02.02')->>'categoria_id')::uuid);
  PERFORM demo.g('CAT_MANT', (public.crear_categoria_gasto(e, 'Papelería y mantenimiento', '6.1.02.05')->>'categoria_id')::uuid);

  PERFORM demo.g('CEM', (public.crear_producto(e, '{"codigo": "CEM-425", "nombre": "Cemento gris 42.5 kg",
    "precio_venta_centavos": 27500, "stock_minimo": 10}', gen_random_uuid())->>'producto_id')::uuid);
  PERFORM demo.g('VAR', (public.crear_producto(e, '{"codigo": "VAR-038", "nombre": "Varilla corrugada 3/8",
    "precio_venta_centavos": 18500, "stock_minimo": 20}', gen_random_uuid())->>'producto_id')::uuid);
  PERFORM demo.g('CLA', (public.crear_producto(e, jsonb_build_object('codigo', 'CLA-250', 'nombre', 'Clavo de 2 1/2 pulgadas',
    'unidad_id', lb, 'permite_fracciones', true, 'precio_venta_centavos', 4000), gen_random_uuid())->>'producto_id')::uuid);
  PERFORM demo.g('PIN', (public.crear_producto(e, '{"codigo": "PIN-BLA", "nombre": "Pintura blanca galón",
    "precio_venta_centavos": 52000}', gen_random_uuid())->>'producto_id')::uuid);
  PERFORM demo.g('PVC', (public.crear_producto(e, '{"codigo": "PVC-012", "nombre": "Tubo PVC 1/2 pulgada",
    "precio_venta_centavos": 11500, "stock_minimo": 15}', gen_random_uuid())->>'producto_id')::uuid);

  PERFORM demo.g('PROV1', (public.crear_tercero(e, '{"nombre": "Distribuidora Lara", "es_proveedor": true,
    "plazo_dias": 30, "rtn": "08011999000111"}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM demo.g('PROV2', (public.crear_tercero(e, '{"nombre": "Cementos del Norte", "es_proveedor": true,
    "plazo_dias": 15}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM demo.g('CLI1', (public.crear_tercero(e, '{"nombre": "Constructora Ríos", "es_cliente": true,
    "rtn": "08011999000222", "limite_credito_centavos": 5000000, "plazo_dias": 30, "telefono": "9988-7766"}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM demo.g('CLI2', (public.crear_tercero(e, '{"nombre": "Taller Mejía", "es_cliente": true,
    "limite_credito_centavos": 1500000, "plazo_dias": 15}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM demo.g('CLI3', (public.crear_tercero(e, '{"nombre": "Pedro Castillo", "es_cliente": true}', gen_random_uuid())->>'tercero_id')::uuid);

  -- 3) Compras al crédito (la primera ya venció).
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', demo.id('PROV1'), 'bodega_id', demo.id('B1'),
    'numero_documento', 'FL-1021', 'fecha', inicio + 1, 'condicion', 'credito',
    'lineas', jsonb_build_array(
      jsonb_build_object('producto_id', demo.id('VAR'), 'cantidad', 200, 'costo_unitario', 12000),
      jsonb_build_object('producto_id', demo.id('CLA'), 'cantidad', 150, 'costo_unitario', 2200),
      jsonb_build_object('producto_id', demo.id('PIN'), 'cantidad', 40, 'costo_unitario', 36000),
      jsonb_build_object('producto_id', demo.id('PVC'), 'cantidad', 120, 'costo_unitario', 6000))), gen_random_uuid());
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', demo.id('PROV2'), 'bodega_id', demo.id('B1'),
    'numero_documento', 'CN-552', 'fecha', inicio + 2, 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', demo.id('CEM'), 'cantidad', 84, 'costo_unitario', 19000))), gen_random_uuid());
  PERFORM public.pagar_proveedor(e, (SELECT id FROM public.compra WHERE empresa_id = e AND numero_documento = 'CN-552'),
    1000000, inicio + 10, NULL, gen_random_uuid(), 'Abono con cheque', NULL, demo.id('BAC'));

  -- 4) Ventas del mes pasado y de este mes.
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', inicio + 4, 'cliente_id', demo.id('CLI1'),
    'lineas', jsonb_build_array(demo.l('CEM', 40), demo.l('VAR', 60)),
    'pagos', '[{"forma":"credito"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', inicio + 8,
    'lineas', jsonb_build_array(demo.l('PIN', 6), demo.l('CLA', 12.5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', inicio + 15,
    'lineas', jsonb_build_array(demo.l('PVC', 30), demo.l('VAR', 20)), 'pagos', '[{"forma":"tarjeta"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', inicio + 22,
    'lineas', jsonb_build_array(demo.l('CEM', 12)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', demo.id('CLI1'), 'fecha', inicio + 20,
    'pagos', '[{"forma":"efectivo","monto_centavos":800000}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', hoy - 9,
    'lineas', jsonb_build_array(demo.l('CEM', 15), demo.l('VAR', 40), demo.l('PIN', 5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', hoy - 7,
    'lineas', jsonb_build_array(demo.l('PIN', 8), demo.l('PVC', 25)), 'pagos', '[{"forma":"tarjeta"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', hoy - 3, 'cliente_id', demo.id('CLI2'),
    'lineas', jsonb_build_array(demo.l('PIN', 4), demo.l('PVC', 10)), 'pagos', '[{"forma":"credito"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', hoy - 1,
    'lineas', jsonb_build_array(demo.l('CEM', 8), demo.l('CLA', 5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  -- Hoy
  PERFORM public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(demo.l('CEM', 5), demo.l('VAR', 10)),
    'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(demo.l('PIN', 2)),
    'pagos', '[{"forma":"tarjeta"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(demo.l('CLA', 3.5), demo.l('PVC', 6)),
    'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());

  -- 4b) Dos promociones vigentes para la pintura (desde hoy, después de las ventas de arriba):
  --     quien vende ve la sugerida (la que más descuenta) y puede cambiarla; nunca se suman.
  PERFORM demo.g('CAT_PIN', (public.crear_categoria(e, 'Pinturas')->>'categoria_id')::uuid);
  PERFORM public.editar_producto(e, demo.id('PIN'), jsonb_build_object('categoria_id', demo.id('CAT_PIN')));
  PERFORM demo.g('PROMO10', (public.crear_promocion(e, jsonb_build_object('nombre', 'Pintura 10 %', 'categoria_id', demo.id('CAT_PIN'),
    'tipo', 'porcentaje', 'porcentaje', 10, 'fecha_inicio', to_char(hoy, 'YYYY-MM-DD'),
    'fecha_fin', to_char(hoy + 30, 'YYYY-MM-DD')))->>'promocion_id')::uuid);
  PERFORM demo.g('PROMO60', (public.crear_promocion(e, jsonb_build_object('nombre', 'Galón L 60 menos', 'categoria_id', demo.id('CAT_PIN'),
    'tipo', 'monto', 'monto_centavos', 6000, 'fecha_inicio', to_char(hoy, 'YYYY-MM-DD'),
    'fecha_fin', to_char(hoy + 30, 'YYYY-MM-DD')))->>'promocion_id')::uuid);

  -- 5) Gastos y un depósito de la caja fuerte al banco que sigue en tránsito.
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'reposicion_caja_chica', 'origen_id', demo.id('BAC'),
    'destino_id', demo.id('CCHICA'), 'fecha', inicio + 3, 'referencia', 'Fondo de caja chica'), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', demo.id('BAC'), 'categoria_id', demo.id('CAT_ALQ'),
    'monto_centavos', 1200000, 'descripcion', 'Alquiler del local', 'fecha', inicio + 5), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', demo.id('BAC'), 'categoria_id', demo.id('CAT_LUZ'),
    'monto_centavos', 238000, 'descripcion', 'Energía del mes', 'fecha', hoy - 6), gen_random_uuid());
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', demo.id('FUERTE'),
    'destino_id', demo.id('BAC'), 'monto_centavos', 210000, 'fecha', hoy - 5, 'referencia', 'Boleta 88231'), gen_random_uuid());

  -- 6) Solicitudes pendientes: el admin pide un gasto sobre su tope (L 5,000).
  PERFORM demo.como('admin@demo.hn');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', demo.id('BAC'), 'categoria_id', demo.id('CAT_MANT'),
    'monto_centavos', 750000, 'descripcion', 'Reparación del techo de la bodega', 'fecha', hoy), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', demo.id('BAC'), 'categoria_id', demo.id('CAT_MANT'),
    'monto_centavos', 620000, 'descripcion', 'Pintura del rótulo del frente', 'fecha', hoy), gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;
