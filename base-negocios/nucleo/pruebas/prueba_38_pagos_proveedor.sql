-- PRUEBA: pagos a proveedores (abonos a CxP) con su asiento y la cuenta de la que sale el dinero; nunca más que el saldo; reintentos; una compra con pagos no se anula
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  c1  uuid;
  c2  uuid;
  op  uuid := gen_random_uuid();
  r   jsonb;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('admin_a');
  -- Compra al crédito: 100 x 1000 = 100,000 + ISV 15,000 = 115,000.
  c1 := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-200', '2026-01-10', 'credito', 'P1', 100, 1000), gen_random_uuid())->>'compra_id')::uuid;
  c2 := (public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'F-201', '2026-01-10', 'contado', 'P1', 1, 1000, 'caja'), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 115000, 'CxP 115000');

  -- Cajero y vendedor no pagan.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c1, '2026-01-15', 'caja'), 'SIN_PERMISO', 'cajero paga');

  -- Abono de 40,000 por caja: queda 75,000.
  PERFORM pruebas.como('admin_a');
  r := public.pagar_proveedor(e, c1, 40000, '2026-01-15', 'caja', op, 'Recibo 55');
  PERFORM pruebas.afirmar((r->>'saldo_restante_centavos')::bigint = 75000 AND (r->>'numero')::bigint = 1, 'abono 1');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 75000, 'CxP 75000');
  -- Caja: -1,150 (contado) - 40,000 = -41,150.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.01') = -41150, 'caja -41150');
  -- Reintento: no se paga dos veces.
  r := public.pagar_proveedor(e, c1, 40000, '2026-01-15', 'caja', op, 'Recibo 55');
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'reintento');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 75000, 'sigue 75000');

  -- Más que el saldo: no.
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 75001, %L, %L, gen_random_uuid())', e, c1, '2026-01-16', 'banco'), 'PAGO_EXCEDE_SALDO', 'pagar de más');
  -- Datos malos.
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 0, %L, %L, gen_random_uuid())', e, c1, '2026-01-16', 'banco'), 'DATO_INVALIDO', 'monto cero');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, -5, %L, %L, gen_random_uuid())', e, c1, '2026-01-16', 'banco'), 'DATO_INVALIDO', 'monto negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c1, '2026-01-16', 'tarjeta'), 'DATO_INVALIDO', 'forma de pago rara');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c1, '2026-01-05', 'banco'), 'FECHA_INVALIDA', 'pago antes de la compra');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid())', e, c2, '2026-01-16', 'banco'), 'NO_PERMITIDO', 'pagar compra de contado');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, NULL)', e, c1, '2026-01-16', 'banco'), 'FALTA_ID_OPERACION', 'sin id_operacion');

  -- Una compra con pagos no se anula.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c1, 'Factura equivocada', '2026-01-16'), 'NO_PERMITIDO', 'anular con pagos');

  -- Se termina de pagar por banco: saldo 0; ya no se puede pagar más.
  r := public.pagar_proveedor(e, c1, 75000, '2026-01-20', 'banco', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'saldo_restante_centavos')::bigint = 0, 'saldada');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 1, %L, %L, gen_random_uuid())', e, c1, '2026-01-21', 'banco'), 'PAGO_EXCEDE_SALDO', 'pagar saldada');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 0 AND pruebas.saldo_libros(e, '1.1.01.03') = -75000, 'CxP 0, banco -75000');

  -- De qué banco sale: subcuenta propia (el dueño la crea). Compra de contado
  -- y su anulación vuelven a la MISMA cuenta.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.crear_subcuenta(e, '1.1.01', '1.1.01.04', 'Banco Atlántida');
  c2 := (public.registrar_compra(e, pruebas.compra('PROV2', 'B1', 'F-ATL', '2026-01-21', 'contado', 'P1', 2, 1000, 'banco')
         || '{"cuenta_pago": "1.1.01.04"}', gen_random_uuid())->>'compra_id')::uuid;
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.04') = -2300 AND pruebas.saldo_libros(e, '1.1.01.03') = -75000, 'sale del Atlántida, no de Bancos');
  PERFORM public.anular_compra(c2, 'Pagada con el banco equivocado', gen_random_uuid(), '2026-01-21');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.04') = 0, 'la anulación devuelve al Atlántida');
  c2 := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-ATL2', '2026-01-21', 'credito', 'P1', 2, 1000), gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.pagar_proveedor(e, c2, 1000, '2026-01-22', 'banco', gen_random_uuid(), 'Transf. 9988', '1.1.01.04');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.04') = -1000, 'abono desde el Atlántida');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid(), NULL, %L)', e, c2, '2026-01-22', 'banco', '4.1.01.01'), 'CUENTA_INVALIDA', 'pagar desde una cuenta que no es de dinero');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 100, %L, %L, gen_random_uuid(), NULL, %L)', e, c2, '2026-01-22', 'banco', '1.1.01'), 'CUENTA_INVALIDA', 'cuenta de agrupación');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_compra(%L, %L, gen_random_uuid())', e,
    pruebas.compra('PROV1', 'B1', 'F-X', '2026-01-22', 'credito', 'P1', 1, 100) || '{"cuenta_pago": "1.1.01.04"}'), 'DATO_INVALIDO', 'crédito con cuenta de pago');

  -- Asiento del pago y su bitácora; el asiento no se anula por fuera.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.pago_proveedor p JOIN public.asiento_linea l ON l.asiento_id = p.asiento_id
                             JOIN public.cuenta c ON c.id = l.cuenta_id WHERE p.id_operacion = op)
                          = '2.1.01.01:40000/0 1.1.01.01:0/40000', 'asiento del pago');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'pago_proveedor' AND empresa_id = e) = 3, 'pagos en bitácora');
  PERFORM pruebas.debe_fallar('UPDATE public.pago_proveedor SET monto_centavos = 1', 'PROHIBIDO', 'editar pago');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento((SELECT asiento_id FROM public.pago_proveedor WHERE id_operacion = %L), %L)', op, 'anular por fuera'),
                              'PROHIBIDO', 'anular asiento de pago');
END $$;
