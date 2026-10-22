-- PRUEBA: (0.16.0) usuario limitado a su sucursal recibe solo lo suyo y el dueño todo como antes: lado de clientes (saldos iniciales, aplicaciones, condonaciones, pagos de cobros, saldo a favor y sus usos; cobro con excedente y con saldo a favor; devolución a saldo a favor; condonar solo en su sucursal); contador y proveedor con soporte no pierden nada; compras (líneas, pagos, anulaciones, saldos iniciales de toda la empresa) y v_cxp_documento; pagar y anular pagos solo de su sucursal (saldo inicial: no); v_comision_vendedor; donde_esta_mi_dinero; estado_fondos; proyeccion_flujo; conciliación (tablas, v_conciliacion, ver_conciliacion); cobro "a la más vieja" salta facturas de otra sucursal y rechaza aplicar a ellas; preferencias de alertas rechazadas; totales de compras, gastos y lo más vendido que cuadran con la suma de filas (y cifras a mano)
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  hoy    date;
  s1     uuid;
  s2     uuid;
  c2     uuid;
  fn1    uuid;      -- compra de la Norte
  fini   uuid;      -- compra de la principal (preparar_ventas)
  si1    uuid;      -- saldo inicial de proveedor
  v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb; v5 jsonb;
  p      jsonb;
  r      jsonb;
  r2     jsonb;
  f      jsonb;
  n      bigint;
  m      bigint;
  t      text;
  t2     text;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  hoy := public.hoy_local(e);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de sucursales 0.16.0');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones'), (e, 'conciliacion'), (e, 'fondos');
  PERFORM pruebas.como('dueno_a');
  SELECT id INTO s1 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  c2 := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  PERFORM pruebas.guardar('CAJA2', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja Norte', 'caja_id', c2))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('BANCO_P', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'banco', 'nombre', 'Banco principal', 'banco', 'BAC',
    'numero_cuenta', '1111-2222-3333', 'tipo_cuenta', 'cheques', 'sucursal_id', s1))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('BANCO_N', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'banco', 'nombre', 'Banco Norte', 'banco', 'Atlántida',
    'numero_cuenta', '4444-5555-6666', 'tipo_cuenta', 'cheques', 'sucursal_id', s2))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('B3', (public.crear_bodega(e, s2, 'B3', 'Bodega Norte')->>'bodega_id')::uuid);
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B3'), hoy,
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)), gen_random_uuid(), 'Surtir la Norte');
  -- Comisiones: base precio sin ISV, vendedor 10 %.
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "precio"}', 'Comisiones del equipo');
  PERFORM public.fijar_porcentaje_comision(e, pruebas.usuario('vendedor_a'), 10, NULL, 'Acuerdo con el vendedor');
  -- Admin y cajero solo en la Norte.
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[s2], 'Encargado de la Norte');
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('cajero_a'), ARRAY[s2], 'Cajero de la Norte');

  -- =========== Ventas (dueño; tornillo P1 = L 15.00 con ISV) ===========
  -- V4 principal, al crédito a CLI1, hace 2 días: 2 tornillos = 3,000 (la MÁS VIEJA)
  -- V3 Norte, al crédito a CLI1, ayer: 4 tornillos = 6,000
  -- V1 principal contado (vendedor): 2 tornillos = 3,000; V2 Norte contado (vendedor): 1 tornillo = 1,500;
  -- V5 Norte contado (vendedor): 1 h de mano de obra = 23,000.
  v4 := public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI1') || jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'fecha', hoy - 2), gen_random_uuid());
  v3 := public.registrar_venta(e, pruebas.venta('P1', 4, 'credito', 'CLI1') || jsonb_build_object('caja_id', c2, 'fecha', hoy - 1), gen_random_uuid());
  v1 := public.registrar_venta(e, pruebas.venta('P1', 2) || jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid());
  v2 := public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('caja_id', c2, 'vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid());
  v5 := public.registrar_venta(e, pruebas.venta('S1', 1) || jsonb_build_object('caja_id', c2, 'vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid());
  PERFORM pruebas.afirmar((v4->>'total_centavos')::bigint = 3000 AND (v3->>'total_centavos')::bigint = 6000 AND (v1->>'total_centavos')::bigint = 3000
    AND (v2->>'total_centavos')::bigint = 1500 AND (v5->>'total_centavos')::bigint = 23000, 'ventas a mano');

  -- =========== Cobro "a la más vieja" del cajero de la Norte ===========
  -- Sin restricción, 2,000 irían a V4 (principal, la más vieja). El cajero de la Norte: van a V3 (su sucursal).
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', c2,
         'pagos', '[{"forma":"efectivo","monto_centavos":2000}]'::jsonb), pruebas.guardar('COB1', gen_random_uuid()));
  PERFORM pruebas.afirmar(jsonb_array_length(r->'aplicaciones') = 1 AND (r->'aplicaciones'->0->>'venta_id')::uuid = (v3->>'venta_id')::uuid
    AND (r->'aplicaciones'->0->>'monto_centavos')::bigint = 2000 AND (r->'aplicaciones'->0->>'saldo_restante_centavos')::bigint = 4000,
    'a la más vieja de SU sucursal: V3 queda en 4,000: ' || (r->'aplicaciones')::text);
  PERFORM pruebas.afirmar((public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', c2,
         'pagos', '[{"forma":"efectivo","monto_centavos":2000}]'::jsonb), pruebas.id('COB1'))->>'duplicado')::boolean, 'reintento = mismo cobro');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L::jsonb, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'caja_id', c2, 'pagos', '[{"forma":"efectivo","monto_centavos":4500}]'::jsonb)), 'COBRO_EXCEDE_SALDO', 'en su sucursal debe 4,000 (no toma la principal)');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L::jsonb, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'caja_id', c2, 'pagos', '[{"forma":"efectivo","monto_centavos":500}]'::jsonb,
    'aplicar', jsonb_build_array(jsonb_build_object('venta_id', v4->>'venta_id', 'monto_centavos', 500)))), 'SUCURSAL_NO_PERMITIDA', 'aplicar a una factura de otra sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_cobro(%L, %L::jsonb, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'caja_id', c2, 'pagos', '[{"forma":"efectivo","monto_centavos":500}]'::jsonb)), 'COBRO_EXCEDE_SALDO', 'cliente sin deuda en su sucursal');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_documento_cxc((v4->>'venta_id')::uuid) = 3000 AND interno.saldo_documento_cxc((v3->>'venta_id')::uuid) = 4000,
    'la de la principal sigue en 3,000');
  -- El dueño (sin restricción): a la más vieja de TODA la empresa, igual que antes.
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', pruebas.id('CAJA001'),
         'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((r->'aplicaciones'->0->>'venta_id')::uuid = (v4->>'venta_id')::uuid AND (r->'aplicaciones'->0->>'saldo_restante_centavos')::bigint = 2000,
    'dueño: V4 (la más vieja) queda en 2,000');

  -- =========== Compras y pagos a proveedores ===========
  fini := (SELECT id FROM public.compra WHERE empresa_id = e AND numero_documento = 'F-INI-1');
  si1 := (public.registrar_saldo_inicial_cxp(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'numero_documento', 'SI-1',
          'fecha_documento', '2025-12-15', 'monto_centavos', 50000), gen_random_uuid())->>'saldo_inicial_id')::uuid;
  -- La Norte compra al crédito 10 tornillos a L 10.00 + ISV 15 %: 10,000 + 1,500 = 11,500.
  PERFORM pruebas.como('admin_a');
  fn1 := (public.registrar_compra(e, pruebas.compra('PROV2', 'B3', 'F-N-1', hoy, 'credito', 'P1', 10, 1000), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM pruebas.afirmar((SELECT total_centavos FROM public.compra WHERE id = fn1) = 11500, 'compra Norte 11,500');
  -- Paga 1,500 desde la caja Norte; paga 1,000 y lo anula.
  PERFORM public.pagar_proveedor(e, fn1, 1500, hoy, NULL, gen_random_uuid(), 'Abono 1', NULL, pruebas.id('CAJA2'));
  p := public.pagar_proveedor(e, fn1, 1000, hoy, NULL, gen_random_uuid(), 'Abono 2', NULL, pruebas.id('CAJA2'));
  PERFORM public.anular_pago_proveedor((p->>'pago_id')::uuid, 'Se pagó dos veces', gen_random_uuid());
  -- No paga lo de la principal ni el saldo inicial (es de toda la empresa).
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L::date, NULL, gen_random_uuid(), NULL, NULL, %L)', e, fini, hoy, pruebas.id('BANCO')),
    'SUCURSAL_NO_PERMITIDA', 'pagar compra de otra sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L::date, NULL, gen_random_uuid(), NULL, NULL, %L)', e, si1, hoy, pruebas.id('BANCO')),
    'SUCURSAL_NO_PERMITIDA', 'pagar un saldo inicial (de toda la empresa)');
  -- El dueño paga el saldo inicial (10,000) y la compra principal (100,000), y anula este último.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.guardar('PAGO_SI', (public.pagar_proveedor(e, si1, 10000, hoy, NULL, gen_random_uuid(), 'Cheque 1', NULL, pruebas.id('BANCO'))->>'pago_id')::uuid);
  p := public.pagar_proveedor(e, fini, 100000, hoy, NULL, gen_random_uuid(), 'Cheque 2', NULL, pruebas.id('BANCO'));
  PERFORM public.anular_pago_proveedor((p->>'pago_id')::uuid, 'Cheque sin fondos', gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', pruebas.id('PAGO_SI'), 'No es mío'),
    'SUCURSAL_NO_PERMITIDA', 'anular el pago de un saldo inicial');

  -- Lo que llega al admin de la Norte (tablas y vistas): solo lo suyo.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.compra) = 1 AND (SELECT count(*) FROM public.compra_linea) = 1
    AND (SELECT count(*) FROM public.compra_linea WHERE compra_id <> fn1) = 0, 'admin: solo la compra y la línea de la Norte');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.pago_proveedor) = 2 AND (SELECT count(*) FROM public.pago_proveedor WHERE compra_id IS DISTINCT FROM fn1) = 0
    AND (SELECT count(*) FROM public.pago_proveedor_anulacion) = 1 AND (SELECT count(*) FROM public.cxp_saldo_inicial) = 0, 'admin: sus pagos y su anulación; ningún saldo inicial');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cxp_documento) = 1
    AND (SELECT saldo_centavos FROM public.v_cxp_documento WHERE documento_id = fn1) = 10000, 'admin: v_cxp_documento solo F-N-1 con 10,000');
  -- El dueño ve TODO (igual que sin RLS): F-INI-1 544,000 (475,000 + ISV 69,000; el pago se anuló), SI-1 40,000, F-N-1 10,000.
  PERFORM pruebas.como('dueno_a');
  SELECT count(*), sum(saldo_centavos) INTO n, m FROM public.v_cxp_documento;
  PERFORM pruebas.afirmar(n = 3 AND m = 594000, 'dueño: 3 facturas por pagar = 594,000: ' || n || '/' || m);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.pago_proveedor) = 4 AND (SELECT count(*) FROM public.pago_proveedor_anulacion) = 2
    AND (SELECT count(*) FROM public.compra_linea) = 4 AND (SELECT count(*) FROM public.cxp_saldo_inicial) = 1, 'dueño: todos los pagos, anulaciones, líneas y saldos');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(saldo_centavos) FROM public.v_cxp_documento) = 594000 AND interno.total_cxp(e) = 594000, 'sin RLS: lo mismo que el dueño');

  -- =========== Totales de compras (a mano y = suma de filas) ===========
  PERFORM pruebas.como('admin_a');
  r := public.totales_compras(e, '2026-01-01', hoy);
  PERFORM pruebas.afirmar((r->>'cantidad')::int = 1 AND (r->>'total_centavos')::bigint = 11500 AND (r->>'por_pagar_centavos')::bigint = 10000
    AND (r->>'isv_centavos')::bigint = 1500 AND (r->>'solo_mis_sucursales')::boolean, 'admin: 11,500 comprado, 10,000 por pagar: ' || r::text);
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = (SELECT sum(total_centavos) FROM public.compra WHERE anulada_en IS NULL)
    AND (r->>'por_pagar_centavos')::bigint = (SELECT sum(d.saldo_centavos) FROM public.v_cxp_documento d WHERE d.origen = 'compra'), 'admin: = suma de sus filas');
  PERFORM pruebas.como('dueno_a');
  r := public.totales_compras(e, '2026-01-01', hoy);
  PERFORM pruebas.afirmar((r->>'cantidad')::int = 2 AND (r->>'total_centavos')::bigint = 555500 AND (r->>'por_pagar_centavos')::bigint = 554000
    AND (r->>'credito_centavos')::bigint = 555500 AND (r->>'contado_centavos')::bigint = 0 AND NOT (r->>'solo_mis_sucursales')::boolean,
    'dueño: 544,000 + 11,500 = 555,500; por pagar 554,000: ' || r::text);
  PERFORM pruebas.afirmar((r->>'por_pagar_centavos')::bigint = (SELECT sum(d.saldo_centavos) FROM public.v_cxp_documento d WHERE d.origen = 'compra'
                                                                  AND d.fecha_contable BETWEEN '2026-01-01' AND hoy)
    AND (r->>'total_centavos')::bigint = (SELECT sum(total_centavos) FROM public.compra WHERE anulada_en IS NULL AND fecha_contable BETWEEN '2026-01-01' AND hoy),
    'dueño: = suma de filas');
  r := public.totales_compras(e, '2026-01-01', hoy, pruebas.id('PROV2'));
  PERFORM pruebas.afirmar((r->>'cantidad')::int = 1 AND (r->>'total_centavos')::bigint = 11500, 'filtro por proveedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.totales_compras(%L, %L::date, %L::date)', e, hoy, hoy - 1), 'FECHA_INVALIDA', 'desde después de hasta');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.totales_compras(%L, %L::date, %L::date)', e, hoy, hoy), 'SIN_PERMISO', 'vendedor sin compras.ver');

  -- =========== Gastos y totales de gastos ===========
  -- Admin: 1,000 de papel desde la caja Norte. Dueño: 500 de papel desde la Caja 1 (principal) y 2,000 de luz desde
  -- el BAC (de toda la empresa). Después todo gasto del admin pide aprobación: 700 en espera.
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA2'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 1000, 'descripcion', 'Papel Norte'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 500, 'descripcion', 'Papel principal'), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 2000, 'descripcion', 'Luz de la empresa'), gen_random_uuid());
  PERFORM public.configurar_tope_rol(e, 'admin', 'gasto', 0, 500000, 'Todo gasto del admin pide aprobación');
  PERFORM pruebas.como('admin_a');
  r := public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA2'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 700, 'descripcion', 'Papel extra'), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'pendiente_aprobacion', 'gasto en espera');
  r := public.totales_gastos(e, hoy, hoy);
  PERFORM pruebas.afirmar((r->>'gastado_centavos')::bigint = 3000 AND (r->>'en_espera_centavos')::bigint = 700 AND (r->>'cantidad')::int = 3,
    'admin: 1,000 suyo + 2,000 de toda la empresa; 700 en espera: ' || r::text);
  PERFORM pruebas.afirmar((r->>'gastado_centavos')::bigint = (SELECT sum(monto_centavos) FROM public.v_gasto WHERE estado = 'aplicado' AND fecha_contable = hoy)
    AND (r->>'en_espera_centavos')::bigint = (SELECT sum(monto_centavos) FROM public.v_gasto WHERE estado = 'pendiente_aprobacion' AND fecha_contable = hoy)
    AND (r->>'cantidad')::int = (SELECT count(*) FROM public.v_gasto WHERE fecha_contable = hoy), 'admin: = suma de filas de v_gasto');
  PERFORM pruebas.como('dueno_a');
  r := public.totales_gastos(e, hoy, hoy);
  PERFORM pruebas.afirmar((r->>'gastado_centavos')::bigint = 3500 AND (r->>'en_espera_centavos')::bigint = 700 AND (r->>'aplicados')::int = 3
    AND (r->>'gastado_centavos')::bigint = (SELECT sum(monto_centavos) FROM public.v_gasto WHERE estado = 'aplicado' AND fecha_contable = hoy),
    'dueño: 3,500 gastado y 700 en espera: ' || r::text);
  r := public.totales_gastos(e, hoy, hoy, pruebas.id('CAT_PAPEL'), pruebas.id('CAJA2'));
  PERFORM pruebas.afirmar((r->>'gastado_centavos')::bigint = 1000 AND (r->>'en_espera_centavos')::bigint = 700, 'filtro por categoría y caja');

  -- =========== Devolución y lo más vendido ===========
  -- El dueño devuelve 1 tornillo de V2 (Norte) en dinero: 1,500.
  r := public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'Venía dañado', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA2')), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicada' AND (r->>'total_centavos')::bigint = 1500, 'devolución aplicada 1,500');
  -- Dueño: tornillos vendidos 2+4+2+1 = 9 (13,500), devuelto 1 (1,500), neto 8 (12,000); mano de obra 23,000. Neto 35,000.
  r := public.mas_vendido(e, hoy - 2, hoy, 1000);
  SELECT x INTO f FROM jsonb_array_elements(r->'filas') x WHERE (x->>'producto_id')::uuid = pruebas.id('P1');
  PERFORM pruebas.afirmar((f->>'cantidad_vendida')::numeric = 9 AND (f->>'total_vendido_centavos')::bigint = 13500 AND (f->>'cantidad_devuelta')::numeric = 1
    AND (f->>'total_neto_centavos')::bigint = 12000 AND (f->>'cantidad_neta')::numeric = 8, 'dueño: tornillo ' || f::text);
  PERFORM pruebas.afirmar((r->'total'->>'total_neto_centavos')::bigint = 35000 AND (r->'filas'->0->>'producto_id')::uuid = pruebas.id('S1')
    AND (r->'total'->>'total_neto_centavos')::bigint = (SELECT sum((x->>'total_neto_centavos')::bigint) FROM jsonb_array_elements(r->'filas') x)
    AND (r->'total'->>'total_vendido_centavos')::bigint = (SELECT sum(total_centavos) FROM public.v_venta_linea WHERE estado = 'emitida' AND fecha_contable BETWEEN hoy - 2 AND hoy),
    'dueño: total 35,000 = suma de filas = v_venta_linea: ' || (r->'total')::text);
  r2 := public.mas_vendido(e, hoy - 2, hoy, 1);
  PERFORM pruebas.afirmar(jsonb_array_length(r2->'filas') = 1 AND (r2->>'hay_mas')::boolean AND r2->'total' = r->'total', 'límite 1: el total sigue siendo de todos');
  -- Admin de la Norte: tornillos 4+1 = 5 (7,500), devuelto 1, neto 6,000; mano de obra 23,000.
  PERFORM pruebas.como('admin_a');
  r := public.mas_vendido(e, hoy - 2, hoy);
  SELECT x INTO f FROM jsonb_array_elements(r->'filas') x WHERE (x->>'producto_id')::uuid = pruebas.id('P1');
  PERFORM pruebas.afirmar((f->>'cantidad_vendida')::numeric = 5 AND (f->>'total_neto_centavos')::bigint = 6000
    AND (r->'total'->>'total_neto_centavos')::bigint = 29000 AND (r->>'solo_mis_sucursales')::boolean
    AND (r->'total'->>'total_vendido_centavos')::bigint = (SELECT sum(total_centavos) FROM public.v_venta_linea WHERE estado = 'emitida' AND fecha_contable BETWEEN hoy - 2 AND hoy),
    'admin: solo la Norte (neto 29,000): ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.mas_vendido(%L, %L::date, %L::date)', e, hoy - 400, hoy), 'FECHA_INVALIDA', 'más de un año');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.mas_vendido(%L, %L::date, %L::date)', e, hoy, hoy), 'SIN_PERMISO', 'cajero sin ventas.ver');

  -- =========== v_comision_vendedor ===========
  PERFORM pruebas.como('admin_a');
  SELECT devengado_centavos, por_pagar_centavos INTO n, m FROM public.v_comision_vendedor WHERE vendedor_id = pruebas.usuario('vendedor_a');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(n = (SELECT sum(cm.monto_centavos) FROM public.comision_movimiento cm JOIN public.venta v ON v.id = cm.venta_id WHERE v.sucursal_id = s2)
    AND n = m AND n < (SELECT sum(monto_centavos) FROM public.comision_movimiento), 'admin: solo comisiones de ventas de la Norte: ' || n);
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT devengado_centavos FROM public.v_comision_vendedor WHERE vendedor_id = pruebas.usuario('vendedor_a'))
    = (SELECT sum(monto_centavos) FROM public.comision_movimiento), 'dueño: todas las comisiones');
  PERFORM public.pagar_comisiones(e, jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a'), 'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  t := (SELECT string_agg(x::text, ',') FROM (SELECT u.vendedor_id,
          coalesce((SELECT sum(cm.monto_centavos) FROM public.comision_movimiento cm WHERE cm.empresa_id = u.empresa_id AND cm.vendedor_id = u.vendedor_id), 0),
          coalesce((SELECT sum(l.monto_centavos) FROM public.comision_liquidacion l WHERE l.empresa_id = u.empresa_id AND l.vendedor_id = u.vendedor_id AND l.anulada_en IS NULL), 0)
          FROM (SELECT DISTINCT empresa_id, vendedor_id FROM public.comision_movimiento) u ORDER BY 1) x);   -- la cuenta de 036
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(t = (SELECT string_agg(x::text, ',') FROM (SELECT vendedor_id, devengado_centavos, pagado_centavos FROM public.v_comision_vendedor ORDER BY 1) x),
    'dueño: igual que la vista de antes: ' || t);
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((SELECT pagado_centavos = devengado_centavos AND por_pagar_centavos = 0 FROM public.v_comision_vendedor
                            WHERE vendedor_id = pruebas.usuario('vendedor_a')), 'admin: lo de la Norte quedó pagado');

  -- =========== ¿Dónde está mi dinero? ===========
  r := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = (SELECT sum(interno.saldo_dinero(d.id)) FROM public.cuenta_dinero d
                                                             WHERE d.empresa_id = e AND (d.sucursal_id IS NULL OR d.sucursal_id = s2))
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'cuentas') x JOIN public.cuenta_dinero d ON d.id = (x->>'cuenta_dinero_id')::uuid WHERE d.sucursal_id = s1)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'cuentas') x WHERE (x->>'cuenta_dinero_id')::uuid = pruebas.id('CAJA2'))
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'cuentas') x WHERE (x->>'cuenta_dinero_id')::uuid = pruebas.id('BANCO'))
    AND jsonb_array_length(r->'otras_cuentas_efectivo_sin_rastro') = 0 AND (r->>'solo_mis_sucursales')::boolean, 'admin: su caja, su banco y los de toda la empresa; nada de la principal');
  PERFORM pruebas.como('dueno_a');
  r := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = (SELECT sum(interno.saldo_dinero(d.id)) FROM public.cuenta_dinero d WHERE d.empresa_id = e)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'cuentas') x WHERE (x->>'cuenta_dinero_id')::uuid = pruebas.id('CAJA1'))
    AND NOT r ? 'solo_mis_sucursales', 'dueño: todo, sin clave nueva');

  -- =========== Fondos ===========
  PERFORM pruebas.como('dueno_a');
  PERFORM public.crear_fondo(e, jsonb_build_object('nombre', 'Reserva', 'tipo', 'reinversion', 'cuenta_dinero_id', pruebas.id('BANCO_P')), 'Fondo en el banco de la principal');
  r := public.estado_fondos(e);
  PERFORM pruebas.afirmar((r->'fondos'->0->>'saldo_cuenta_dinero_centavos')::bigint = 0 AND NOT r ? 'solo_mis_sucursales', 'dueño ve el saldo de la cuenta del fondo');
  PERFORM pruebas.como('admin_a');
  r := public.estado_fondos(e);
  PERFORM pruebas.afirmar(r->'fondos'->0->'saldo_cuenta_dinero_centavos' = 'null'::jsonb AND r->'fondos'->0->>'nombre' = 'Reserva'
    AND (r->>'solo_mis_sucursales')::boolean, 'admin: el fondo sí, el saldo de la cuenta de otra sucursal no');

  -- =========== Proyección de flujo ===========
  -- Cobros: V3 (Norte) 4,000 y V4 (principal) 2,000, al crédito a 30 días. Pagos: F-N-1 10,000 (Norte, vence hoy), F-INI-1 y SI-1 (principal / empresa).
  r := public.proyeccion_flujo(e, 30);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->>'disponible_hoy_centavos')::bigint = (SELECT sum(interno.saldo_dinero(d.id)) FROM public.cuenta_dinero d WHERE d.empresa_id = e
                             AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica') AND (d.sucursal_id IS NULL OR d.sucursal_id = s2))
    AND (SELECT sum((x->>'monto')::bigint) FROM jsonb_array_elements(r->'detalle') x WHERE x->>'tipo' = 'cobro') = 4000
    AND (SELECT sum((x->>'monto')::bigint) FROM jsonb_array_elements(r->'detalle') x WHERE x->>'tipo' = 'pago_proveedor') = -10000
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'detalle') x WHERE x->>'tipo' IN ('comisiones', 'dividendos'))
    AND (r->>'solo_mis_sucursales')::boolean AND r->'ocultos' @> '["comisiones"]', 'admin: proyección de la Norte: ' || (r->'detalle')::text);
  PERFORM pruebas.como('dueno_a');
  r := public.proyeccion_flujo(e, 30);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((r->>'disponible_hoy_centavos')::bigint = (SELECT sum(interno.saldo_dinero(d.id)) FROM public.cuenta_dinero d WHERE d.empresa_id = e
                             AND d.tipo IN ('efectivo_caja', 'banco', 'caja_chica'))
    AND (SELECT sum((x->>'monto')::bigint) FROM jsonb_array_elements(r->'detalle') x WHERE x->>'tipo' = 'cobro') = 6000
    AND (SELECT sum((x->>'monto')::bigint) FROM jsonb_array_elements(r->'detalle') x WHERE x->>'tipo' = 'pago_proveedor') = -594000
    AND NOT r ? 'solo_mis_sucursales', 'dueño: toda la empresa');

  -- =========== Conciliación ===========
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.guardar('CONC_P', (public.importar_estado_cuenta(e, pruebas.id('BANCO_P'), extract(year FROM hoy)::int, extract(month FROM hoy)::int,
    jsonb_build_object('filas', jsonb_build_array(jsonb_build_object('fecha', hoy, 'descripcion', 'INTERESES', 'monto_centavos', 100))),
    gen_random_uuid())->>'conciliacion_id')::uuid);
  PERFORM pruebas.como('admin_a');
  PERFORM public.importar_estado_cuenta(e, pruebas.id('BANCO_N'), extract(year FROM hoy)::int, extract(month FROM hoy)::int,
    jsonb_build_object('filas', jsonb_build_array(jsonb_build_object('fecha', hoy, 'descripcion', 'COMISION', 'monto_centavos', -200))), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_conciliacion) = 1 AND (SELECT cuenta_dinero_id FROM public.v_conciliacion) = pruebas.id('BANCO_N')
    AND (SELECT count(*) FROM public.conciliacion) = 1 AND (SELECT count(*) FROM public.banco_movimiento) = 1
    AND (SELECT count(*) FROM public.banco_importacion) = 1, 'admin: solo la conciliación de su banco');
  PERFORM pruebas.debe_fallar(format('SELECT public.ver_conciliacion(%L)', pruebas.id('CONC_P')), 'SUCURSAL_NO_PERMITIDA', 'ver la conciliación de otra sucursal');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_conciliacion) = 2 AND (SELECT count(*) FROM public.banco_movimiento) = 2, 'dueño: las dos');
  PERFORM public.ver_conciliacion(pruebas.id('CONC_P'));

  -- =========== Preferencias de alertas ===========
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_preferencias_alertas(%L, %L)', e, '{"cuenta_negativa": false}'), 'SIN_PERMISO', 'cajero: tipo que no ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_preferencias_alertas(%L, %L)', e, '{"stock_minimo": false, "aprobaciones": false}'), 'SIN_PERMISO', 'nada se guarda a medias');
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_preferencias_alertas(%L, %L)', e, '{"no_existe": false}'), 'DATO_INVALIDO', 'tipo inventado');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.alerta_preferencia WHERE user_id = pruebas.usuario('cajero_a')), 'nada guardado');
  r := public.guardar_preferencias_alertas(e, '{"stock_minimo": false}');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'tipo' = 'stock_minimo' AND NOT (x->>'recibir')::boolean), 'cajero: el suyo sí');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.guardar_preferencias_alertas(e, '{"cuenta_negativa": false}');

  -- =========== Lado de clientes ===========
  -- Cobro del cajero con excedente: recibe 4,500; V3 debe 4,000 -> 500 quedan a favor de CLI1 (lote de la Norte).
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', c2, 'excedente', 'saldo_favor',
         'pagos', '[{"forma":"efectivo","monto_centavos":4500}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'aplicado_centavos')::bigint = 4000 AND (r->>'excedente_centavos')::bigint = 500
    AND jsonb_array_length(r->'aplicaciones') = 1 AND (r->'aplicaciones'->0->>'venta_id')::uuid = (v3->>'venta_id')::uuid
    AND (r->'saldo_favor'->>'monto_centavos')::bigint = 500, 'excedente a favor: ' || r::text);
  PERFORM pruebas.guardar('SF_NORTE', (r->'saldo_favor'->>'saldo_favor_id')::uuid);
  -- Dueño: anticipo de CLI2 en la principal (1,000), saldo inicial de CLI2 (2,000), V6 al crédito en la Norte a CLI1 (3,000)
  -- y V7 de contado en la Norte a CLI2 (2 tornillos = 3,000).
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'tipo', 'anticipo', 'caja_id', pruebas.id('CAJA001'),
         'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.guardar('SF_PRINCIPAL', (r->'saldo_favor'->>'saldo_favor_id')::uuid);
  PERFORM pruebas.guardar('SIC', (public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-OLD-9',
    'fecha_documento', '2025-12-01', 'monto_centavos', 2000), gen_random_uuid())->>'saldo_inicial_id')::uuid);
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'caja_id', pruebas.id('CAJA001'),
    'pagos', '[{"forma":"efectivo","monto_centavos":500}]'::jsonb), gen_random_uuid());   -- abono al saldo inicial
  PERFORM public.condonar_saldo_cxc(e, jsonb_build_object('venta_id', v4->>'venta_id', 'monto_centavos', 100), 'Redondeo del cliente', gen_random_uuid());
  PERFORM pruebas.guardar('V6', (public.registrar_venta(e, pruebas.venta('P1', 2, 'credito', 'CLI1') || jsonb_build_object('caja_id', c2), gen_random_uuid())->>'venta_id')::uuid);
  PERFORM pruebas.guardar('V7', (public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo', 'CLI2') || jsonb_build_object('caja_id', c2), gen_random_uuid())->>'venta_id')::uuid);
  -- El cajero paga 500 de V6 con el saldo a favor (función del núcleo: la RLS no la frena).
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'caja_id', c2,
         'pagos', '[{"forma":"saldo_favor","monto_centavos":500}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'aplicado_centavos')::bigint = 500 AND (r->'aplicaciones'->0->>'venta_id')::uuid = pruebas.id('V6')
    AND (r->'aplicaciones'->0->>'saldo_restante_centavos')::bigint = 2500, 'cobro con saldo a favor: ' || r::text);
  -- El admin de la Norte devuelve 1 tornillo de V7 a saldo a favor de CLI2 (lote de la Norte).
  PERFORM pruebas.como('admin_a');
  r := public.registrar_devolucion(pruebas.id('V7'), jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
         'motivo', 'No era la medida', 'destino', 'saldo_favor'), gen_random_uuid());
  IF r->>'estado' = 'pendiente_aprobacion' THEN
    PERFORM pruebas.como('dueno_a');
    r := public.resolver_aprobacion((r->>'aprobacion_id')::uuid, true, 'Devolución correcta', gen_random_uuid());
    PERFORM pruebas.como('admin_a');
  END IF;
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.saldo_favor WHERE documento_tipo = 'devolucion' AND monto_centavos = 1500),
    'devolución a saldo a favor (y el admin la ve)');
  -- Condonar: solo en su sucursal; un saldo inicial, no.
  PERFORM pruebas.debe_fallar(format('SELECT public.condonar_saldo_cxc(%L, %L::jsonb, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v4->>'venta_id', 'monto_centavos', 100), 'Redondeo ajeno'), 'SUCURSAL_NO_PERMITIDA', 'condonar factura de otra sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.condonar_saldo_cxc(%L, %L::jsonb, %L, gen_random_uuid())', e,
    jsonb_build_object('saldo_inicial_id', pruebas.id('SIC'), 'monto_centavos', 100), 'Redondeo viejo'), 'SUCURSAL_NO_PERMITIDA', 'condonar un saldo inicial');
  r := public.condonar_saldo_cxc(e, jsonb_build_object('venta_id', pruebas.id('V6'), 'monto_centavos', 100), 'Redondeo Norte', gen_random_uuid());
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'condonar en su sucursal sí');
  -- Lo que llega al admin: nada de la principal ni de toda la empresa.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cxc_saldo_inicial) = 0
    AND NOT EXISTS (SELECT 1 FROM public.cxc_aplicacion a LEFT JOIN public.venta v ON v.id = a.venta_id WHERE v.sucursal_id IS DISTINCT FROM s2)
    AND NOT EXISTS (SELECT 1 FROM public.cxc_condonacion c LEFT JOIN public.venta v ON v.id = c.venta_id WHERE v.sucursal_id IS DISTINCT FROM s2)
    AND (SELECT count(*) FROM public.cxc_condonacion) = 1
    AND NOT EXISTS (SELECT 1 FROM public.cobro_pago p JOIN public.cobro c ON c.id = p.cobro_id WHERE c.sucursal_id IS DISTINCT FROM s2)
    AND (SELECT count(*) FROM public.cobro_pago) = (SELECT count(*) FROM public.cobro_pago p WHERE p.cobro_id IN (SELECT id FROM public.cobro))
    AND EXISTS (SELECT 1 FROM public.saldo_favor WHERE id = pruebas.id('SF_NORTE'))
    AND NOT EXISTS (SELECT 1 FROM public.saldo_favor WHERE id = pruebas.id('SF_PRINCIPAL'))
    AND EXISTS (SELECT 1 FROM public.saldo_favor_uso WHERE saldo_favor_id = pruebas.id('SF_NORTE'))
    AND NOT EXISTS (SELECT 1 FROM public.saldo_favor_uso WHERE saldo_favor_id <> ALL (ARRAY(SELECT id FROM public.saldo_favor))),
    'admin: lado de clientes solo de la Norte');
  -- El dueño ve todo (igual que sin RLS).
  PERFORM pruebas.como('dueno_a');
  SELECT string_agg(x.tb || ':' || x.n, ',') INTO t FROM (SELECT 'si' AS tb, count(*) AS n FROM public.cxc_saldo_inicial UNION ALL SELECT 'apl', count(*) FROM public.cxc_aplicacion
    UNION ALL SELECT 'con', count(*) FROM public.cxc_condonacion UNION ALL SELECT 'pag', count(*) FROM public.cobro_pago
    UNION ALL SELECT 'sf', count(*) FROM public.saldo_favor UNION ALL SELECT 'uso', count(*) FROM public.saldo_favor_uso
    UNION ALL SELECT 'ppa', count(*) FROM public.pago_proveedor UNION ALL SELECT 'cl', count(*) FROM public.compra_linea UNION ALL SELECT 'bm', count(*) FROM public.banco_movimiento) x;
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(t = (SELECT string_agg(x.tb || ':' || x.n, ',') FROM (SELECT 'si' AS tb, count(*) AS n FROM public.cxc_saldo_inicial UNION ALL SELECT 'apl', count(*) FROM public.cxc_aplicacion
    UNION ALL SELECT 'con', count(*) FROM public.cxc_condonacion UNION ALL SELECT 'pag', count(*) FROM public.cobro_pago
    UNION ALL SELECT 'sf', count(*) FROM public.saldo_favor UNION ALL SELECT 'uso', count(*) FROM public.saldo_favor_uso
    UNION ALL SELECT 'ppa', count(*) FROM public.pago_proveedor UNION ALL SELECT 'cl', count(*) FROM public.compra_linea UNION ALL SELECT 'bm', count(*) FROM public.banco_movimiento) x),
    'dueño = todo: ' || t);
  -- Contador y proveedor con soporte (sin restricción): ven lo mismo que el dueño en las tablas con reglas nuevas.
  PERFORM pruebas.crear_contador();
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '2 hours', 'Revisar los cobros');
  FOR f IN SELECT to_jsonb(x) FROM (VALUES ('contador'), ('proveedor')) x(quien) LOOP
    PERFORM pruebas.como(f->>'quien');
    SELECT string_agg(x.tb || ':' || x.n, ',') INTO t2 FROM (SELECT 'si' AS tb, count(*) AS n FROM public.cxc_saldo_inicial UNION ALL SELECT 'apl', count(*) FROM public.cxc_aplicacion
      UNION ALL SELECT 'con', count(*) FROM public.cxc_condonacion UNION ALL SELECT 'pag', count(*) FROM public.cobro_pago
      UNION ALL SELECT 'sf', count(*) FROM public.saldo_favor UNION ALL SELECT 'uso', count(*) FROM public.saldo_favor_uso
      UNION ALL SELECT 'ppa', count(*) FROM public.pago_proveedor UNION ALL SELECT 'cl', count(*) FROM public.compra_linea UNION ALL SELECT 'bm', count(*) FROM public.banco_movimiento) x;
    PERFORM pruebas.afirmar(t2 = t, (f->>'quien') || ' no pierde nada: ' || t2 || ' / dueño ' || t);
  END LOOP;

  -- Todo cuadra.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea WHERE empresa_id = e), 'debe = haber');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                            WHERE d.empresa_id = e AND interno.saldo_dinero(d.id) <> pruebas.saldo_libros(e, c.codigo)) = 0, 'dinero = libros');
END $$;
