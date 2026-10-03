-- PRUEBA: dependencias entre módulos como datos (no se activa sin lo que necesita, no se apaga si otro activo lo usa, el error dice cuál); negocio de solo servicios: ventas sin inventario ni dinero (catálogo con "ventas", solo servicios, crédito sí, contado no, un bien se rechaza); apagar compras, ventas, dinero y fiscal_hn: lo nuevo se rechaza, leer y corregir sigue (anular pago, compra, gasto y venta; cerrar el turno abierto); las cuentas del módulo apagado siguen sin asientos manuales; nada se borra y todo cuadra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s1   uuid;
  b1   uuid;
  v    jsonb;
BEGIN
  -- 1) Dependencias mínimas guardadas como datos.
  PERFORM pruebas.afirmar((SELECT string_agg(modulo || '>' || requiere, ',' ORDER BY modulo, requiere) FROM public.modulo_dependencia)
    = 'compras>inventario,dinero>contabilidad,fiscal_hn>ventas,inventario>contabilidad,ventas>contabilidad', 'dependencias');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', e, 'fiscal_hn'),
    'necesita "ventas"', 'fiscal_hn sin ventas');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', e, 'compras'),
    'necesita "inventario"', 'compras sin inventario');
  -- Varios en una sola sentencia: se revisa al final (orden indiferente).
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fiscal_hn'), (e, 'ventas');
  PERFORM pruebas.debe_fallar(format('UPDATE public.modulo_activo SET activo = false WHERE empresa_id = %L AND modulo = %L', e, 'ventas'),
    'lo usa "fiscal_hn"', 'no se apaga ventas con fiscal_hn activo');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.modulo_activo WHERE empresa_id = %L AND modulo = %L', e, 'contabilidad'),
    'MODULO_DEPENDENCIA', 'tampoco se borra la fila de contabilidad');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'fiscal_hn';
  PERFORM pruebas.afirmar((SELECT estuvo_activo FROM public.modulo_activo WHERE empresa_id = e AND modulo = 'fiscal_hn'), 'recuerda que estuvo activo');

  -- 2) Negocio de solo servicios: ventas sin inventario ni dinero.
  PERFORM pruebas.como('dueno_a');
  s1 := (public.crear_producto(e, jsonb_build_object('codigo', 'CORTE', 'nombre', 'Corte de cabello', 'tipo', 'servicio',
          'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', 11500),
          gen_random_uuid())->>'producto_id')::uuid;
  b1 := (public.crear_producto(e, jsonb_build_object('codigo', 'CHAMPU', 'nombre', 'Champú', 'precio_venta_centavos', 23000),
          gen_random_uuid())->>'producto_id')::uuid;
  PERFORM public.cambiar_precio_producto(e, s1, 12650, 'Precio nuevo del corte');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_bodega(%L, (SELECT id FROM public.sucursal WHERE empresa_id = %L AND codigo = %L), %L, %L)',
    e, e, '001', 'B9', 'Bodega'), 'MODULO_INACTIVO', 'bodegas siguen siendo de inventario');
  PERFORM pruebas.guardar('CLI_S', (public.crear_tercero(e, '{"nombre": "Cliente salón", "es_cliente": true, "limite_credito_centavos": 100000}',
    gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM pruebas.como('cajero_a');
  v := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI_S'),
         'lineas', jsonb_build_array(jsonb_build_object('producto_id', s1, 'cantidad', 2)), 'pagos', '[{"forma":"credito"}]'::jsonb), gen_random_uuid());
  -- A mano: 2 x 126.50 = 253.00 con ISV 15 % -> sin ISV round(25,300/1.15) = 22,000; ISV 3,300.
  PERFORM pruebas.afirmar(v->>'estado' = 'emitida' AND (v->>'total_centavos')::bigint = 25300 AND (v->>'impuesto_centavos')::bigint = 3300
    AND v->>'numero_documento' LIKE 'T-001-001-%', 'venta de servicios al crédito sin inventario ni dinero: ' || v::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', s1, 'cantidad', 1)), 'pagos', '[{"forma":"efectivo"}]'::jsonb)),
    'módulo "dinero"', 'contado sin dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('cliente_id', pruebas.id('CLI_S'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', b1, 'cantidad', 1)),
                       'pagos', '[{"forma":"credito"}]'::jsonb)), 'solo puede llevar servicios', 'un bien sin inventario');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.02.01') = 25300 AND interno.total_cxc(e) = 25300
    AND pruebas.saldo_libros(e, '2.1.02.01') = 3300 AND pruebas.saldo_libros(e, '4.1.01.01') = 22000
    AND NOT EXISTS (SELECT 1 FROM public.inventario_movimiento WHERE empresa_id = e), 'servicios: CxC, ISV y ventas; sin kardex');
END $$;

-- 3) Todo encendido y después se apagan fiscal_hn, ventas, compras y dinero (inventario sigue).
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  t    jsonb;
  vt   jsonb;
  vc   jsonb;
  s    jsonb;
  g    jsonb;
  c    jsonb;
  p    jsonb;
  n    integer;
BEGIN
  PERFORM pruebas.preparar_ventas();          -- inventario, compras, dinero, ventas y fiscal_hn
  PERFORM pruebas.como('cajero_a');
  t := public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  vt := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());                     -- 2 x 15.00 = 3,000 en efectivo
  vc := public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid());  -- 45,000 al crédito
  PERFORM pruebas.como('dueno_a');
  c := public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'F-88', '2026-01-10', 'credito', 'P2', 10, 1500), gen_random_uuid());
  p := public.pagar_proveedor(e, (c->>'compra_id')::uuid, 5000, '2026-01-12', NULL, gen_random_uuid(), 'Recibo 1', NULL, pruebas.id('BANCO'));
  g := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
         'monto_centavos', 20000, 'descripcion', 'Luz'), gen_random_uuid());
  SELECT count(*) INTO n FROM public.asiento WHERE empresa_id = e;

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('UPDATE public.modulo_activo SET activo = false WHERE empresa_id = %L AND modulo = %L', e, 'inventario'),
    'lo usa "compras"', 'no se apaga inventario con compras activo');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo IN ('fiscal_hn', 'compras', 'dinero');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'ventas';

  -- Lo nuevo se rechaza.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P1', 1)), 'MODULO_INACTIVO', 'venta nueva');
  PERFORM pruebas.debe_fallar(format('SELECT public.abrir_turno(%L, %L, 0, gen_random_uuid())', e, pruebas.id('CAJA001')), 'MODULO_INACTIVO', 'turno nuevo');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV2', 'B1', 'F-89', '2026-01-13', 'credito', 'P2', 1, 1500)), 'MODULO_INACTIVO', 'compra nueva');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, NULL, gen_random_uuid(), NULL, NULL, %L)', e, c->>'compra_id',
    '2026-01-13', pruebas.id('BANCO')), 'MODULO_INACTIVO', 'pago nuevo');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', e, jsonb_build_object('cuenta_dinero_id',
    pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 100, 'descripcion', 'X')), 'MODULO_INACTIVO', 'gasto nuevo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cotizacion(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)))), 'MODULO_INACTIVO', 'cotización nueva');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cai(%L, %L)', e, '{}'), 'MODULO_INACTIVO', 'CAI nuevo');
  -- Las cuentas de los módulos apagados siguen sin asientos manuales.
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-15', pruebas.lineas('1.1.02.01', '4.1.01.01', 100)), 'ahora apagado', 'CxC con ventas apagado');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-15', pruebas.lineas('6.1.02.02', '2.1.01.01', 100)), 'ahora apagado', 'CxP con compras apagado');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-15', pruebas.lineas('6.1.02.02', '1.1.03.01', 100)), 'CUENTA_CONTROLADA', 'inventario (activo)');
  -- Leer sigue igual.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_venta WHERE empresa_id = e) = 3 AND (SELECT count(*) FROM public.v_cxp_documento) = 2
    AND (public.donde_esta_mi_dinero(e)->>'total_centavos') IS NOT NULL, 'lecturas y reportes');

  -- Corregir sigue: anular pago, compra y gasto; pedir y aprobar la anulación de una venta; cerrar el turno.
  PERFORM public.anular_pago_proveedor((p->>'pago_id')::uuid, 'Pago duplicado', gen_random_uuid());
  PERFORM public.anular_compra((c->>'compra_id')::uuid, 'Factura equivocada', gen_random_uuid());
  PERFORM public.anular_gasto((g->>'gasto_id')::uuid, 'Gasto de otra empresa', gen_random_uuid());
  s := public.solicitar_anulacion_venta((vc->>'venta_id')::uuid, 'Cliente devolvió la mercadería', gen_random_uuid());
  PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Aprobada por el dueño', gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM public.cerrar_turno((t->>'turno_id')::uuid, 3000, gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado FROM public.venta WHERE id = (vc->>'venta_id')::uuid) = 'anulada'
    AND (SELECT anulada_en IS NOT NULL FROM public.compra WHERE id = (c->>'compra_id')::uuid)
    AND (SELECT estado FROM public.turno_caja WHERE id = (t->>'turno_id')::uuid) = 'cerrado', 'correcciones hechas con los módulos apagados');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE empresa_id = e) > n, 'nada se borró');

  -- Cuadre global con los módulos apagados.
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e), 'debe = haber');
  PERFORM pruebas.afirmar((SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'), 'kardex = inventario');
  PERFORM pruebas.afirmar(interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01'), 'CxC = Clientes');
  PERFORM pruebas.afirmar(interno.total_cxp(e) = pruebas.saldo_libros(e, '2.1.01.01'), 'CxP = Proveedores');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta cu ON cu.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, cu.codigo)), 'dinero = subcuentas');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 3000, 'el efectivo de la venta sigue en la caja');
  PERFORM pruebas.afirmar((SELECT coalesce(sum(impuesto_centavos), 0) FROM public.venta WHERE empresa_id = e AND estado = 'emitida')
    = pruebas.saldo_libros(e, '2.1.02.01'), 'ISV por pagar = ventas no anuladas');

  -- Volver a encender: ventas y compras cuadran con sus cuentas (sin MODULO_CON_SALDO).
  UPDATE public.modulo_activo SET activo = true WHERE empresa_id = e AND modulo IN ('ventas', 'compras', 'dinero');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.modulo_activo WHERE empresa_id = e AND activo) = 5, 'encendidos otra vez');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;

-- 4) Una venta pendiente de aprobación no se emite si después se apagaron inventario o dinero
--    (aprobar la emite: es una operación nueva); rechazarla sí se puede.
DO $$
DECLARE
  e   uuid := pruebas.empresa('B');
  vp  jsonb;
  vs  jsonb;
  s1  uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'ventas'), (e, 'inventario'), (e, 'dinero');
  PERFORM pruebas.como('dueno_b');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  PERFORM public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja',
    'caja_id', (SELECT id FROM public.caja WHERE empresa_id = e)));
  s1 := (public.crear_producto(e, jsonb_build_object('codigo', 'REC', 'nombre', 'Recarga', 'tipo', 'servicio',
          'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', 10000),
          gen_random_uuid())->>'producto_id')::uuid;
  PERFORM pruebas.como('superusuario');
  -- El dueño no tiene topes: las ventas pendientes las registra un admin nuevo de B (15 % > su tope de 10 %).
  INSERT INTO auth.users (id, email) VALUES ('b0000000-0000-0000-0000-000000000002', 'admin_b@prueba.hn');
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('admin_b', 'b0000000-0000-0000-0000-000000000002');
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES ('b0000000-0000-0000-0000-000000000002', e, 'admin');
  PERFORM pruebas.como('admin_b');
  vs := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', s1, 'cantidad', 1,
          'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  vp := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', s1, 'cantidad', 1,
          'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(vs->>'estado' = 'pendiente_aprobacion' AND vp->>'estado' = 'pendiente_aprobacion', 'pendientes');
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'dinero';
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', vs->>'aprobacion_id', 'Ok'),
    'módulo "dinero" no está activo', 'no se emite al contado sin dinero');
  PERFORM public.resolver_aprobacion((vp->>'aprobacion_id')::uuid, false, 'Ya no se cobra al contado', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT estado FROM public.venta WHERE id = (vp->>'venta_id')::uuid) = 'rechazada', 'rechazar sí se puede');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.asiento WHERE empresa_id = e AND origen = 'venta'), 'nada se emitió');
END $$;
