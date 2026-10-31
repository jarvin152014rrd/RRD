-- =====================================================================
-- demo_datos.sql  -  SOLO DEMO LOCAL. Datos falsos de una ferretería
-- para ver y probar la app (herramientas/demo_app.sh lo carga).
--
--   Ferretería El Roble (empezó el día 1 del mes pasado)
--   Usuarios (clave de la demo: la que imprime demo_app.sh):
--     dueno@demo.hn (María López, dueña)   admin@demo.hn (Carlos Mejía)
--     cajero@demo.hn (Ana Sosa)            vendedor@demo.hn (Juan Ramos)
--   Módulos: inventario, compras, dinero, ventas (desde app 0.7.0 fondos y conciliación; desde 0.8.0 comisiones).
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

-- 7) (app 0.3.0) Segunda bodega para traslados y límite de 5 usuarios en el contrato (hay 4:
--    se puede agregar uno más y al siguiente sale el mensaje del límite).
DO $$
DECLARE e uuid := demo.id('EMPRESA');
BEGIN
  PERFORM demo.como('dueno@demo.hn');
  PERFORM demo.g('B2', (public.crear_bodega(e, (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001'),
    'B2', 'Bodega trasera')->>'bodega_id')::uuid);
  PERFORM demo.como(NULL);
  INSERT INTO public.limite_contrato (empresa_id, usuarios) VALUES (e, 5)
  ON CONFLICT (empresa_id) DO UPDATE SET usuarios = 5;
END $$;

-- 8) (app 0.7.0) Para las pantallas de Dinero: pagos fijos, fondos y socios con un reparto del mes
--    pasado (ya cerrado) y el estado de cuenta del BAC del mes pasado para cuadrar con el banco.
DO $$
DECLARE
  e      uuid := demo.id('EMPRESA');
  inicio date := (date_trunc('month', public.hoy_local(demo.id('EMPRESA'))) - interval '1 month')::date;
  r      jsonb;
  u_admin uuid := (SELECT id FROM auth.users WHERE email = 'admin@demo.hn');
  u_dueno uuid := (SELECT id FROM auth.users WHERE email = 'dueno@demo.hn');
BEGIN
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos'), (e, 'conciliacion')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM demo.como('dueno@demo.hn');
  -- Pagos fijos
  PERFORM demo.g('PF_ALQ', (public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Alquiler del local', 'categoria_id', demo.id('CAT_ALQ'),
    'monto_estimado_centavos', 1200000, 'frecuencia', 'mensual', 'dia', 5, 'fecha_inicio', inicio, 'cuenta_dinero_id', demo.id('BAC')))->>'pago_fijo_id')::uuid);
  PERFORM demo.g('PF_LUZ', (public.crear_pago_fijo(e, jsonb_build_object('nombre', 'Energía eléctrica', 'categoria_id', demo.id('CAT_LUZ'),
    'monto_estimado_centavos', 240000, 'frecuencia', 'mensual', 'dia', 20, 'fecha_inicio', inicio + 19, 'cuenta_dinero_id', demo.id('BAC')))->>'pago_fijo_id')::uuid);
  -- Un producto de buen margen comprado y vendido el mes pasado (así el mes cierra con utilidad cobrada para repartir).
  PERFORM demo.g('TAL', (public.crear_producto(e, '{"codigo": "TAL-500", "nombre": "Taladro eléctrico 500 W",
    "precio_venta_centavos": 250000}', gen_random_uuid())->>'producto_id')::uuid);
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', demo.id('PROV1'), 'bodega_id', demo.id('B1'),
    'numero_documento', 'FL-1088', 'fecha', inicio + 11, 'condicion', 'contado', 'cuenta_dinero_id', demo.id('BAC'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', demo.id('TAL'), 'cantidad', 10, 'costo_unitario', 100000))), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('fecha', inicio + 12,
    'lineas', jsonb_build_array(demo.l('TAL', 8)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  -- Fondos y socios
  PERFORM demo.g('F_REINV', (public.crear_fondo(e, jsonb_build_object('nombre', 'Reinversión', 'tipo', 'reinversion', 'meta_tipo', 'ninguna',
    'cuenta_dinero_id', demo.id('ATL')), 'Demo: fondo de reinversión')->>'fondo_id')::uuid);
  PERFORM demo.g('F_EMER', (public.crear_fondo(e, jsonb_build_object('nombre', 'Emergencias', 'tipo', 'emergencias', 'meta_tipo', 'meses_pagos_fijos',
    'meta_meses', 3), 'Demo: fondo de emergencias')->>'fondo_id')::uuid);
  PERFORM demo.g('S_MARIA', (public.guardar_socio(e, jsonb_build_object('user_id', u_dueno,
    'nombre', 'María López', 'porcentaje', 60), 'Demo: socia principal')->>'socio_id')::uuid);
  PERFORM demo.g('S_CARLOS', (public.guardar_socio(e, jsonb_build_object('user_id', u_admin, 'nombre', 'Carlos Mejía', 'porcentaje', 40), 'Demo: socio')->>'socio_id')::uuid);
  PERFORM public.guardar_regla_distribucion(e, jsonb_build_object('fondos', jsonb_build_array(
      jsonb_build_object('fondo_id', demo.id('F_REINV'), 'porcentaje', 40), jsonb_build_object('fondo_id', demo.id('F_EMER'), 'porcentaje', 30)),
    'socios_porcentaje', 30), 'Demo: regla del negocio');
  PERFORM public.cerrar_mes(e, extract(year FROM inicio)::int, extract(month FROM inicio)::int, 'Demo: cierre del mes pasado');
  PERFORM public.distribuir_utilidades(e, extract(year FROM inicio)::int, extract(month FROM inicio)::int, '{}'::jsonb, 'Demo: reparto del mes pasado', gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;

DO $$
DECLARE
  e      uuid := demo.id('EMPRESA');
  inicio date := (date_trunc('month', public.hoy_local(demo.id('EMPRESA'))) - interval '1 month')::date;
  r      jsonb;
BEGIN
  PERFORM demo.como('dueno@demo.hn');
  -- Estado de cuenta del BAC del mes pasado: 3 movimientos se emparejan solos; el cheque lo cobró el banco
  -- 5 días después (queda para emparejarlo a mano) y la comisión y los intereses quedan para crearlos.
  r := public.importar_estado_cuenta(e, demo.id('BAC'), extract(year FROM inicio)::int, extract(month FROM inicio)::int,
    jsonb_build_object('archivo', 'bac_mes_pasado.csv', 'saldo_inicial_centavos', 9840000, 'saldo_final_centavos', 6285484,
      'filas', jsonb_build_array(
        jsonb_build_object('fecha', inicio + 3, 'descripcion', 'DEBITO TRASLADO CAJA CHICA', 'referencia', 'Fondo de caja chica', 'monto_centavos', -200000),
        jsonb_build_object('fecha', inicio + 5, 'descripcion', 'PAGO ALQUILER LOCAL', 'monto_centavos', -1200000),
        jsonb_build_object('fecha', inicio + 16, 'descripcion', 'CHEQUE 000451', 'monto_centavos', -1000000),
        jsonb_build_object('fecha', inicio + 11, 'descripcion', 'TRANSFERENCIA DISTRIBUIDORA LARA', 'referencia', 'FL-1088', 'monto_centavos', -1150000),
        jsonb_build_object('fecha', inicio + 27, 'descripcion', 'COMISION MANEJO DE CUENTA', 'monto_centavos', -5750),
        jsonb_build_object('fecha', inicio + 27, 'descripcion', 'INTERESES GANADOS', 'monto_centavos', 1234))), gen_random_uuid());
  PERFORM demo.g('CONC1', (r->>'conciliacion_id')::uuid);
  PERFORM demo.como(NULL);
END $$;

-- 9) (app 0.8.0) Para Reportes: comisiones (Juan 5 %, Ana 3 %, sobre la ganancia), ventas de Juan y de Ana
--    este mes, un turno de Ana cerrado con un faltante de L 50.00 y una venta anulada con motivo (bitácora).
--    Las fechas nunca caen en el mes pasado (ya está cerrado).
DO $$
DECLARE
  e       uuid := demo.id('EMPRESA');
  hoy     date := public.hoy_local(demo.id('EMPRESA'));
  mes1    date := date_trunc('month', public.hoy_local(demo.id('EMPRESA')))::date;
  u_juan  uuid := (SELECT id FROM auth.users WHERE email = 'vendedor@demo.hn');
  u_ana   uuid := (SELECT id FROM auth.users WHERE email = 'cajero@demo.hn');
  caja1   uuid := (SELECT id FROM public.caja WHERE empresa_id = demo.id('EMPRESA') AND punto_emision = '001');
  r       jsonb;
  t       jsonb;
  v_anul  uuid;
  v_apr   uuid;
  v_saldo bigint;
BEGIN
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "ganancia"}', 'Demo: comisiones sobre la ganancia');
  PERFORM public.fijar_porcentaje_comision(e, u_juan, 5, hoy, 'Demo: comisión de Juan');
  PERFORM public.fijar_porcentaje_comision(e, u_ana, 3, hoy, 'Demo: comisión de Ana');
  -- Ventas de contado a nombre de Juan (vendedor) y una al crédito que todavía no le da comisión.
  PERFORM public.registrar_venta(e, jsonb_build_object('vendedor_id', u_juan,
    'lineas', jsonb_build_array(demo.l('TAL', 1), demo.l('VAR', 5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('vendedor_id', u_juan, 'cliente_id', demo.id('CLI3'),
    'lineas', jsonb_build_array(demo.l('PVC', 4)), 'pagos', '[{"forma":"credito"}]'::jsonb), gen_random_uuid());
  -- Una venta que se anula (queda en la bitácora con su motivo).
  r := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(demo.l('CLA', 2)),
    'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  v_anul := (r->>'venta_id')::uuid;
  -- Turno de Ana: abre con lo que tiene la caja, vende y al cerrar cuenta L 50.00 menos.
  v_saldo := (SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE caja_id = caja1);
  PERFORM demo.como('cajero@demo.hn');
  t := public.abrir_turno(e, caja1, v_saldo, gen_random_uuid());
  PERFORM public.registrar_venta(e, jsonb_build_object('vendedor_id', u_ana,
    'lineas', jsonb_build_array(demo.l('VAR', 3), demo.l('PVC', 2)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  v_apr := (public.solicitar_anulacion_venta(v_anul, 'El cliente se arrepintió antes de llevarse el clavo', gen_random_uuid())->>'aprobacion_id')::uuid;
  PERFORM demo.como('dueno@demo.hn');
  v_saldo := (SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE caja_id = caja1);
  PERFORM demo.como('cajero@demo.hn');
  PERFORM public.cerrar_turno((t->>'turno_id')::uuid, v_saldo - 5000, gen_random_uuid());
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.resolver_aprobacion(v_apr, true, 'Revisado con el cliente', gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;

-- 10) (app 0.12.0, núcleo 0.18.0) Precio mayorista: cemento a L 250.00 desde 20 sacos, varilla a L 170.00 desde 30 y la Constructora
--     Ríos como cliente mayorista (con una venta de hoy a ese precio). Con un núcleo anterior se salta.
DO $$
DECLARE e uuid := demo.id('EMPRESA');
BEGIN
  IF to_regprocedure('interno.mayorista_de(public.producto, numeric, numeric, boolean)') IS NULL THEN
    RETURN;
  END IF;
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.editar_producto(e, demo.id('CEM'), '{"precio_mayorista_centavos": 25000, "cantidad_mayorista": 20}', 'Demo: precio de mayoreo');
  PERFORM public.editar_producto(e, demo.id('VAR'), '{"precio_mayorista_centavos": 17000, "cantidad_mayorista": 30}', 'Demo: precio de mayoreo');
  PERFORM public.editar_tercero(e, demo.id('CLI1'), '{"es_mayorista": true}', 'Demo: compra para sus obras');
  PERFORM public.registrar_venta(e, jsonb_build_object('cliente_id', demo.id('CLI1'),
    'lineas', jsonb_build_array(demo.l('VAR', 6)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;

-- 11) (app 0.12.0, núcleo 0.18.0) Garantías: taladro con 180 días y pintura con 30. Llegan 5 taladros más, se
--     vende uno hoy a Pedro Castillo y él ya dejó un reclamo (abierto). Con un núcleo anterior se salta.
DO $$
DECLARE
  e uuid := demo.id('EMPRESA');
  v jsonb;
BEGIN
  IF to_regprocedure('public.registrar_reclamo_garantia(uuid, jsonb, uuid)') IS NULL THEN
    RETURN;
  END IF;
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.editar_producto(e, demo.id('TAL'), '{"dias_garantia": 180}');
  PERFORM public.editar_producto(e, demo.id('PIN'), '{"dias_garantia": 30}');
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', demo.id('PROV1'), 'bodega_id', demo.id('B1'),
    'numero_documento', 'FL-1102', 'fecha', public.hoy_local(e), 'condicion', 'contado', 'cuenta_dinero_id', demo.id('BAC'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', demo.id('TAL'), 'cantidad', 5, 'costo_unitario', 100000))), gen_random_uuid());
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', demo.id('CLI3'),
    'lineas', jsonb_build_array(demo.l('TAL', 1)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM demo.g('V_TAL', (v->>'venta_id')::uuid);
  PERFORM public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v->'venta_id', 'linea', 1,
    'motivo', 'Se calienta y se apaga', 'descripcion', 'Lo trajo en su caja, sin golpes.'), gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;

-- 12) (app 0.12.0, núcleo 0.18.0) Abonos con cheque: el Taller Mejía abona L 200.00 con un cheque de hoy y la
--     Constructora Ríos L 100.00 con uno posfechado (dentro de 12 días). Los dos quedan "por depositar".
DO $$
DECLARE e uuid := demo.id('EMPRESA');
BEGIN
  IF to_regprocedure('public.depositar_cheque(uuid, uuid, date, text, uuid)') IS NULL THEN
    RETURN;
  END IF;
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', demo.id('CLI2'), 'referencia', 'Recibo 301',
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', 20000, 'numero_cheque', '004518',
      'banco_emisor', 'Banco Atlántida', 'fecha_cheque', public.hoy_local(e)))), gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', demo.id('CLI1'), 'referencia', 'Recibo 302',
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'cheque', 'monto_centavos', 10000, 'numero_cheque', '120077',
      'banco_emisor', 'Ficohsa', 'fecha_cheque', public.hoy_local(e) + 12))), gen_random_uuid());
  PERFORM demo.como(NULL);
END $$;

-- 13) (app 0.12.0) Para "Antigüedad de saldos": un saldo viejo de Pedro Castillo de antes de empezar (factura de
--     hace unos 5 meses, vencida hace más de 90 días). Con un núcleo anterior también sirve (saldos iniciales: 0.9.0).
DO $$
DECLARE
  e      uuid := demo.id('EMPRESA');
  inicio date := (SELECT fecha_inicio FROM public.empresa WHERE id = demo.id('EMPRESA'));
BEGIN
  PERFORM demo.como('dueno@demo.hn');
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', demo.id('CLI3'), 'numero_documento', 'F-2025-88',
    'fecha_documento', inicio - 150, 'fecha_vencimiento', inicio - 120, 'monto_centavos', 85000, 'fecha', public.hoy_local(e)), gen_random_uuid());  -- (el mes pasado ya está cerrado)
  PERFORM demo.como(NULL);
END $$;
