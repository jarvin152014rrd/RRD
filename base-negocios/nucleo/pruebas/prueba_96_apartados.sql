-- PRUEBA: apartados con anticipo (cifras a mano): requieren cliente y el módulo "apartados"; reservan existencias sin salir del kardex ni reconocer ingreso (otra venta o traslado no las toca: EXISTENCIA_RESERVADA); anticipos como pasivo (2.1.04.01) con rastro; abonos y su anulación; al completar se convierte en factura CAI aplicando los anticipos; vencido ya no reserva; cancelar libera la reserva y el anticipo pasa a saldo a favor o se devuelve según el dueño; anular la venta del apartado deja el anticipo a favor del cliente; con el módulo apagado solo se cancela; cuadre
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  a1   jsonb; a2 jsonb; a3 jsonb; a4 jsonb;
  r    jsonb;
  ab   jsonb;
  v    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de apartados');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, '{}'), 'MODULO_INACTIVO', 'sin el módulo');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (%L, %L)', pruebas.empresa('B'), 'apartados'),
    'MODULO_DEPENDENCIA', 'apartados necesita ventas e inventario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'apartados');

  -- 1) Apartado de 4 galones (45,000 c/u con ISV 18 % = 180,000) con anticipo de 50,000 en efectivo.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, jsonb_build_object(
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 4)),
    'pagos', '[{"forma":"efectivo","monto_centavos":50000}]'::jsonb)), 'CLIENTE_REQUERIDO', 'requiere cliente');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1)),
    'pagos', '[{"forma":"efectivo","monto_centavos":500}]'::jsonb)), 'DATO_INVALIDO', 'solo servicios no se aparta');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 4)))), 'DATO_INVALIDO', 'sin anticipo');
  a1 := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'),
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 4)),
          'pagos', '[{"forma":"efectivo","monto_centavos":50000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar(a1->>'estado' = 'vigente' AND (a1->>'total_centavos')::bigint = 180000 AND (a1->>'anticipos_centavos')::bigint = 50000
    AND (a1->>'saldo_centavos')::bigint = 130000 AND (a1->>'vence_el')::date = public.hoy_local(e) + 30, 'apartado: ' || a1::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.01') = 50000 AND pruebas.dinero('CAJA1') = 50000
    AND pruebas.existencia('B1', 'P3') = 10 AND pruebas.valor('B1', 'P3') = 300000
    AND coalesce(pruebas.saldo_libros(e, '4.1.01.01'), 0) = 0 AND coalesce(pruebas.saldo_libros(e, '2.1.02.01'), 0) = 0,
    'anticipo = pasivo; sin kardex ni ingreso ni ISV');
  PERFORM pruebas.afirmar(interno.reservado(pruebas.id('B1'), pruebas.id('P3')) = 4, 'reserva 4');

  -- 2) La reserva se respeta: de 10 solo 6 están libres.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e, pruebas.venta('P3', 7, 'efectivo')),
    'EXISTENCIA_RESERVADA', 'no se venden 7');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_apartado(%L, %L, gen_random_uuid())', e, jsonb_build_object('cliente_id', pruebas.id('CLI2'),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 7)),
    'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb)), 'EXISTENCIA_INSUFICIENTE', 'no se apartan 7');
  v := public.registrar_venta(e, pruebas.venta('P3', 6, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.afirmar(v->>'numero_documento' = '001-001-01-00000001', 'se venden las 6 libres');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.trasladar_inventario(%L, %L, %L, %L, %L, gen_random_uuid())', e, pruebas.id('B1'), pruebas.id('B2'),
    public.hoy_local(e), jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1))), 'EXISTENCIA_RESERVADA', 'ni se trasladan');

  -- 3) Abonos: 30,000 con tarjeta (anticipos 80,000); no más de lo que falta; un abono se anula con motivo.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.abonar_apartado(%L, %L, gen_random_uuid())', a1->>'apartado_id',
    '{"pagos":[{"forma":"efectivo","monto_centavos":130001}]}'), 'COBRO_EXCEDE_SALDO', 'abono mayor que lo que falta');
  ab := public.abonar_apartado((a1->>'apartado_id')::uuid, '{"pagos":[{"forma":"tarjeta","monto_centavos":30000}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((ab->>'anticipos_centavos')::bigint = 80000 AND (ab->>'saldo_centavos')::bigint = 100000, 'abono');
  PERFORM pruebas.como('admin_a');
  PERFORM public.anular_cobro((ab->>'cobro_id')::uuid, 'Voucher rechazado', gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  ab := public.abonar_apartado((a1->>'apartado_id')::uuid, '{"pagos":[{"forma":"efectivo","monto_centavos":30000}]}', gen_random_uuid());
  PERFORM pruebas.afirmar((ab->>'anticipos_centavos')::bigint = 80000, 'otra vez 80,000');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.01') = 80000, 'anticipos 80,000');

  -- 4) Completar: lo que falta (100,000) en efectivo; factura CAI con los anticipos aplicados.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.completar_apartado(%L, %L, gen_random_uuid())', a1->>'apartado_id',
    '{"pagos":[{"forma":"efectivo","monto_centavos":90000}]}'), 'PAGO_NO_CUADRA', 'falta pagar');
  r := public.completar_apartado((a1->>'apartado_id')::uuid, '{"pagos":[{"forma":"efectivo","monto_centavos":100000}]}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'emitida' AND r->>'numero_documento' = '001-001-01-00000002' AND (r->>'total_centavos')::bigint = 180000
    AND (r->>'anticipo_aplicado_centavos')::bigint = 80000 AND (r->>'impuesto_centavos')::bigint = 27458, 'venta del apartado: ' || r::text);
  PERFORM pruebas.como('superusuario');
  -- Ventas: 6 gal (270,000 -> 228,814 + 41,186) y 4 gal (180,000 -> 152,542 + 27,458). Kardex: 10 gal salen a 30,000.
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.04.01') = 0 AND pruebas.dinero('CAJA1') = 50000 + 270000 + 30000 + 100000
    AND pruebas.existencia('B1', 'P3') = 0 AND pruebas.saldo_libros(e, '4.1.01.01') = 228814 + 152542
    AND pruebas.saldo_libros(e, '2.1.02.01') = 41186 + 27458 AND pruebas.saldo_libros(e, '5.1.01.01') = 300000,
    'completado: anticipos aplicados, ingreso e ISV al entregar');
  PERFORM pruebas.afirmar((SELECT estado FROM public.apartado WHERE id = (a1->>'apartado_id')::uuid) = 'completado'
    AND interno.reservado(pruebas.id('B1'), pruebas.id('P3')) = 0, 'ya no reserva');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', ab->>'cobro_id', 'Ya no se puede'),
    'NO_PERMITIDO', 'el anticipo aplicado no se anula');

  -- 5) Cancelar (defecto del dueño: el anticipo queda a favor del cliente).
  PERFORM pruebas.como('cajero_a');
  a2 := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
          'pagos', '[{"forma":"efectivo","monto_centavos":500}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.cancelar_apartado(%L, %L, %L, gen_random_uuid())', a2->>'apartado_id', 'Ya no lo quiere', '{}'),
    'SIN_PERMISO', 'el cajero no cancela');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cancelar_apartado(%L, %L, %L, gen_random_uuid())', a2->>'apartado_id', 'Ya no lo quiere',
    jsonb_build_object('destino', 'devolver', 'cuenta_dinero_id', pruebas.id('CAJA1'))), 'NO_PERMITIDO', 'el dueño eligió saldo a favor');
  r := public.cancelar_apartado((a2->>'apartado_id')::uuid, 'Ya no lo quiere', '{}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'cancelado' AND r->>'destino_anticipo' = 'saldo_favor' AND (r->>'anticipo_devuelto_centavos')::bigint = 500, 'cancelado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 500 AND pruebas.saldo_libros(e, '2.1.04.01') = 0
    AND interno.reservado(pruebas.id('B1'), pruebas.id('P1')) = 0, 'anticipo a saldo a favor; reserva liberada');

  -- 6) El dueño deja elegir: se devuelve el anticipo desde la caja.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"apartado_cancelacion": "elegir"}', 'Que se elija al cancelar');
  PERFORM pruebas.como('cajero_a');
  a3 := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)),
          'pagos', '[{"forma":"efectivo","monto_centavos":700}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cancelar_apartado(%L, %L, %L, gen_random_uuid())', a3->>'apartado_id', 'Ya no lo quiere', '{}'),
    'DATO_INVALIDO', 'hay que elegir');
  r := public.cancelar_apartado((a3->>'apartado_id')::uuid, 'Se fue del país', jsonb_build_object('destino', 'devolver', 'cuenta_dinero_id', pruebas.id('CAJA1')),
         gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(r->>'destino_anticipo' = 'devolver' AND pruebas.dinero('CAJA1') = 450000 + 500 AND pruebas.saldo_libros(e, '2.1.04.01') = 0
    AND (SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = (a3->>'apartado_id')::uuid AND monto_centavos = -700) = 1,
    'devuelto con rastro: 450,000 + 500 + 700 - 700');

  -- 7) Vencido ya no reserva: 10 lb de arroz apartadas del 10 al 15/01; se venden 45 de 50 y al completar no alcanza.
  PERFORM pruebas.como('cajero_a');
  a4 := public.crear_apartado(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-01-10', 'vence_el', '2026-01-15',
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 10)),
          'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((a4->>'vencido')::boolean, 'vencido');
  PERFORM public.registrar_venta(e, pruebas.venta('P2', 45, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.completar_apartado(%L, %L, gen_random_uuid())', a4->>'apartado_id',
    '{"pagos":[{"forma":"efectivo","monto_centavos":21000}]}'), 'EXISTENCIA_INSUFICIENTE', 'vencido: la mercadería ya se vendió');

  -- 8) Anular la venta del apartado: inventario vuelve, el efectivo sale de la caja y el anticipo queda a favor del cliente.
  PERFORM pruebas.como('dueno_a');
  r := public.solicitar_anulacion_venta((SELECT venta_id FROM public.apartado WHERE id = (a1->>'apartado_id')::uuid), 'Factura con datos malos', gen_random_uuid());
  PERFORM public.resolver_aprobacion((r->>'aprobacion_id')::uuid, true, 'Se anula', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI1')) = 80000 AND pruebas.existencia('B1', 'P3') = 4, 'anulada: anticipo a favor');

  -- 9) Con el módulo apagado: crear y abonar no; cancelar sí.
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'apartados';
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.abonar_apartado(%L, %L, gen_random_uuid())', a4->>'apartado_id',
    '{"pagos":[{"forma":"efectivo","monto_centavos":100}]}'), 'MODULO_INACTIVO', 'abonar con el módulo apagado');
  PERFORM pruebas.como('admin_a');
  r := public.cancelar_apartado((a4->>'apartado_id')::uuid, 'Venció y no vino', '{"destino":"saldo_favor"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'cancelado', 'cancelar con el módulo apagado');

  -- 10) Cuadre.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(coalesce(pruebas.saldo_libros(e, '2.1.04.01'), 0) = (SELECT coalesce(sum(interno.anticipos_apartado(id)), 0) FROM public.apartado WHERE empresa_id = e AND estado = 'vigente')
    AND interno.total_saldo_favor(e) = pruebas.saldo_libros(e, '2.1.04.02')
    AND (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01')
    AND (SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = e AND estado = 'emitida') = pruebas.saldo_libros(e, '2.1.02.01')
    AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta x ON x.id = d.cuenta_id
                     WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, x.codigo))
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'cuadre de apartados');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_apartado WHERE empresa_id = e) = 4, 'v_apartado');
  PERFORM pruebas.debe_fallar(format('UPDATE public.apartado SET total_centavos = 1 WHERE id = %L', a1->>'apartado_id'), 'PROHIBIDO', 'no se edita');
END $$;
