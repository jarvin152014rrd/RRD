-- PRUEBA: (0.9.1, menor) devolución pendiente que se atasca: pedida sobre una venta al crédito (sin destino: todo rebajaba la deuda) y el cliente paga antes de aprobarla; el error lo dice claro; quien la pidió o quien aprueba le pone destino válido (con motivo y bitácora) y se vuelve a aprobar; ya aplicada no cambia
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  v   jsonb;
  dp  jsonb;
  r   jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de devolución atascada');
  -- Venta al crédito a CLI2: 4 tornillos = 6,000.
  v := public.registrar_venta(e, pruebas.venta('P1', 4, 'credito', 'CLI2'), gen_random_uuid());

  -- El cajero pide devolver 2 (3,000) sin destino (la venta debía todo): queda pendiente (el cajero siempre pide aprobación).
  PERFORM pruebas.como('cajero_a');
  dp := public.registrar_devolucion((v->>'venta_id')::uuid, '{"lineas":[{"linea":1,"cantidad":2}],"motivo":"Vinieron dañados"}', gen_random_uuid());
  PERFORM pruebas.afirmar(dp->>'estado' = 'pendiente_aprobacion', 'pendiente');
  -- Mientras tanto el cliente paga los 6,000.
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo","monto_centavos":6000}]'::jsonb),
    gen_random_uuid());

  -- Aprobar ya no puede rebajar la deuda: el error dice qué hacer.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', dp->>'aprobacion_id', 'Revisado'),
    'definir_destino_devolucion', 'el error dice cómo seguir');

  -- Destino: el vendedor (ni la pidió ni aprueba) no; "cambio" no; sin motivo no.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.definir_destino_devolucion(%L, %L, %L)', dp->>'devolucion_id', '{"destino":"saldo_favor"}', 'El cliente ya pagó'),
    'SIN_PERMISO', 'el vendedor no');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.definir_destino_devolucion(%L, %L, %L)', dp->>'devolucion_id', '{"destino":"cambio"}', 'El cliente ya pagó'),
    'DATO_INVALIDO', 'cambio no queda pendiente');
  PERFORM pruebas.debe_fallar(format('SELECT public.definir_destino_devolucion(%L, %L, %L)', dp->>'devolucion_id', '{"destino":"saldo_favor"}', 'ya'),
    'FALTA_MOTIVO', 'con motivo');
  r := public.definir_destino_devolucion((dp->>'devolucion_id')::uuid, '{"destino":"saldo_favor"}', 'El cliente ya pagó');
  PERFORM pruebas.afirmar(r->>'destino' = 'saldo_favor' AND r->>'estado' = 'pendiente_aprobacion', 'destino puesto');

  -- Se vuelve a aprobar: los 3,000 quedan a favor de CLI2 (nada rebaja la CxC: ya estaba pagada).
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Revisado', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicada' AND (r->>'saldo_favor_centavos')::bigint = 3000 AND (r->>'cxc_centavos')::bigint = 0,
    'aplicada a saldo a favor: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.definir_destino_devolucion(%L, %L, %L)', dp->>'devolucion_id', '{"destino":"saldo_favor"}', 'Otra vez lo mismo'),
    'NO_PERMITIDO', 'ya aplicada no cambia');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(interno.saldo_favor_cliente(e, pruebas.id('CLI2')) = 3000 AND interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01')
    AND interno.total_saldo_favor(e) = pruebas.saldo_libros(e, '2.1.04.02')
    AND (SELECT count(*) FROM public.bitacora WHERE tabla = 'devolucion' AND motivo = 'El cliente ya pagó') = 1, 'cuadre y bitácora');
END $$;
