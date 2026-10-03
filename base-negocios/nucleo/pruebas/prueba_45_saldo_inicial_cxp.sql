-- PRUEBA: saldos iniciales de proveedores (factura, fecha, vencimiento, monto) contra Saldos de apertura: salen en CxP y antigüedad, se pagan y se anulan; activar inventario/compras con saldo previo se rechaza y el procedimiento de carga inicial lo resuelve
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  b    uuid := pruebas.empresa('B');
  hoy  date;
  s1   jsonb; s2 jsonb; s3 jsonb;
  pg   jsonb;
  op   uuid := gen_random_uuid();
  r    record;
  bb   uuid; pb uuid; prb uuid;
BEGIN
  PERFORM pruebas.preparar_inventario();
  hoy := public.hoy_local(e);

  -- Solo el dueño (permiso especial compras.saldo_inicial).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'X-1', 'fecha_documento', hoy, 'monto_centavos', 100)),
    'SIN_PERMISO', 'admin carga saldo inicial');

  -- Tres facturas pendientes al empezar (asiento con fecha de hoy):
  --   S1 PROV1 F-889 de hace 100 días, 250,000, venció hace 70 días
  --   S2 PROV2 F-120 de hace 45 días, 80,000, vence = factura + plazo 0 = hace 45 días
  --   S3 PROV1 F-990 de hace 10 días, 12,345, vence en 20 días
  PERFORM pruebas.como('dueno_a');
  s1 := public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'F-889',
          'fecha_documento', hoy - 100, 'fecha_vencimiento', hoy - 70, 'monto_centavos', 250000, 'fecha', hoy), op);
  s2 := public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'numero_documento', 'F-120',
          'fecha_documento', hoy - 45, 'monto_centavos', 80000, 'fecha', hoy), gen_random_uuid());
  s3 := public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'F-990',
          'fecha_documento', hoy - 10, 'fecha_vencimiento', hoy + 20, 'monto_centavos', 12345, 'fecha', hoy, 'notas', 'Carga del Excel'), gen_random_uuid());
  PERFORM pruebas.afirmar((s1->>'numero')::int = 1 AND (s3->>'numero')::int = 3 AND NOT (s1->>'duplicado')::boolean, 'numerados 1..3');
  -- Reintento.
  PERFORM pruebas.afirmar((public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'OTRA',
          'fecha_documento', hoy, 'monto_centavos', 1, 'fecha', hoy), op)->>'duplicado')::boolean, 'reintento no duplica');

  -- Libros: Proveedores 250,000 + 80,000 + 12,345 = 342,345 contra Saldos de apertura.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 342345 AND pruebas.saldo_libros(e, '3.3.01.03') = -342345, 'asientos de apertura');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = (s1->>'asiento_id')::uuid)
                          = '3.3.01.03:250000/0 2.1.01.01:0/250000', 'líneas del saldo inicial');
  PERFORM pruebas.afirmar((SELECT origen FROM public.asiento WHERE id = (s1->>'asiento_id')::uuid) = 'saldo_inicial_cxp', 'origen');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'cxp_saldo_inicial' AND accion = 'INSERT'
    AND registro_id = s1->>'saldo_inicial_id' AND usuario_id = pruebas.usuario('dueno_a')), 'en bitácora');

  -- Vistas de CxP y antigüedad (días desde la fecha de la FACTURA).
  PERFORM pruebas.como('admin_a');
  SELECT * INTO r FROM public.v_cxp_proveedor WHERE proveedor_id = pruebas.id('PROV1');
  PERFORM pruebas.afirmar(r.facturas = 2 AND r.saldo_centavos = 262345 AND r.mas_de_90_centavos = 250000
    AND r.de_0_a_30_centavos = 12345 AND r.vencido_centavos = 250000, 'PROV1: ' || to_jsonb(r)::text);
  SELECT * INTO r FROM public.v_cxp_proveedor WHERE proveedor_id = pruebas.id('PROV2');
  PERFORM pruebas.afirmar(r.saldo_centavos = 80000 AND r.de_31_a_60_centavos = 80000 AND r.vencido_centavos = 80000, 'PROV2: ' || to_jsonb(r)::text);
  SELECT * INTO r FROM public.v_cxp_documento WHERE numero_documento = 'F-120';
  PERFORM pruebas.afirmar(r.origen = 'saldo_inicial' AND r.compra_id IS NULL AND r.documento_id = (s2->>'saldo_inicial_id')::uuid
    AND r.dias = 45 AND r.fecha_vencimiento = hoy - 45 AND r.dias_vencido = 45 AND r.fecha_contable = hoy, 'documento F-120');
  PERFORM pruebas.afirmar((SELECT sum(saldo_centavos) FROM public.v_cxp_proveedor) = pruebas.saldo_libros(e, '2.1.01.01'), 'vista = libros');

  -- Datos malos y facturas repetidas.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'f-889', 'fecha_documento', hoy, 'monto_centavos', 5, 'fecha', hoy)), 'YA_EXISTE', 'factura repetida');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-889', hoy, 'credito', 'P1', 1, 100)), 'saldo inicial', 'compra con la factura del saldo inicial');
  PERFORM public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'C-1', hoy, 'credito', 'P1', 1, 1000), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'numero_documento', 'C-1', 'fecha_documento', hoy, 'monto_centavos', 5, 'fecha', hoy)), 'YA_EXISTE', 'saldo inicial de una compra ya registrada');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy + 1, 'monto_centavos', 5, 'fecha', hoy)), 'FECHA_INVALIDA', 'factura posterior a la apertura');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy - 5, 'fecha_vencimiento', hoy - 6, 'monto_centavos', 5, 'fecha', hoy)), 'FECHA_INVALIDA', 'vence antes de la factura');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy, 'monto_centavos', 0, 'fecha', hoy)), 'DATO_INVALIDO', 'monto cero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy, 'monto_centavos', 10.5, 'fecha', hoy)), 'DATO_INVALIDO', 'monto con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy, 'monto_centavos', 5, 'saldo', 9)), 'DATO_INVALIDO', 'campo desconocido');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_cxp(%L, %L, NULL)', e,
    jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'Z-1', 'fecha_documento', hoy, 'monto_centavos', 5)), 'FALTA_ID_OPERACION', 'sin id_operacion');

  -- Se paga como una compra (por su documento_id). No antes de la apertura.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, s1->>'saldo_inicial_id', hoy - 1, 'banco'), 'FECHA_INVALIDA', 'pago antes de la apertura');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 250001, %L, %L, gen_random_uuid())', e, s1->>'saldo_inicial_id', hoy, 'banco'), 'PAGO_EXCEDE_SALDO', 'pagar de más');
  pg := public.pagar_proveedor(e, (s1->>'saldo_inicial_id')::uuid, 100000, hoy, 'banco', gen_random_uuid(), 'Cheque 5');
  PERFORM pruebas.afirmar((pg->>'saldo_restante_centavos')::bigint = 150000, 'abono a saldo inicial: quedan 150,000');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxp_documento WHERE numero_documento = 'F-889') = 150000, 'vista 150,000');
  -- Y su pago se anula: vuelve a 250,000.
  PERFORM public.anular_pago_proveedor((pg->>'pago_id')::uuid, 'Cheque rebotado', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxp_documento WHERE numero_documento = 'F-889') = 250000, 'pago anulado: 250,000');

  -- Anular un saldo inicial: solo sin pagos vigentes, una vez, solo el dueño.
  pg := public.pagar_proveedor(e, (s3->>'saldo_inicial_id')::uuid, 12345, hoy, 'caja', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_saldo_inicial_cxp(%L, %L, gen_random_uuid())', s3->>'saldo_inicial_id', 'Ya se había pagado'), 'SIN_PERMISO', 'admin anula saldo inicial');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_saldo_inicial_cxp(%L, %L, gen_random_uuid())', s3->>'saldo_inicial_id', 'Ya se había pagado'), 'tiene pagos', 'anular con pagos');
  PERFORM public.anular_pago_proveedor((pg->>'pago_id')::uuid, 'Era de otra factura', gen_random_uuid());
  PERFORM public.anular_saldo_inicial_cxp((s3->>'saldo_inicial_id')::uuid, 'Ya se había pagado antes de empezar', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_saldo_inicial_cxp(%L, %L, gen_random_uuid())', s3->>'saldo_inicial_id', 'Otra vez'), 'YA_ANULADO', 'anular dos veces');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 1, %L, %L, gen_random_uuid())', e, s3->>'saldo_inicial_id', hoy, 'caja'), 'anulado', 'pagar saldo anulado');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cxp_saldo_inicial SET monto_centavos = 1 WHERE id = %L', s1->>'saldo_inicial_id'), '42501', 'usuario no edita la tabla');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.cxp_saldo_inicial SET monto_centavos = 1 WHERE id = %L', s1->>'saldo_inicial_id'), 'PROHIBIDO', 'ni a la fuerza');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.cxp_saldo_inicial WHERE id = %L', s1->>'saldo_inicial_id'), 'PROHIBIDO', 'borrar saldo inicial');
  PERFORM pruebas.como('dueno_a');
  -- Libros: 342,345 - 12,345 + compra C-1 1,150 = 331,150; apertura -330,000.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 331150 AND pruebas.saldo_libros(e, '3.3.01.03') = -330000
    AND pruebas.saldo_libros(e, '1.1.01.01') = 0 AND pruebas.saldo_libros(e, '1.1.01.03') = 0, 'libros tras anular');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_cxp(e) = pruebas.saldo_libros(e, '2.1.01.01'), 'CxP del módulo = libros');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxp_documento WHERE origen = 'saldo_inicial') = 2, 'el anulado ya no sale');

  -- ===== Activar módulos con saldo previo (empresa B) =====
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(b, hoy, 'Inventario que traía', pruebas.lineas('1.1.03.01', '3.1.01.01', 50000), gen_random_uuid());
  PERFORM public.registrar_asiento(b, hoy, 'Factura pendiente', pruebas.lineas('6.1.02.10', '2.1.01.01', 30000), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', b, 'inventario'), 'cargar_saldo_inicial', 'activar inventario con saldo');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', b, 'compras'), 'registrar_saldo_inicial_cxp', 'activar compras con saldo');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', b, 'compras'), 'MODULO_CON_SALDO', 'clave del error');
  -- Procedimiento (P-07): pasar los saldos a apertura, activar y cargar el detalle.
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(b, hoy, 'Saldo de inventario a apertura', pruebas.lineas('3.3.01.03', '1.1.03.01', 50000), gen_random_uuid());
  PERFORM public.registrar_asiento(b, hoy, 'Saldo de proveedores a apertura', pruebas.lineas('2.1.01.01', '3.3.01.03', 30000), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (b, 'inventario'), (b, 'compras');
  PERFORM pruebas.como('dueno_b');
  bb  := (public.crear_bodega(b, (SELECT id FROM public.sucursal WHERE empresa_id = b AND codigo = '001'), 'PRI', 'Principal')->>'bodega_id')::uuid;
  pb  := (public.crear_producto(b, '{"codigo": "AZU", "nombre": "Azúcar", "precio_venta_centavos": 2000}', gen_random_uuid())->>'producto_id')::uuid;
  prb := (public.crear_tercero(b, '{"nombre": "Distribuidora", "es_proveedor": true}', gen_random_uuid())->>'tercero_id')::uuid;
  PERFORM public.cargar_saldo_inicial(b, bb, hoy, jsonb_build_array(jsonb_build_object('producto_id', pb, 'cantidad', 50, 'costo_unitario', 1000)), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_cxp(b, jsonb_build_object('proveedor_id', prb, 'numero_documento', 'D-7',
    'fecha_documento', hoy - 3, 'monto_centavos', 30000, 'fecha', hoy), gen_random_uuid());
  -- Inventario 50,000 y proveedores 30,000 otra vez; apertura en 0 (Dr 50,000 + 30,000 = Cr 30,000 + 50,000).
  PERFORM pruebas.afirmar(pruebas.saldo_libros(b, '1.1.03.01') = 50000 AND pruebas.saldo_libros(b, '2.1.01.01') = 30000
    AND pruebas.saldo_libros(b, '3.3.01.03') = 0, 'saldos de B después de la carga inicial');
  -- Apagar y volver a encender con todo cuadrado: se permite.
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = b AND modulo = 'inventario';
  UPDATE public.modulo_activo SET activo = true  WHERE empresa_id = b AND modulo = 'inventario';
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
