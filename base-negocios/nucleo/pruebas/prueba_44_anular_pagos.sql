-- PRUEBA: anular un pago a proveedor (contra-asiento a la misma cuenta de dinero, una vez, mes abierto, fecha no anterior); la factura recupera su saldo y, sin pagos vigentes, la compra se anula
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  c1   uuid;
  c2   uuid;
  p1   jsonb; p2 jsonb; p3 jsonb; p4 jsonb;
  op   uuid := gen_random_uuid();
  r    jsonb;
  anul public.asiento;
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.como('dueno_a');
  PERFORM public.crear_subcuenta(e, '1.1.01', '1.1.01.04', 'Banco Atlántida');

  -- Compra al crédito: 100 x 1000 = 100,000 + ISV 15% 15,000 = 115,000.
  PERFORM pruebas.como('admin_a');
  c1 := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-300', '2026-01-10', 'credito', 'P1', 100, 1000), gen_random_uuid())->>'compra_id')::uuid;
  -- Pago 1: 40,000 por caja. Pago 2: 30,000 desde el Banco Atlántida. Queda 45,000.
  p1 := public.pagar_proveedor(e, c1, 40000, '2026-01-15', 'caja', gen_random_uuid(), 'Recibo 1');
  p2 := public.pagar_proveedor(e, c1, 30000, '2026-01-20', 'banco', gen_random_uuid(), 'Transf. 77', '1.1.01.04');
  PERFORM pruebas.afirmar((p2->>'saldo_restante_centavos')::bigint = 45000, 'saldo 45,000 tras dos pagos');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.01.01') = 45000 AND pruebas.saldo_libros(e, '1.1.01.01') = -40000
    AND pruebas.saldo_libros(e, '1.1.01.04') = -30000, 'libros antes de anular');

  -- Validaciones de la anulación.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', p2->>'pago_id', 'Pago equivocado'), 'SIN_PERMISO', 'cajero anula pago');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', p2->>'pago_id', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, NULL)', p2->>'pago_id', 'Pago equivocado'), 'FALTA_ID_OPERACION', 'sin id_operacion');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid(), %L)', p2->>'pago_id', 'Pago equivocado', '2026-01-19'), 'FECHA_INVALIDA', 'fecha antes del pago');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', gen_random_uuid(), 'Pago equivocado'), 'NO_EXISTE', 'pago inventado');

  -- Anular el pago 2 (21/01): vuelve al MISMO banco; la factura recupera 30,000.
  r := public.anular_pago_proveedor((p2->>'pago_id')::uuid, 'Se pagó desde el banco equivocado', op, '2026-01-21');
  PERFORM pruebas.afirmar((r->>'saldo_documento_centavos')::bigint = 75000 AND NOT (r->>'duplicado')::boolean, 'saldo 75,000: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.04') = 0 AND pruebas.saldo_libros(e, '2.1.01.01') = 75000, 'Atlántida 0 y CxP 75,000');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxp_documento WHERE documento_id = c1) = 75000
    AND (SELECT pagado_centavos FROM public.v_cxp_documento WHERE documento_id = c1) = 40000, 'vista: pagado 40,000, saldo 75,000');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO anul FROM public.asiento WHERE id = (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar(anul.origen = 'anulacion_pago_proveedor' AND anul.fecha_contable = '2026-01-21'
    AND anul.anula_asiento_id = (SELECT asiento_id FROM public.pago_proveedor WHERE id = (p2->>'pago_id')::uuid), 'contra-asiento enlazado');
  PERFORM pruebas.afirmar((SELECT string_agg(c.codigo || ':' || l.debe_centavos || '/' || l.haber_centavos, ' ' ORDER BY l.linea)
                             FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id WHERE l.asiento_id = anul.id)
                          = '1.1.01.04:30000/0 2.1.01.01:0/30000', 'líneas del contra-asiento');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'pago_proveedor_anulacion'
    AND motivo = 'Se pagó desde el banco equivocado'), 'anulación en bitácora');
  PERFORM pruebas.debe_fallar(format('UPDATE public.pago_proveedor_anulacion SET motivo = %L', 'otro motivo'), 'PROHIBIDO', 'editar anulación');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.pago_proveedor_anulacion WHERE pago_id = %L', p2->>'pago_id'), 'PROHIBIDO', 'borrar anulación');

  -- Reintento: mismo id_operacion, nada nuevo. Otra vez con otro id: no.
  PERFORM pruebas.como('admin_a');
  r := public.anular_pago_proveedor((p2->>'pago_id')::uuid, 'Se pagó desde el banco equivocado', op, '2026-01-21');
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'reintento de anulación');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid())', p2->>'pago_id', 'Otra vez'), 'YA_ANULADO', 'anular dos veces');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', r->>'asiento_id', 'por fuera'), 'NO_PERMITIDO', 'anular por fuera el contra-asiento');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_asiento(%L, %L)', p1->>'asiento_id', 'por fuera'), 'PROHIBIDO', 'anular por fuera el asiento del pago');

  -- Corrección: se vuelve a pagar bien. Ya no se puede pasar el saldo.
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_proveedor(%L, %L, 75001, %L, %L, gen_random_uuid())', e, c1, '2026-01-22', 'banco'), 'PAGO_EXCEDE_SALDO', 'pagar de más');
  p3 := public.pagar_proveedor(e, c1, 75000, '2026-01-22', 'banco', gen_random_uuid(), 'Cheque 12');
  PERFORM pruebas.afirmar((p3->>'saldo_restante_centavos')::bigint = 0, 'saldada');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.v_cxp_documento WHERE documento_id = c1), 'saldada: sale de la vista');

  -- Con pagos vigentes la compra no se anula; anulando TODOS, sí.
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c1, 'Factura equivocada', '2026-01-23'), 'anule primero esos pagos', 'compra con pagos');
  PERFORM public.anular_pago_proveedor((p1->>'pago_id')::uuid, 'La factura estaba mal hecha', gen_random_uuid(), '2026-01-23');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_compra(%L, %L, gen_random_uuid(), %L)', c1, 'Factura equivocada', '2026-01-23'), 'NO_PERMITIDO', 'aún queda un pago');
  PERFORM public.anular_pago_proveedor((p3->>'pago_id')::uuid, 'La factura estaba mal hecha', gen_random_uuid(), '2026-01-23');
  r := public.anular_compra(c1, 'Factura equivocada', gen_random_uuid(), '2026-01-23');
  PERFORM pruebas.afirmar((r->>'ajuste_costo_centavos')::bigint = 0, 'compra anulada sin ajuste');
  -- Todo de vuelta a cero: caja, bancos, Atlántida, CxP, inventario e ISV.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '1.1.01.01') = 0 AND pruebas.saldo_libros(e, '1.1.01.03') = 0
    AND pruebas.saldo_libros(e, '1.1.01.04') = 0 AND pruebas.saldo_libros(e, '2.1.01.01') = 0
    AND pruebas.saldo_libros(e, '1.1.03.01') = 0 AND pruebas.saldo_libros(e, '1.1.04.01') = 0, 'libros en cero');

  -- Mes cerrado: la anulación no puede ir con fecha de enero; con la de hoy sí.
  c2 := (public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-301', '2026-01-25', 'credito', 'P1', 10, 1000), gen_random_uuid())->>'compra_id')::uuid;
  p4 := public.pagar_proveedor(e, c2, 11500, '2026-01-26', 'caja', gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_periodo(e, 2026, 1);
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_pago_proveedor(%L, %L, gen_random_uuid(), %L)', p4->>'pago_id', 'Pago repetido', '2026-01-27'), 'PERIODO_CERRADO', 'anular en mes cerrado');
  r := public.anular_pago_proveedor((p4->>'pago_id')::uuid, 'Pago repetido', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT fecha_contable FROM public.asiento WHERE id = (r->>'asiento_id')::uuid) = public.hoy_local(e), 'sin fecha: hoy');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cxp_documento WHERE documento_id = c2) = 11500, 'factura de enero vuelve a deber 11,500');

  -- Cuadre final: CxP del módulo = libros; bitácora intacta.
  PERFORM pruebas.afirmar(interno.total_cxp(e) = pruebas.saldo_libros(e, '2.1.01.01') AND interno.total_cxp(e) = 11500, 'CxP = libros = 11,500');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
