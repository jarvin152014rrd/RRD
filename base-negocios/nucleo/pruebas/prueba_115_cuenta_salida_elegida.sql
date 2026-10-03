-- PRUEBA: (0.9.2, menor) negocio de una sola caja ocupada por el turno del cajero: el admin anula un cobro y el dueño aprueba anular una venta sacando el efectivo de la caja fuerte o del banco (p_cuenta_salida_id), con referencia al turno original; sigue prohibido sacarlo del turno de otro cajero (TURNO_AJENO) y hace falta el permiso de anular; el turno del cajero no se toca y todo cuadra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  t1   jsonb;
  v1   jsonb; v2 jsonb;
  c1   jsonb;
  s1   jsonb;
  r    jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(false);   -- turnos obligatorios; una sola caja (001); caja fuerte 300,000; banco 1,000,000
  -- El cajero abre T1 en la única caja y vende V1 (2 tornillos, 3,000) en efectivo; el dueño vende V2 al crédito a CLI2
  -- (3 tornillos, 4,500) y el cajero cobra C1 = 4,500 en efectivo. En T1: 7,500.
  PERFORM pruebas.como('cajero_a');
  t1 := public.abrir_turno(e, pruebas.id('CAJA001'), 0, gen_random_uuid());
  v1 := public.registrar_venta(e, pruebas.venta('P1', 2), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P1', 3, 'credito', 'CLI2') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  PERFORM pruebas.como('cajero_a');
  c1 := public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo","monto_centavos":4500}]'::jsonb),
          gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 7500, 'T1 con 7,500');

  -- 1) Anular C1: el admin no tiene turno (la única caja la ocupa el cajero).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid())', c1->>'cobro_id', 'Cobro duplicado'),
    'TURNO_AJENO', 'sin cuenta elegida: turno de otro cajero');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid(), NULL, %L)', c1->>'cobro_id', 'Cobro duplicado', pruebas.id('CAJA1')),
    'TURNO_AJENO', 'elegir la caja del turno de otro: prohibido');
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.anular_cobro(%L, %L, gen_random_uuid(), NULL, %L)', c1->>'cobro_id', 'Cobro duplicado', pruebas.id('FUERTE')),
    'SIN_PERMISO', 'sin permiso de anular');
  --    Desde la caja fuerte: 300,000 - 4,500 = 295,500, con referencia a T1.
  PERFORM pruebas.como('admin_a');
  r := public.anular_cobro((c1->>'cobro_id')::uuid, 'Cobro duplicado', gen_random_uuid(), NULL, pruebas.id('FUERTE'));
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('FUERTE') = 295500 AND pruebas.dinero('CAJA1') = 7500, 'sale de la caja fuerte; T1 intacto');
  PERFORM pruebas.afirmar((SELECT m.turno_origen_id = (t1->>'turno_id')::uuid AND m.turno_id IS NULL AND m.creado_por = pruebas.usuario('admin_a')
                             FROM public.dinero_movimiento m WHERE m.documento_id = (c1->>'cobro_id')::uuid AND m.operacion = 'anulacion_cobro'),
    'a nombre del admin, con referencia a T1');

  -- 2) Anular V1: lo pide el admin y lo aprueba el dueño (ninguno tiene turno).
  PERFORM pruebas.como('admin_a');
  s1 := public.solicitar_anulacion_venta((v1->>'venta_id')::uuid, 'Precio equivocado', gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid())', s1->>'aprobacion_id', 'Aprobada'),
    'TURNO_AJENO', 'aprobar sin cuenta elegida');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid(), NULL, %L)', s1->>'aprobacion_id', 'Aprobada',
    pruebas.id('CAJA1')), 'TURNO_AJENO', 'aprobar eligiendo el turno de otro');
  --    Desde el banco: 1,000,000 - 3,000 = 997,000.
  r := public.resolver_aprobacion((s1->>'aprobacion_id')::uuid, true, 'Aprobada', gen_random_uuid(), NULL, pruebas.id('BANCO'));
  PERFORM pruebas.afirmar(r->>'estado' = 'anulada', 'venta anulada: ' || r::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 997000 AND pruebas.dinero('CAJA1') = 7500, 'sale del banco; T1 intacto');

  -- 3) La cuenta de salida solo va al aprobar la anulación de una venta.
  PERFORM pruebas.como('cajero_a');
  r := public.registrar_venta(e, pruebas.venta('P1', 1, 'credito', 'CLI2'), gen_random_uuid());   -- CLI2 sin límite: pide aprobación
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_aprobacion(%L, true, %L, gen_random_uuid(), NULL, %L)', r->>'aprobacion_id', 'Crédito ok',
    pruebas.id('BANCO')), 'DATO_INVALIDO', 'cuenta de salida en otra aprobación');

  -- Cuadre: dinero = libros; el cajero cierra T1 con sus 7,500 sin diferencia.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.afirmar((public.cerrar_turno((t1->>'turno_id')::uuid, 7500, gen_random_uuid())->>'diferencia_centavos')::bigint = 0, 'T1 sin diferencia');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.cuenta_dinero x JOIN public.cuenta k ON k.id = x.cuenta_id
                                       WHERE x.empresa_id = e AND interno.saldo_dinero(x.id) <> pruebas.saldo_libros(e, k.codigo))
    AND interno.total_cxc(e) = pruebas.saldo_libros(e, '1.1.02.01'), 'cuadre');
END $$;
