-- PRUEBA: comisiones (cifras a mano): módulo propio (necesita ventas) e interruptor del dueño; porcentaje por empleado; base ganancia (precio sin ISV - costo; servicios con costo estimado) o precio sin ISV, nunca ISV; se devengan cuando la venta queda cobrada completa; se ajustan con devoluciones aunque ya se hayan pagado (saldo a descontar) y con anulaciones; pago por período desde una cuenta de dinero con asiento y rastro, y su anulación; el vendedor ve solo lo suyo sin costos; comisiones por pagar = su cuenta
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  ven   uuid := pruebas.usuario('vendedor_a');
  caj   uuid := pruebas.usuario('cajero_a');
  v1 jsonb; v2 jsonb; v3 jsonb; v4 jsonb; v5 jsonb;
  p     jsonb;
  r     jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de comisiones');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_comisiones(%L, %L, %L)', e, '{"activas": true}', 'Encender'), 'MODULO_INACTIVO', 'sin el módulo');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones');

  -- 1) Solo el dueño configura: encendidas, base ganancia; vendedor 10 %, cajero 5 %.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_comisiones(%L, %L, %L)', e, '{"activas": true}', 'Encender'), 'SIN_PERMISO', 'admin no');
  PERFORM pruebas.como('dueno_a');
  r := public.configurar_comisiones(e, '{"activas": true, "base": "ganancia"}', 'Comisiones para el equipo');
  PERFORM pruebas.afirmar((r->>'comisiones_activas')::boolean AND r->>'comision_base' = 'ganancia', 'encendidas');
  PERFORM public.fijar_porcentaje_comision(e, ven, 10, NULL, 'Acuerdo con el vendedor');
  PERFORM public.fijar_porcentaje_comision(e, caj, 5, NULL, 'Acuerdo con el cajero');
  PERFORM pruebas.debe_fallar(format('SELECT public.fijar_porcentaje_comision(%L, %L, 101, NULL, %L)', e, ven, 'Mucho'), 'DATO_INVALIDO', 'porcentaje');

  -- 2) Al crédito: no se devenga hasta cobrarla completa. V1 10 tornillos: base 13,043 - costo 10,000 = 3,043 x 10 % = 304.
  PERFORM pruebas.como('vendedor_a');
  v1 := public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1'), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo","monto_centavos":5000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.comision_movimiento WHERE venta_id = (v1->>'venta_id')::uuid), 'a medio cobrar: nada');
  PERFORM pruebas.como('cajero_a');
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo","monto_centavos":10000}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT monto_centavos || '/' || base_centavos || '/' || tipo FROM public.comision_movimiento WHERE venta_id = (v1->>'venta_id')::uuid)
    = '304/3043/devengo' AND pruebas.saldo_libros(e, '2.1.03.04') = 304 AND pruebas.saldo_libros(e, '6.1.01.04') = 304, 'cobrada completa: 304');

  -- 3) Al contado se devenga al vender. V2 (vendida por el cajero a nombre del vendedor): 2 h de servicio:
  --    base 40,000 - costo estimado 16,000 = 24,000 x 10 % = 2,400. V3 (del cajero): galón 38,136 - 30,000 = 8,136 x 5 % = 407.
  PERFORM pruebas.como('cajero_a');
  v2 := public.registrar_venta(e, pruebas.venta('S1', 2, 'efectivo') || jsonb_build_object('vendedor_id', ven), gen_random_uuid());
  v3 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT monto_centavos FROM public.comision_movimiento WHERE venta_id = (v2->>'venta_id')::uuid) = 2400
    AND (SELECT monto_centavos || '/' || base_centavos FROM public.comision_movimiento WHERE venta_id = (v3->>'venta_id')::uuid) = '407/8136',
    'contado: 2,400 y 407 (nunca sobre ISV)');

  -- 4) Devolución de 1 h de V2: base 20,000 - 8,000 = 12,000 x 10 % = 1,200: ajuste de -1,200.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_devolucion((v2->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Solo una hora',
    'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v2->>'venta_id')::uuid) = 1200
    AND (SELECT monto_centavos FROM public.comision_movimiento WHERE venta_id = (v2->>'venta_id')::uuid AND tipo = 'ajuste') = -1200, 'ajuste -1,200');

  -- 5) Pago del período al vendedor desde el banco: 304 + 2,400 - 1,200 = 1,504.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_comisiones(%L, %L, gen_random_uuid())', e, jsonb_build_object('vendedor_id', ven,
    'cuenta_dinero_id', pruebas.id('BANCO'))), 'SIN_PERMISO', 'el cajero no paga comisiones');
  PERFORM pruebas.como('admin_a');
  p := public.pagar_comisiones(e, jsonb_build_object('vendedor_id', ven, 'cuenta_dinero_id', pruebas.id('BANCO'), 'referencia', 'Cheque 501'), gen_random_uuid());
  PERFORM pruebas.afirmar((p->>'monto_centavos')::bigint = 1504 AND (p->>'movimientos')::int = 3, 'pago 1,504');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_comisiones(%L, %L, gen_random_uuid())', e, jsonb_build_object('vendedor_id', ven,
    'cuenta_dinero_id', pruebas.id('BANCO'))), 'NADA_QUE_PAGAR', 'ya pagado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 1000000 - 1504 AND pruebas.saldo_libros(e, '2.1.03.04') = 407
    AND (SELECT count(*) FROM public.dinero_movimiento WHERE documento_id = (p->>'liquidacion_id')::uuid AND monto_centavos = -1504) = 1,
    'Dr comisiones por pagar / Cr banco, con rastro');

  -- 6) Devolución DESPUÉS de pagar: V1 devuelve 4 tornillos (ya cobrada: el dinero sale de la caja).
  --    Base 13,043 - 5,217 = 7,826; costo 6,000; 1,826 x 10 % = 183: ajuste 183 - 304 = -121, queda a descontar.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":4}]'::jsonb, 'motivo', 'Oxidados',
    'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_comisiones(%L, %L, gen_random_uuid())', e, jsonb_build_object('vendedor_id', ven,
    'cuenta_dinero_id', pruebas.id('BANCO'))), 'NADA_QUE_PAGAR', 'saldo a descontar: -121');
  PERFORM pruebas.afirmar((SELECT por_pagar_centavos FROM public.v_comision_vendedor WHERE vendedor_id = ven) = -121, 'a descontar -121');
  -- V4 (galón a nombre del vendedor): 8,136 x 10 % = 814. Se descuenta: 814 - 121 = 693.
  PERFORM pruebas.como('cajero_a');
  v4 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo') || jsonb_build_object('vendedor_id', ven), gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  p := public.pagar_comisiones(e, jsonb_build_object('vendedor_id', ven, 'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  PERFORM pruebas.afirmar((p->>'monto_centavos')::bigint = 693, 'paga 814 - 121 = 693');
  -- Anular el pago: el dinero vuelve al banco y queda otra vez por pagar.
  r := public.anular_pago_comisiones((p->>'liquidacion_id')::uuid, 'Cheque mal hecho', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT por_pagar_centavos FROM public.v_comision_vendedor WHERE vendedor_id = ven) = 693, 'por pagar 693');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 1000000 - 1504, 'el banco recupera 693');

  -- 7) Base "precio" (sin ISV): V5 del cajero 2 tornillos: 2,609 x 5 % = 130. Anulada: -130.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"base": "precio"}', 'Sobre el precio');
  PERFORM pruebas.como('cajero_a');
  v5 := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT monto_centavos || '/' || base_centavos || '/' || base_tipo FROM public.comision_movimiento
                            WHERE venta_id = (v5->>'venta_id')::uuid) = '130/2609/precio', 'base precio: 130');
  -- Interruptor apagado: ventas nuevas sin comisión; las ya devengadas se ajustan igual.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"activas": false}', 'Pausa de comisiones');
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  r := public.solicitar_anulacion_venta((v5->>'venta_id')::uuid, 'Venta duplicada', gen_random_uuid());
  PERFORM public.resolver_aprobacion((r->>'aprobacion_id')::uuid, true, 'Duplicada', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v5->>'venta_id')::uuid) = 0
    AND (SELECT count(*) FROM public.comision_movimiento WHERE vendedor_id = caj) = 3, 'anulada: -130; apagadas: sin comisión nueva');

  -- 8) Lo que ve cada quien: el vendedor solo lo suyo (monto y %), sin base ni costos; admin todo.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_mis_comisiones) = 5 AND (SELECT sum(monto_centavos) FROM public.v_mis_comisiones) = 2197
    AND (SELECT count(*) FROM public.v_comision) = 0 AND (SELECT count(*) FROM public.comision_movimiento) = 0, 'vendedor: lo suyo');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'v_mis_comisiones'
                                         AND column_name IN ('base_centavos', 'costo_centavos')), 'sin base ni costo');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_mis_comisiones) = 3, 'cajero: lo suyo');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_comision WHERE empresa_id = e) = 8, 'admin: todas');

  -- 9) Módulo apagado: no se paga; anular un pago sí.
  PERFORM pruebas.como('superusuario');
  UPDATE public.modulo_activo SET activo = false WHERE empresa_id = e AND modulo = 'comisiones';
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.pagar_comisiones(%L, %L, gen_random_uuid())', e, jsonb_build_object('vendedor_id', caj,
    'cuenta_dinero_id', pruebas.id('BANCO'))), 'MODULO_INACTIVO', 'pagar con el módulo apagado');

  -- 10) Cuadre: comisiones por pagar = su cuenta; gasto = devengado; dinero = subcuentas.
  --     Devengado: 304 + 2,400 - 1,200 - 121 + 814 + 407 + 130 - 130 = 2,604; pagado 1,504 -> por pagar 1,100 (693 + 407).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = 1100 AND pruebas.saldo_libros(e, '2.1.03.04') = 1100
    AND pruebas.saldo_libros(e, '6.1.01.04') = 2604
    AND NOT EXISTS (SELECT 1 FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                     WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo))
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'cuadre de comisiones');
  PERFORM pruebas.debe_fallar('UPDATE public.comision_movimiento SET monto_centavos = 1', 'PROHIBIDO', 'no se edita');
END $$;
