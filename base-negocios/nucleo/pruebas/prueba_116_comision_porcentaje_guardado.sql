-- PRUEBA: (0.9.2, menor) el porcentaje de comisión queda guardado en la venta al emitirla: si el dueño lo cambia hoy (desde hoy), una venta al crédito de hoy que se cobra después conserva el de su emisión; las ventas nuevas toman el nuevo
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  ven  uuid := pruebas.usuario('vendedor_a');
  v1   jsonb;
  v2   jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de porcentaje guardado');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'comisiones') ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_comisiones(e, '{"activas": true, "base": "precio"}', 'Comisión sobre el precio');
  PERFORM public.fijar_porcentaje_comision(e, ven, 10, NULL, 'Comisión inicial');

  -- V1 hoy al crédito a CLI1 a nombre del vendedor: 1 tornillo = 1,500 (1,304 sin ISV). Todavía no devenga.
  v1 := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI1') || jsonb_build_object('vendedor_id', ven), gen_random_uuid());
  PERFORM pruebas.afirmar(v1->>'estado' = 'emitida', 'V1 emitida');
  -- El mismo día el dueño sube el porcentaje a 20 % (desde hoy).
  PERFORM public.fijar_porcentaje_comision(e, ven, 20, NULL, 'Sube la comisión');
  -- Se cobra V1: devenga con el 10 % de su emisión = round(130.4) = 130 (antes tomaba el 20 %: 261).
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'pagos', '[{"forma":"efectivo","monto_centavos":1500}]'::jsonb),
    gen_random_uuid());
  -- V2 nueva (contado): 20 % = round(260.8) = 261.
  v2 := public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('vendedor_id', ven), gen_random_uuid());

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v1->>'venta_id')::uuid) = 130,
    'V1 al 10 % de su emisión: ' || coalesce((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v1->>'venta_id')::uuid)::text, 'nada'));
  PERFORM pruebas.afirmar((SELECT comision_porcentaje FROM public.venta WHERE id = (v1->>'venta_id')::uuid) = 10
    AND (SELECT comision_porcentaje FROM public.venta WHERE id = (v2->>'venta_id')::uuid) = 20, 'porcentaje guardado en cada venta');
  PERFORM pruebas.afirmar((SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = (v2->>'venta_id')::uuid) = 261, 'V2 al 20 %');
  PERFORM pruebas.afirmar(interno.total_comisiones_por_pagar(e) = 391 AND pruebas.saldo_libros(e, '2.1.03.04') = 391, 'cuadre: 130 + 261 = 391');
END $$;
