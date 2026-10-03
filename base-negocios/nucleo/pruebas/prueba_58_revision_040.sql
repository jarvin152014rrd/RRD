-- PRUEBA: correcciones de la revisión de 0.4.0: una factura cargada como saldo inicial no entra como compra aunque el proveedor venga en MAYÚSCULAS (A); activar un módulo toma el candado (B); los reintentos siguen funcionando y un id de otro tipo da ID_OPERACION_USADO (C); un producto sin decimales nunca queda con existencia fraccionaria, ni al anular (F)
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  lb   uuid;
  p4   uuid;
  op   uuid := gen_random_uuid();
  r    jsonb;
  d1   jsonb;
  d2   jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();

  -- A) Saldo inicial F-SI-1 de PROV1 (dueño). Luego la misma factura como compra:
  --    con el uuid en minúsculas, en MAYÚSCULAS y con la factura en minúsculas.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'),
    'numero_documento', 'F-SI-1', 'fecha_documento', '2026-01-01', 'monto_centavos', 50000, 'fecha', '2026-01-02'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-SI-1', '2026-01-05', 'credito', 'P1', 1, 1000)), 'saldo inicial', 'misma factura (uuid normal)');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    jsonb_set(pruebas.compra('PROV1', 'B1', 'f-si-1', '2026-01-05', 'credito', 'P1', 1, 1000),
              '{proveedor_id}', to_jsonb(upper(pruebas.id('PROV1')::text)))), 'saldo inicial', 'misma factura (uuid en MAYÚSCULAS)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra WHERE empresa_id = e) = 0, 'no entró ninguna compra');
  -- Otra factura del mismo proveedor (uuid en mayúsculas) sí entra.
  r := public.registrar_compra(e, jsonb_set(pruebas.compra('PROV1', 'B1', 'F-SI-2', '2026-01-05', 'credito', 'P1', 1, 1000),
              '{proveedor_id}', to_jsonb(upper(pruebas.id('PROV1')::text))), gen_random_uuid());
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'otra factura sí entra');

  -- B) El trigger de activación toma el candado de la empresa.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT prosrc FROM pg_proc WHERE oid = 'interno.revisar_activacion_modulo()'::regprocedure)
                          ~ 'PERFORM interno.bloquear_libros\(NEW.empresa_id\)', 'activación con bloquear_libros');

  -- C) Reintento del mismo tipo: mismo asiento. Mismo id en otro tipo: ID_OPERACION_USADO.
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_asiento(e, '2026-01-06', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), op);
  PERFORM pruebas.afirmar((public.registrar_asiento(e, '2026-01-06', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), op)->>'asiento_id')
                          = r->>'asiento_id', 'reintento devuelve el mismo asiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, %L)', e,
    pruebas.compra('PROV1', 'B1', 'F-9', '2026-01-05', 'credito', 'P1', 1, 1000), op), 'ID_OPERACION_USADO', 'compra con id de asiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_producto(%L, %L, %L)', e, '{"codigo":"X-1","nombre":"X"}', op), 'ID_OPERACION_USADO', 'producto con id de asiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, %L)', e, r->>'asiento_id', '2026-01-06', 'caja', op),
    'ID_OPERACION_USADO', 'pago con id de asiento');

  -- F) Producto con decimales P4: carga 1.5 (doc 1) y conteo a 3 (+1.5, doc 2).
  --    Existencia 3 (entera): se puede quitar "decimales". Anular el conteo
  --    dejaría 1.5 en un producto sin decimales: se rechaza.
  SELECT id INTO lb FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'LB';
  p4 := (public.crear_producto(e, jsonb_build_object('codigo', 'AZU-001', 'nombre', 'Azúcar', 'unidad_id', lb,
          'tipo_impuesto', 'EXENTO', 'permite_fracciones', true), gen_random_uuid())->>'producto_id')::uuid;
  d1 := public.cargar_saldo_inicial(e, pruebas.id('B2'), '2026-01-02',
          jsonb_build_array(jsonb_build_object('producto_id', p4, 'cantidad', 1.5, 'costo_unitario', 2000)), gen_random_uuid());
  d2 := public.ajustar_inventario(e, pruebas.id('B2'), '2026-01-03',
          jsonb_build_array(jsonb_build_object('producto_id', p4, 'cantidad_contada', 3)), 'Conteo de azúcar', gen_random_uuid());
  PERFORM public.editar_producto(e, p4, '{"permite_fracciones": false}', 'Se vende por libra entera');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_documento_inventario(%L, %L, gen_random_uuid())', d2->>'documento_id', 'Conteo mal hecho'),
    'unidades enteras', 'anular dejaría 1.5 sin decimales');
  PERFORM pruebas.afirmar(pruebas.existencia('B2', 'P1') = 0 AND
    (SELECT cantidad FROM public.inventario_saldo WHERE producto_id = p4) = 3, 'sigue en 3');
  -- Con la marca puesta otra vez, sí se anula (queda 1.5).
  PERFORM public.editar_producto(e, p4, '{"permite_fracciones": true}', 'Se vuelve a vender suelto');
  PERFORM public.anular_documento_inventario((d2->>'documento_id')::uuid, 'Conteo mal hecho', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT cantidad FROM public.inventario_saldo WHERE producto_id = p4) = 1.5, 'queda 1.5');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L, %L)', e, p4, '{"permite_fracciones": false}', 'Sin decimales'),
    'NO_PERMITIDO', 'no se quitan decimales con 1.5');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.inventario_saldo s JOIN public.producto p ON p.id = s.producto_id
                                       WHERE NOT p.permite_fracciones AND s.cantidad <> trunc(s.cantidad)), 'ninguna existencia fraccionaria sin decimales');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
