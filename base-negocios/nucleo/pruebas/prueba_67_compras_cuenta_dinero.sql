-- PRUEBA: compras y pagos a proveedores con cuenta de dinero (cuenta_dinero_id o el código de su subcuenta): dejan su rastro, no dejan la cuenta en negativo, la anulación devuelve el dinero a la misma cuenta; las llamadas de antes (caja/banco de la plantilla) siguen funcionando igual
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  c1   jsonb; c2 jsonb;
  p1   jsonb; p2 jsonb; p3 jsonb;
  op   uuid := gen_random_uuid();
  tr   uuid;
  m    public.dinero_movimiento;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000; caja fuerte 300,000; Caja 1 0.
  PERFORM pruebas.como('admin_a');

  -- 1) Compra de contado desde el BAC (sin forma de pago: sale del tipo de cuenta).
  --    10 x 1,000 = 10,000 + ISV 1,500 = 11,500. BAC 988,500.
  c1 := public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'C-1', '2026-01-10', 'contado', 'P1', 10, 1000)
          || jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 988500 AND pruebas.dinero_libros('BANCO') = 988500, 'compra de contado desde el BAC');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT forma_pago || '/' || (SELECT codigo FROM public.cuenta WHERE id = cuenta_pago_id) FROM public.compra
                            WHERE id = (c1->>'compra_id')::uuid) = 'banco/1.1.01.06', 'forma y cuenta de pago');
  SELECT * INTO m FROM public.dinero_movimiento WHERE documento_id = (c1->>'compra_id')::uuid;
  PERFORM pruebas.afirmar(m.monto_centavos = -11500 AND m.operacion = 'compra' AND m.referencia = 'Factura C-1'
    AND m.contrapartida = '1.1.03.01 Inventario de mercadería, 1.1.04.01 ISV crédito fiscal', 'rastro de la compra: ' || row_to_json(m)::text);
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'C-9', '2026-01-10', 'contado', 'P1', 1, 1000) || jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'))),
    'SALDO_INSUFICIENTE', 'compra desde una caja vacía');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'C-9', '2026-01-10', 'credito', 'P1', 1, 1000) || jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'))),
    'no lleva cuenta de pago', 'crédito con cuenta de dinero');

  -- 2) Compra al crédito C-2: 20 x 1,000 = 20,000 + 3,000 = 23,000. Pago de 10,000 desde la caja fuerte (290,000).
  c2 := public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'C-2', '2026-01-11', 'credito', 'P1', 20, 1000), gen_random_uuid());
  p1 := public.pagar_proveedor(e, (c2->>'compra_id')::uuid, 10000, '2026-01-12', NULL, op, 'Recibo 5', NULL, pruebas.id('FUERTE'));
  PERFORM pruebas.afirmar((p1->>'saldo_restante_centavos')::bigint = 13000 AND pruebas.dinero('FUERTE') = 290000, 'pago desde la caja fuerte');
  PERFORM pruebas.afirmar((public.pagar_proveedor(e, (c2->>'compra_id')::uuid, 10000, '2026-01-12', NULL, op, 'Recibo 5', NULL, pruebas.id('FUERTE'))->>'duplicado')::boolean
    AND pruebas.dinero('FUERTE') = 290000, 'reintento del pago sin doble rastro');
  -- 3) Llamada de antes con el código de la subcuenta del BAC: también deja rastro (5,000; BAC 983,500).
  p2 := public.pagar_proveedor(e, (c2->>'compra_id')::uuid, 5000, '2026-01-13', 'banco', gen_random_uuid(), 'Transf. 8', '1.1.01.06');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 983500 AND pruebas.dinero_libros('BANCO') = 983500, 'pago con el código de la subcuenta');
  -- 4) Llamada de antes con "caja" (1.1.01.01, sin rastro): igual que en 0.4.0.
  p3 := public.pagar_proveedor(e, (c2->>'compra_id')::uuid, 1000, '2026-01-13', 'caja', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.01') = -1000 AND (p3->>'saldo_restante_centavos')::bigint = 7000, 'pago desde caja general');

  -- 5) No se paga desde tránsito; cuenta de pago contradictoria; sin fondos; módulo inactivo.
  tr := (public.crear_cuenta_dinero(e, '{"tipo":"transito","nombre":"Tránsito BAC"}')->>'cuenta_dinero_id')::uuid;
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, NULL, gen_random_uuid(), NULL, NULL, %L)', e, c2->>'compra_id', '2026-01-13', tr),
    'CUENTA_DINERO_INVALIDA', 'pagar desde tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid(), NULL, %L)', e, c2->>'compra_id', '2026-01-13', 'banco',
    (SELECT c.codigo FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE d.id = tr)), 'CUENTA_DINERO_INVALIDA', 'código de tránsito');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, NULL, gen_random_uuid(), NULL, %L, %L)', e, c2->>'compra_id', '2026-01-13',
    '1.1.01.05', pruebas.id('BANCO')), 'no es la de la cuenta de dinero', 'código y cuenta distintos');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, NULL, gen_random_uuid(), NULL, NULL, %L)', e, c2->>'compra_id', '2026-01-13',
    pruebas.id('CAJA1')), 'SALDO_INSUFICIENTE', 'pagar desde caja vacía');
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'dinero';
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, NULL, gen_random_uuid(), NULL, NULL, %L)', e, c2->>'compra_id', '2026-01-13',
    pruebas.id('BANCO')), 'MODULO_INACTIVO', 'cuenta de dinero sin el módulo');
  -- Sin el módulo, la subcuenta del BAC sigue sin aceptar asientos manuales y lo que la toca deja rastro.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(pruebas.sql_registrar(e, '2026-01-13', pruebas.lineas('6.1.02.10', '1.1.01.06', 100)), 'CUENTA_CONTROLADA', 'manual sin módulo');
  PERFORM pruebas.como('admin_a');
  PERFORM public.pagar_proveedor(e, (c2->>'compra_id')::uuid, 500, '2026-01-13', 'banco', gen_random_uuid(), NULL, '1.1.01.06');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 983000 AND pruebas.dinero_libros('BANCO') = 983000, 'rastro aun sin módulo');
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = true WHERE empresa_id = e AND modulo = 'dinero';

  -- 6) Anular el pago de la caja fuerte: los 10,000 vuelven a ella (300,000).
  PERFORM pruebas.como('admin_a');
  PERFORM public.anular_pago_proveedor((p1->>'pago_id')::uuid, 'Se pagó dos veces', gen_random_uuid(), '2026-01-14');
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 300000 AND pruebas.dinero_libros('FUERTE') = 300000, 'pago anulado: vuelve a la caja fuerte');
  -- 7) Anular la compra de contado: los 11,500 vuelven al BAC (983,000 + 11,500 = 994,500).
  PERFORM public.anular_compra((c1->>'compra_id')::uuid, 'Mercadería devuelta', gen_random_uuid(), '2026-01-14');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 994500 AND pruebas.dinero_libros('BANCO') = 994500, 'compra anulada: vuelve al BAC');

  -- Cuadre: C-2 23,000 - (5,000 + 1,000 + 500) = 16,500 por pagar = 2.1.01.01; rastro = libros.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_cxp(e) = 16500 AND pruebas.saldo_libros(e, '2.1.01.01') = 16500, 'CxP 16,500');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                                       WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)), 'rastro = libros');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
