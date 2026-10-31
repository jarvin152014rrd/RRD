-- PRUEBA: (0.14.0) el cajero cobra abonos (ve saldos por factura sin ventas.ver, sin costos ni ganancias; restringido a su sucursal no ve las de otra ni los saldos iniciales); venta previa con descuento con ISV que suma (subtotal - descuento = total); marca del negocio con volver al anterior (solo dueño y admin)
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s1   uuid;
  s2   uuid;
  c2   uuid;
  va   jsonb;
  vb   jsonb;
  r    jsonb;
  f    jsonb;
  pn   uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de cobro del cajero');
  SELECT id INTO s1 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  c2 := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  PERFORM public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja Norte', 'caja_id', c2));

  -- Deudas de Constructora Ríos (CLI1), a mano:
  --   saldo inicial F-OLD (sin sucursal)                 = 500
  --   venta al crédito en la principal: 2 tornillos x 1,500 = 3,000
  --   venta al crédito en la Norte: 0.5 h de mano de obra x 23,000 = 11,500
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'numero_documento', 'F-OLD',
    'fecha_documento', '2025-12-01', 'monto_centavos', 500), gen_random_uuid());
  va := public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI1') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  vb := public.registrar_venta(e, pruebas.venta('S1', 0.5, 'credito', 'CLI1') || jsonb_build_object('caja_id', c2), gen_random_uuid());
  PERFORM pruebas.afirmar((va->>'total_centavos')::bigint = 3000 AND (vb->>'total_centavos')::bigint = 11500, 'ventas 3,000 y 11,500');

  -- 1) El cajero (sin ventas.ver) ve lo que debe el cliente, factura por factura.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('ventas.ver', e) AND public.tiene_permiso('cobros.ver_saldos', e), 'cajero: ver_saldos sin ventas.ver');
  r := public.cxc_para_cobrar(e, pruebas.id('CLI1'));
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 15000 AND (r->>'todas_las_sucursales')::boolean, 'debe 500 + 3,000 + 11,500 = 15,000');
  PERFORM pruebas.afirmar(jsonb_array_length(r->'clientes'->0->'facturas') = 3, 'tres facturas pendientes');
  PERFORM pruebas.afirmar(r::text !~* 'costo|ganancia|utilidad|margen', 'sin costos ni ganancias');
  -- Sin costos ni reportes de toda la empresa.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_kardex) = 0, 'cajero no lee el kardex (costos)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_existencia WHERE costo_promedio IS NOT NULL OR valor_centavos IS NOT NULL) = 0, 'existencias sin costo');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxc_cliente) = 0, 'no lee la vista de CxC de toda la empresa');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_resultados(%L, 2026, 1)', e), 'SIN_PERMISO', 'sin estado de resultados');

  -- 2) Cobra un abono de 1,000 en efectivo a la venta de la principal: queda 2,000 en esa factura.
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', pruebas.id('CAJA001'),
    'pagos', jsonb_build_array(jsonb_build_object('forma', 'efectivo', 'monto_centavos', 1000)),
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', va->>'venta_id', 'monto_centavos', 1000))), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'aplicado_centavos')::bigint = 1000, 'abono de 1,000 aplicado');
  SELECT x INTO f FROM jsonb_array_elements(public.cxc_para_cobrar(e, pruebas.id('CLI1'))->'clientes'->0->'facturas') x
   WHERE x->>'venta_id' = va->>'venta_id';
  PERFORM pruebas.afirmar((f->>'saldo_centavos')::bigint = 2000, 'la factura queda en 2,000');

  -- 3) Restringido a la principal: no ve la factura de la Norte ni el saldo inicial (sin sucursal).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('cajero_a'), ARRAY[s1], 'Cajero de la principal');
  PERFORM pruebas.como('cajero_a');
  r := public.cxc_para_cobrar(e, pruebas.id('CLI1'));
  PERFORM pruebas.afirmar(NOT (r->>'todas_las_sucursales')::boolean AND (r->>'total_centavos')::bigint = 2000
    AND jsonb_array_length(r->'clientes'->0->'facturas') = 1, 'restringido: solo la factura de su sucursal (2,000)');
  PERFORM pruebas.afirmar((public.cxc_para_cobrar(e)->>'total_centavos')::bigint = 2000, 'lista general también filtrada');

  -- 4) El vendedor (sin ventas.cobrar ni ver_saldos) no la usa.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cxc_para_cobrar(%L)', e), 'SIN_PERMISO', 'vendedor no ve saldos');

  -- 5) Venta previa: descuento con ISV y suma visible.
  --    Tornillo L 15.00 con ISV x 10, 10 % de descuento: subtotal 15,000 - descuento 1,500 = 13,500.
  --    Producto SIN ISV L 100.00 (ISV15): con ISV 11,500; 10 % -> sin ISV 9,000 + ISV 1,350 = 10,350; descuento con ISV 1,150.
  PERFORM pruebas.como('dueno_a');
  pn := (public.crear_producto(e, '{"codigo": "SIN-ISV", "nombre": "Servicio sin ISV", "tipo": "servicio",
         "precio_venta_centavos": 10000, "precio_incluye_isv": false}', gen_random_uuid())->>'producto_id')::uuid;
  r := public.calcular_venta_previa(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'descuento_porcentaje', 10),
         jsonb_build_object('producto_id', pn, 'cantidad', 1, 'descuento_porcentaje', 10))));
  PERFORM pruebas.afirmar((r->'lineas'->0->>'bruto_con_isv_centavos')::bigint = 15000
    AND (r->'lineas'->0->>'descuento_con_isv_centavos')::bigint = 1500, 'línea 1: 15,000 - 1,500');
  PERFORM pruebas.afirmar((r->'lineas'->1->>'bruto_con_isv_centavos')::bigint = 11500
    AND (r->'lineas'->1->>'descuento_con_isv_centavos')::bigint = 1150, 'línea 2: 11,500 - 1,150');
  PERFORM pruebas.afirmar((r->>'subtotal_con_isv_centavos')::bigint = 26500 AND (r->>'descuento_con_isv_centavos')::bigint = 2650
    AND (r->>'total_centavos')::bigint = 23850, 'total: 26,500 - 2,650 = 23,850');

  -- 6) Marca del negocio: admin cambia, vuelve al anterior; cajero no; datos inválidos rechazados.
  PERFORM pruebas.como('admin_a');
  r := public.configurar_marca(e, '{"nombre_comercial": "Ferretería El Roble", "color_principal": "#123456"}', 'Colores nuevos');
  PERFORM pruebas.afirmar(r->'marca'->>'color_principal' = '#123456' AND (r->>'puede_volver')::boolean, 'marca cambiada');
  r := public.configurar_marca(e, '{"color_principal": "#654321"}', 'Probar otro color');
  r := public.configurar_marca(e, '{"volver_anterior": true}', 'No me gustó');
  PERFORM pruebas.afirmar(r->'marca'->>'color_principal' = '#123456' AND r->'marca'->>'nombre_comercial' = 'Ferretería El Roble', 'volvió al anterior');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_marca(%L, %L::jsonb, %L)', e, '{"color_acento": "rojo"}', 'Color malo'), 'DATO_INVALIDO', 'color inválido');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_marca(%L, %L::jsonb, %L)', e, '{"rtn": "1"}', 'Cambiar RTN'), 'DATO_INVALIDO', 'no toca datos fiscales');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_marca(%L, %L::jsonb, %L)', e, '{"color_acento": "#000000"}', 'Cajero cambia'), 'SIN_PERMISO', 'cajero no cambia la marca');
  PERFORM pruebas.afirmar(public.marca_empresa(e)->'marca'->>'color_principal' = '#123456', 'cualquiera de la empresa lee la marca');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.marca_empresa(%L)', e), 'NO_PERTENECE', 'otra empresa no la lee');
END $$;
