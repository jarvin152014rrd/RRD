-- PRUEBA: (0.9.2, menor) al cambiar el destino de una devolución pendiente, la solicitud de aprobación muestra el destino actual y, con doble aprobación, la primera aprobación (que era para el destino anterior) se reinicia: hay que aprobar otra vez; sin cambio real no se toca nada
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  v   jsonb;
  dp  jsonb;
  r   jsonb;
  ap  public.aprobacion;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false, "doble_aprobacion": true}', 'Prueba de destino en la aprobación');
  -- Venta de contado: 4 tornillos = 6,000 en efectivo (Caja 1).
  v := public.registrar_venta(e, pruebas.venta('P1', 4), gen_random_uuid());

  -- El cajero pide devolver 2 (3,000) en dinero de la Caja 1: queda pendiente (doble aprobación).
  PERFORM pruebas.como('cajero_a');
  dp := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":2}]'::jsonb,
          'motivo', 'Vinieron dañados', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
  PERFORM pruebas.afirmar(dp->>'estado' = 'pendiente_aprobacion', 'pendiente');
  -- Primera aprobación (admin), para devolver DINERO.
  PERFORM pruebas.como('admin_a');
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Revisado: dinero', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'falta_segunda_aprobacion')::boolean, 'falta la segunda');

  -- El mismo destino otra vez: no cambia nada (la primera aprobación sigue).
  PERFORM pruebas.como('cajero_a');
  r := public.definir_destino_devolucion((dp->>'devolucion_id')::uuid, jsonb_build_object('destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')),
         'Confirmo el destino');
  PERFORM pruebas.afirmar(NOT coalesce((r->>'aprobacion_reiniciada')::boolean, false), 'sin cambio real no se reinicia');

  -- El cliente prefiere saldo a favor: el cajero cambia el destino.
  r := public.definir_destino_devolucion((dp->>'devolucion_id')::uuid, '{"destino":"saldo_favor"}', 'El cliente prefiere saldo');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO ap FROM public.aprobacion WHERE id = (dp->>'aprobacion_id')::uuid;
  PERFORM pruebas.afirmar(ap.descripcion LIKE '%Destino: saldo a favor del cliente (nota de crédito) (cambiado: El cliente prefiere saldo)',
    'quien aprueba ve el destino actual: ' || ap.descripcion);
  PERFORM pruebas.afirmar(ap.estado = 'pendiente' AND ap.primera_aprobacion_por IS NULL AND (r->>'aprobacion_reiniciada')::boolean,
    'la primera aprobación (para dinero) se reinició');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'aprobacion' AND motivo = 'El cliente prefiere saldo') = 1,
    'el cambio queda en la bitácora');

  -- Hay que aprobar otra vez: el admin da la primera y el dueño la segunda. 3,000 a favor del cliente (sin cliente: vale).
  PERFORM pruebas.como('admin_a');
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Revisado: saldo a favor', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'falta_segunda_aprobacion')::boolean AND r->>'estado' = 'pendiente_aprobacion', 'primera otra vez: ' || r::text);
  PERFORM pruebas.como('dueno_a');
  r := public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Conforme', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'estado' = 'aplicada' AND (r->>'saldo_favor_centavos')::bigint = 3000 AND (r->>'dinero_centavos')::bigint = 0,
    'aplicada a saldo a favor: ' || r::text);

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 6000 AND interno.total_saldo_favor(e) = pruebas.saldo_libros(e, '2.1.04.02')
    AND interno.total_saldo_favor(e) = 3000 AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'cuadre');
END $$;
