-- PRUEBA: combinaciones de módulos (solo contabilidad, solo servicios, ventas sin inventario, ventas+inventario sin compras, sin ventas, todo encendido, con apartados y comisiones; apagar compras, inventario, dinero, ventas, fiscal_hn, apartados o comisiones a mitad de mes y encender otros): en cada una se opera con lo que hay (también cobros, condonación, devoluciones, apartados y comisiones), lo apagado rechaza lo nuevo y deja corregir, y el cuadre global se cumple (debe = haber, dinero = subcuentas con rastro, kardex = inventario, CxC = Clientes, CxP = Proveedores, saldo a favor, anticipos y comisiones = sus pasivos, ISV por pagar = ventas - notas de crédito, bitácora intacta)

-- Ayudantes de esta prueba (la base es una copia desechable).
CREATE FUNCTION pruebas.c_id(p_emp text, p_clave text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT pruebas.id(p_emp || ':' || p_clave) $$;
CREATE FUNCTION pruebas.c_guardar(p_emp text, p_clave text, p_valor uuid) RETURNS uuid LANGUAGE sql AS
  $$ SELECT pruebas.guardar(p_emp || ':' || p_clave, p_valor) $$;
CREATE FUNCTION pruebas.c_activo(p_e uuid, p_modulo text) RETURNS boolean LANGUAGE sql STABLE AS
  $$ SELECT public.modulo_esta_activo(p_e, p_modulo) $$;

-- Empresa nueva (con la llave del proveedor) con su dueño y licencia; sin turnos obligatorios.
CREATE FUNCTION pruebas.c_empresa(p_emp text, p_modulos text[]) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE u uuid := gen_random_uuid(); e uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (id, email) VALUES (u, p_emp || '@combinacion.hn');
  INSERT INTO pruebas.usuario (apodo, id) VALUES (p_emp, u);
  PERFORM pruebas.como('service_role');
  e := public.crear_empresa_inicial(jsonb_build_object('nombre', 'Combinación ' || p_emp, 'fecha_inicio', '2026-01-01',
         'modulos', to_jsonb(p_modulos), 'dueno', jsonb_build_object('user_id', u)));
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.licencia (empresa_id, vence_el) VALUES (e, public.hoy_local() + 30);
  PERFORM pruebas.guardar(p_emp, e);
  PERFORM pruebas.como(p_emp);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de combinaciones');
  RETURN e;
END $$;

-- Prepara lo que pide cada módulo activo (solo lo que falte; se puede llamar otra vez al encender).
CREATE FUNCTION pruebas.c_preparar(p_emp text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  e    uuid := pruebas.empresa(p_emp);
  v_caja uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  v_caja := (SELECT id FROM public.caja WHERE empresa_id = e AND punto_emision = '001');
  PERFORM pruebas.c_guardar(p_emp, 'CAJA', v_caja);
  PERFORM pruebas.como(p_emp);
  IF pruebas.c_id(p_emp, 'CLI') IS NULL THEN
    PERFORM pruebas.c_guardar(p_emp, 'CLI', (public.crear_tercero(e, '{"nombre": "Cliente", "es_cliente": true, "limite_credito_centavos": 10000000}',
      gen_random_uuid())->>'tercero_id')::uuid);
  END IF;
  IF pruebas.c_id(p_emp, 'S') IS NULL AND (pruebas.c_activo(e, 'ventas') OR pruebas.c_activo(e, 'inventario')) THEN
    PERFORM pruebas.c_guardar(p_emp, 'S', (public.crear_producto(e, jsonb_build_object('codigo', 'SERV', 'nombre', 'Servicio', 'tipo', 'servicio',
      'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', 11500),
      gen_random_uuid())->>'producto_id')::uuid);
  END IF;
  IF pruebas.c_id(p_emp, 'B1') IS NULL AND pruebas.c_activo(e, 'inventario') THEN
    PERFORM pruebas.c_guardar(p_emp, 'B1', (public.crear_bodega(e, (SELECT sucursal_id FROM public.caja WHERE id = v_caja), 'B1', 'Bodega')->>'bodega_id')::uuid);
    PERFORM pruebas.c_guardar(p_emp, 'P', (public.crear_producto(e, jsonb_build_object('codigo', 'BIEN', 'nombre', 'Bien',
      'precio_venta_centavos', 2300, 'tipo_impuesto', 'ISV15'), gen_random_uuid())->>'producto_id')::uuid);
    PERFORM public.cargar_saldo_inicial(e, pruebas.c_id(p_emp, 'B1'), '2026-01-02',
      jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, 'P'), 'cantidad', 100, 'costo_unitario', 1000)), gen_random_uuid());
  END IF;
  IF pruebas.c_id(p_emp, 'PROV') IS NULL AND pruebas.c_activo(e, 'compras') THEN
    PERFORM pruebas.c_guardar(p_emp, 'PROV', (public.crear_tercero(e, '{"nombre": "Proveedor", "es_proveedor": true, "plazo_dias": 30}',
      gen_random_uuid())->>'tercero_id')::uuid);
  END IF;
  IF pruebas.c_id(p_emp, 'BANCO') IS NULL AND pruebas.c_activo(e, 'dinero') THEN
    PERFORM pruebas.c_guardar(p_emp, 'CAJA1', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja 1',
      'caja_id', v_caja))->>'cuenta_dinero_id')::uuid);
    PERFORM pruebas.c_guardar(p_emp, 'BANCO', (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "Banco", "banco": "BAC",
      "numero_cuenta": "1234-5678", "tipo_cuenta": "cheques"}')->>'cuenta_dinero_id')::uuid);
    PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', pruebas.c_id(p_emp, 'BANCO'),
      'monto_centavos', 1000000, 'fecha', '2026-01-02'), gen_random_uuid());
    PERFORM pruebas.c_guardar(p_emp, 'CAT', (public.crear_categoria_gasto(e, 'Papelería', '6.1.02.05')->>'categoria_id')::uuid);
  END IF;
  IF pruebas.c_id(p_emp, 'CAI') IS NULL AND pruebas.c_activo(e, 'fiscal_hn') THEN
    PERFORM pruebas.c_guardar(p_emp, 'CAI', (public.registrar_cai(e, jsonb_build_object('caja_id', v_caja, 'tipo_documento', 'factura',
      'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00001000',
      'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')))->>'cai_rango_id')::uuid);
    PERFORM public.registrar_cai(e, jsonb_build_object('caja_id', v_caja, 'tipo_documento', 'nota_credito',
      'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7', 'rango_desde', '001-001-03-00000001', 'rango_hasta', '001-001-03-00001000',
      'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')));
  END IF;
  IF pruebas.c_id(p_emp, 'COM') IS NULL AND pruebas.c_activo(e, 'comisiones') THEN
    PERFORM public.configurar_comisiones(e, '{"activas": true}', 'Prueba de combinaciones');
    PERFORM public.fijar_porcentaje_comision(e, pruebas.usuario(p_emp), 10, '2026-01-01', 'Prueba de combinaciones');
    PERFORM pruebas.c_guardar(p_emp, 'COM', e);
  END IF;
END $$;

-- Una venta de una línea en una fecha.
CREATE FUNCTION pruebas.c_venta(p_emp text, p_prod text, p_cant numeric, p_forma text, p_fecha date) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.registrar_venta(pruebas.empresa(p_emp), jsonb_strip_nulls(jsonb_build_object('fecha', p_fecha,
    'cliente_id', CASE WHEN p_forma = 'credito' THEN pruebas.c_id(p_emp, 'CLI') END,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, p_prod), 'cantidad', p_cant)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', p_forma)))), gen_random_uuid());
END $$;

-- Opera con lo que esté activo (fase 1 = día 10, fase 2 = día 20). Guarda lo que se corrige después.
CREATE FUNCTION pruebas.c_operar(p_emp text, p_fase integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  e  uuid := pruebas.empresa(p_emp);
  d  date := CASE p_fase WHEN 1 THEN '2026-01-10' ELSE '2026-01-20' END::date;
  v  jsonb;
  s  jsonb;
  c  jsonb;
BEGIN
  PERFORM pruebas.como(p_emp);
  PERFORM public.registrar_asiento(e, d, 'Asiento manual', pruebas.lineas('1.1.01.01', '4.2.01.01', 1000), gen_random_uuid());
  IF pruebas.c_activo(e, 'ventas') THEN
    v := pruebas.c_venta(p_emp, 'S', 2, 'credito', d);
    PERFORM pruebas.afirmar(v->>'estado' = 'emitida', p_emp || ': venta de servicio al crédito');
    s := public.solicitar_anulacion_venta((v->>'venta_id')::uuid, 'Prueba de anulación', gen_random_uuid());
    PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Anulada en la prueba', gen_random_uuid());
    v := pruebas.c_venta(p_emp, 'S', 1, 'credito', d);
    PERFORM public.condonar_saldo_cxc(e, jsonb_build_object('venta_id', v->>'venta_id', 'monto_centavos', 1, 'fecha', d), 'Redondeo de prueba',
      gen_random_uuid());
    IF pruebas.c_activo(e, 'dinero') THEN
      v := pruebas.c_venta(p_emp, 'S', 1, 'efectivo', d);
      -- 2b-2b: cobro de lo que debe el cliente y devolución del servicio de contado a saldo a favor (vale).
      PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.c_id(p_emp, 'CLI'), 'fecha', d,
        'pagos', '[{"forma":"efectivo","monto_centavos":5000}]'::jsonb), gen_random_uuid());
      PERFORM public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
        'motivo', 'Prueba de devolución', 'destino', 'saldo_favor', 'fecha', d), gen_random_uuid());
    END IF;
    IF pruebas.c_activo(e, 'inventario') THEN
      v := pruebas.c_venta(p_emp, 'P', 3, 'credito', d);
      PERFORM pruebas.c_guardar(p_emp, 'VB' || p_fase, (v->>'venta_id')::uuid);
      IF pruebas.c_activo(e, 'dinero') THEN
        PERFORM pruebas.c_venta(p_emp, 'P', 1, 'tarjeta', d);
      END IF;
    END IF;
    -- Apartados: uno se completa y otro queda vigente (se cancela con el módulo apagado).
    IF pruebas.c_activo(e, 'apartados') AND pruebas.c_activo(e, 'dinero') THEN
      v := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.c_id(p_emp, 'CLI'), 'fecha', d,
             'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, 'P'), 'cantidad', 1)),
             'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
      PERFORM public.completar_apartado((v->>'apartado_id')::uuid, jsonb_build_object('fecha', d,
        'pagos', '[{"forma":"efectivo","monto_centavos":1300}]'::jsonb), gen_random_uuid());
      v := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.c_id(p_emp, 'CLI'), 'fecha', d,
             'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, 'P'), 'cantidad', 1)),
             'pagos', '[{"forma":"efectivo","monto_centavos":700}]'::jsonb), gen_random_uuid());
      PERFORM pruebas.c_guardar(p_emp, 'AP' || p_fase, (v->>'apartado_id')::uuid);
    END IF;
    -- Comisiones: se paga lo devengado (las ventas de contado ya devengaron).
    IF pruebas.c_activo(e, 'comisiones') AND pruebas.c_activo(e, 'dinero')
       AND coalesce((SELECT por_pagar_centavos FROM public.v_comision_vendedor WHERE empresa_id = e AND vendedor_id = pruebas.usuario(p_emp)), 0) > 0 THEN
      v := public.pagar_comisiones(e, jsonb_build_object('vendedor_id', pruebas.usuario(p_emp), 'cuenta_dinero_id', pruebas.c_id(p_emp, 'BANCO'),
             'fecha', d, 'hasta', d), gen_random_uuid());
      PERFORM pruebas.c_guardar(p_emp, 'LIQ' || p_fase, (v->>'liquidacion_id')::uuid);
    END IF;
  END IF;
  IF pruebas.c_activo(e, 'compras') THEN
    c := public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.c_id(p_emp, 'PROV'), 'bodega_id', pruebas.c_id(p_emp, 'B1'),
           'numero_documento', 'F-' || p_fase, 'fecha', d, 'condicion', 'credito',
           'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, 'P'), 'cantidad', 5, 'costo_unitario', 1200))), gen_random_uuid());
    IF pruebas.c_activo(e, 'dinero') THEN
      v := public.pagar_proveedor(e, (c->>'compra_id')::uuid, 1000, d, NULL, gen_random_uuid(), 'Abono', NULL, pruebas.c_id(p_emp, 'BANCO'));
    ELSE
      v := public.pagar_proveedor(e, (c->>'compra_id')::uuid, 1000, d, 'caja', gen_random_uuid(), 'Abono');
    END IF;
    PERFORM pruebas.c_guardar(p_emp, 'PAGO' || p_fase, (v->>'pago_id')::uuid);
  END IF;
  IF pruebas.c_activo(e, 'dinero') THEN
    v := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.c_id(p_emp, 'BANCO'), 'categoria_id', pruebas.c_id(p_emp, 'CAT'),
           'monto_centavos', 500, 'descripcion', 'Papel', 'fecha', d), gen_random_uuid());
    PERFORM pruebas.c_guardar(p_emp, 'GASTO' || p_fase, (v->>'gasto_id')::uuid);
  END IF;
  IF pruebas.c_activo(e, 'inventario') THEN
    -- Al final (así se puede anular: no hay movimientos posteriores en la fase).
    v := public.ajustar_inventario(e, pruebas.c_id(p_emp, 'B1'), d, jsonb_build_array(jsonb_build_object('producto_id', pruebas.c_id(p_emp, 'P'),
           'cantidad_contada', pruebas.existencia(p_emp || ':B1', p_emp || ':P') - 1)), 'Conteo físico', gen_random_uuid());
    PERFORM pruebas.c_guardar(p_emp, 'AJUSTE' || p_fase, (v->>'documento_id')::uuid);
  END IF;
END $$;

-- Lo apagado rechaza lo nuevo y deja corregir lo de la fase 1.
CREATE FUNCTION pruebas.c_apagado(p_emp text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  e  uuid := pruebas.empresa(p_emp);
  s  jsonb;
BEGIN
  PERFORM pruebas.como(p_emp);
  IF NOT pruebas.c_activo(e, 'ventas') THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', p_emp || ': venta con ventas apagado');
    IF pruebas.c_id(p_emp, 'VB1') IS NOT NULL THEN
      s := public.solicitar_anulacion_venta(pruebas.c_id(p_emp, 'VB1'), 'Corrección con el módulo apagado', gen_random_uuid());
      PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Corrección aprobada', gen_random_uuid());
    END IF;
  END IF;
  IF NOT pruebas.c_activo(e, 'inventario') THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.ajustar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.c_id(p_emp, 'B1'),
      '2026-01-20', '[]', 'Conteo'), 'MODULO_INACTIVO', p_emp || ': ajuste con inventario apagado');
    IF pruebas.c_id(p_emp, 'AJUSTE1') IS NOT NULL AND pruebas.c_id(p_emp, 'VB1') IS NULL THEN
      PERFORM public.anular_documento_inventario(pruebas.c_id(p_emp, 'AJUSTE1'), 'Conteo mal hecho', gen_random_uuid());
    END IF;
  END IF;
  IF NOT pruebas.c_activo(e, 'compras') THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', p_emp || ': compra con compras apagado');
    IF pruebas.c_id(p_emp, 'PAGO1') IS NOT NULL THEN
      PERFORM public.anular_pago_proveedor(pruebas.c_id(p_emp, 'PAGO1'), 'Pago mal registrado', gen_random_uuid());
    END IF;
  END IF;
  IF NOT pruebas.c_activo(e, 'dinero') THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', p_emp || ': gasto con dinero apagado');
    IF pruebas.c_id(p_emp, 'GASTO1') IS NOT NULL THEN
      PERFORM public.anular_gasto(pruebas.c_id(p_emp, 'GASTO1'), 'Gasto duplicado', gen_random_uuid());
    END IF;
    IF pruebas.c_activo(e, 'ventas') THEN
      PERFORM pruebas.debe_fallar(format('SELECT pruebas.c_venta(%L, %L, 1, %L, %L)', p_emp, 'S', 'efectivo', '2026-01-20'),
        'módulo "dinero"', p_emp || ': contado sin dinero');
    END IF;
  END IF;
  IF NOT pruebas.c_activo(e, 'apartados') AND pruebas.c_id(p_emp, 'AP1') IS NOT NULL THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', p_emp || ': apartado con el módulo apagado');
    PERFORM public.cancelar_apartado(pruebas.c_id(p_emp, 'AP1'), 'Cancelado con el módulo apagado', '{}', gen_random_uuid());
  END IF;
  IF NOT pruebas.c_activo(e, 'comisiones') AND pruebas.c_id(p_emp, 'LIQ1') IS NOT NULL THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.pagar_comisiones(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', p_emp || ': pagar comisiones apagado');
    PERFORM public.anular_pago_comisiones(pruebas.c_id(p_emp, 'LIQ1'), 'Pago mal hecho', gen_random_uuid());
  END IF;
  IF NOT pruebas.c_activo(e, 'fiscal_hn') THEN
    PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, '{}'), 'MODULO_INACTIVO', p_emp || ': CAI con fiscal_hn apagado');
  END IF;
END $$;

-- Cuadre global de una empresa.
CREATE FUNCTION pruebas.c_cuadre(p_emp text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e uuid := pruebas.empresa(p_emp);
BEGIN
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT coalesce(sum(debe_centavos), 0) = coalesce(sum(haber_centavos), 0) FROM public.asiento_linea WHERE empresa_id = e),
    p_emp || ': debe = haber');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento a WHERE a.empresa_id = e
    AND (SELECT sum(debe_centavos) - sum(haber_centavos) FROM public.asiento_linea l WHERE l.asiento_id = a.id) <> 0), p_emp || ': cada asiento cuadra');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
    WHERE d.empresa_id = e AND interno.saldo_dinero(d.id) <> coalesce(pruebas.saldo_libros(e, c.codigo), 0)), p_emp || ': dinero = subcuentas');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento_linea l JOIN public.cuenta_dinero d ON d.cuenta_id = l.cuenta_id
    WHERE l.empresa_id = e AND (SELECT count(*) FROM public.dinero_movimiento m WHERE m.asiento_linea_id = l.id) <> 1), p_emp || ': rastro de cada línea');
  PERFORM pruebas.afirmar(coalesce((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e), 0)
    = coalesce(pruebas.saldo_libros(e, '1.1.03.01'), 0), p_emp || ': kardex = inventario contable');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = coalesce(pruebas.saldo_libros(e, '1.1.02.01'), 0)
    AND coalesce((SELECT sum(saldo_centavos) FROM public.v_cxc_documento WHERE empresa_id = e), 0) = interno.total_cxc(e), p_emp || ': CxC = Clientes');
  PERFORM pruebas.afirmar(interno.total_cxp(e) = coalesce(pruebas.saldo_libros(e, '2.1.01.01'), 0), p_emp || ': CxP = Proveedores');
  PERFORM pruebas.afirmar(coalesce((SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida'), 0)
    - coalesce((SELECT sum(impuesto_centavos) FROM public.devolucion WHERE empresa_id = e AND estado = 'aplicada'), 0)
    = coalesce(pruebas.saldo_libros(e, '2.1.02.01'), 0), p_emp || ': ISV por pagar = ventas no anuladas - notas de crédito');
  PERFORM pruebas.afirmar(interno.total_saldo_favor(e) = coalesce(pruebas.saldo_libros(e, '2.1.04.02'), 0), p_emp || ': saldo a favor = su pasivo');
  PERFORM pruebas.afirmar(coalesce((SELECT sum(interno.anticipos_apartado(a.id)) FROM public.apartado a WHERE a.empresa_id = e AND a.estado = 'vigente'), 0)
    = coalesce(pruebas.saldo_libros(e, '2.1.04.01'), 0), p_emp || ': anticipos = su pasivo');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = coalesce(pruebas.saldo_libros(e, '2.1.03.04'), 0), p_emp || ': comisiones = su pasivo');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora(e)), p_emp || ': bitácora intacta');
END $$;

-- Una combinación completa: crear, operar, apagar/encender a mitad de mes, operar, corregir y cuadrar.
CREATE FUNCTION pruebas.c_combinacion(p_emp text, p_modulos text[], p_apagar text[] DEFAULT '{}', p_encender text[] DEFAULT '{}')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  e uuid;
  m text;
BEGIN
  e := pruebas.c_empresa(p_emp, p_modulos);
  PERFORM pruebas.c_preparar(p_emp);
  PERFORM pruebas.c_operar(p_emp, 1);
  PERFORM pruebas.c_cuadre(p_emp);
  PERFORM pruebas.como('superusuario');
  FOREACH m IN ARRAY p_apagar LOOP            -- en el orden dado (los que dependen primero)
    UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = m;
  END LOOP;
  FOREACH m IN ARRAY p_encender LOOP
    INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, m) ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  END LOOP;
  PERFORM pruebas.c_preparar(p_emp);
  PERFORM pruebas.c_apagado(p_emp);
  PERFORM pruebas.c_operar(p_emp, 2);
  PERFORM pruebas.c_cuadre(p_emp);
  PERFORM pruebas.como('superusuario');
  RETURN p_emp || ' OK';
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO anon, authenticated, service_role;

DO $$
BEGIN
  PERFORM pruebas.c_combinacion('solo_contabilidad', '{}');
  PERFORM pruebas.c_combinacion('solo_servicios', '{ventas}');
  PERFORM pruebas.c_combinacion('servicios_y_dinero', '{ventas,dinero}', '{dinero}');
  PERFORM pruebas.c_combinacion('ventas_sin_inventario_fiscal', '{ventas,dinero,fiscal_hn}', '{fiscal_hn}');
  PERFORM pruebas.c_combinacion('ventas_inventario_sin_compras', '{ventas,inventario,dinero}', '{inventario}');
  PERFORM pruebas.c_combinacion('ventas_inventario_sin_dinero', '{ventas,inventario}', '{ventas}');
  PERFORM pruebas.c_combinacion('sin_ventas', '{inventario,compras,dinero}', '{compras}');
  PERFORM pruebas.c_combinacion('todo', '{ventas,inventario,compras,dinero,fiscal_hn}');
  PERFORM pruebas.c_combinacion('todo_apaga_compras', '{ventas,inventario,compras,dinero,fiscal_hn}', '{compras}');
  PERFORM pruebas.c_combinacion('todo_apaga_inventario', '{ventas,inventario,compras,dinero,fiscal_hn}', '{compras,inventario}');
  PERFORM pruebas.c_combinacion('todo_apaga_dinero', '{ventas,inventario,compras,dinero,fiscal_hn}', '{dinero}');
  PERFORM pruebas.c_combinacion('todo_apaga_fiscal', '{ventas,inventario,compras,dinero,fiscal_hn}', '{fiscal_hn}');
  PERFORM pruebas.c_combinacion('todo_apaga_ventas', '{ventas,inventario,compras,dinero,fiscal_hn}', '{fiscal_hn,ventas}');
  PERFORM pruebas.c_combinacion('enciende_a_mitad', '{ventas}', '{}', '{dinero,inventario,compras}');
  -- 2b-2b: apartados y comisiones.
  PERFORM pruebas.c_combinacion('todo_2b2b', '{ventas,inventario,compras,dinero,fiscal_hn,apartados,comisiones}');
  PERFORM pruebas.c_combinacion('apaga_apartados', '{ventas,inventario,dinero,apartados,comisiones}', '{apartados}');
  PERFORM pruebas.c_combinacion('apaga_comisiones', '{ventas,inventario,dinero,apartados,comisiones}', '{comisiones}');
  PERFORM pruebas.c_combinacion('apaga_ventas_2b2b', '{ventas,inventario,dinero,fiscal_hn,apartados,comisiones}', '{apartados,comisiones,fiscal_hn,ventas}');
  PERFORM pruebas.c_combinacion('servicios_comisiones', '{ventas,dinero,comisiones}', '{dinero}');
  PERFORM pruebas.c_combinacion('enciende_2b2b_a_mitad', '{ventas,inventario,dinero}', '{}', '{apartados,comisiones}');
  -- Una dependencia mal pedida a mitad de mes se rechaza y no cambia nada.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.modulo_activo SET activo = false WHERE empresa_id = %L AND modulo = %L',
    pruebas.empresa('todo'), 'inventario'), 'MODULO_DEPENDENCIA', 'apagar inventario con compras activo');
  PERFORM pruebas.debe_fallar(format('UPDATE public.modulo_activo SET activo = false WHERE empresa_id = %L AND modulo = %L',
    pruebas.empresa('todo_2b2b'), 'ventas'), 'MODULO_DEPENDENCIA', 'apagar ventas con comisiones y apartados activos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.modulo_activo WHERE empresa_id = pruebas.empresa('todo') AND activo) = 6, 'todo sigue encendido');
END $$;
