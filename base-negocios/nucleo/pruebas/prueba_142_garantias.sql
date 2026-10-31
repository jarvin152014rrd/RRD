-- PRUEBA: (0.18.0) garantías: días por producto; cada línea vendida guarda sus días y, al emitirse, "garantía hasta" = fecha de la venta + días (una venta pendiente de aprobación la fija al aprobarse); el comprobante lo dice; buscar por factura, cliente o producto con "vigente"; reclamo con motivo sobre una línea vigente (estado recibido -> en revisión -> resuelto o rechazado, historial, bitácora, id_operacion y doble envío); línea sin garantía o cantidad de más se rechazan; garantía vencida se rechaza salvo que alguien con garantias.resolver la autorice con motivo; permisos (registrar: cajero y vendedor; resolver y rechazar: admin y dueño; otra empresa no ve nada); resolver "reparado" con costo de reparación como gasto, "cambiado" con el cambio de producto de siempre y "devuelto" con la devolución de dinero de siempre, ligadas al reclamo; un reclamo cerrado no cambia; comprobante del reclamo; asientos cuadran y bitácora íntegra
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb;
  v2   jsonb;
  vv   jsonb;
  vp   jsonb;
  r    jsonb;
  r2   jsonb;
  op   uuid := gen_random_uuid();
  rec  uuid;
  hoy  date;
  n    bigint;
  inv0 numeric;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba sin turnos');
  hoy := public.hoy_local(e);

  -- ===== 1) Días de garantía del producto =====
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P3'), '{"dias_garantia": 90}'),
    'SIN_PERMISO', 'el vendedor no edita productos');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_producto(%L, %L, %L)', e, pruebas.id('P3'), '{"dias_garantia": 0}'),
    'DATO_INVALIDO', 'cero días');
  PERFORM public.editar_producto(e, pruebas.id('P3'), '{"dias_garantia": 90}');
  PERFORM pruebas.afirmar((SELECT dias_garantia FROM public.v_producto WHERE producto_id = pruebas.id('P3')) = 90, 'v_producto con la garantía');

  -- Una venta vieja (10/01) con garantía de 90 días: venció el 10/04.
  PERFORM pruebas.como('dueno_a');
  vv := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo', 'CLI2') || '{"fecha": "2026-01-10"}', gen_random_uuid());
  -- Venta de hoy: galón (90 días) y tornillos (sin garantía).
  v1 := public.registrar_venta(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'pagos', '[{"forma":"efectivo"}]'::jsonb,
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1),
                                      jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT garantia_dias = 90 AND garantia_hasta = hoy + 90 FROM public.venta_linea WHERE venta_id = (v1->>'venta_id')::uuid AND linea = 1)
    AND (SELECT garantia_dias IS NULL AND garantia_hasta IS NULL FROM public.venta_linea WHERE venta_id = (v1->>'venta_id')::uuid AND linea = 2),
    'garantía de las líneas');
  PERFORM pruebas.afirmar((SELECT garantia_hasta FROM public.venta_linea WHERE venta_id = (vv->>'venta_id')::uuid) = '2026-04-10', 'venta vieja: hasta 10/04');
  PERFORM pruebas.como('dueno_a');
  r := public.documento_venta((v1->>'venta_id')::uuid);
  PERFORM pruebas.afirmar(r->'lineas'->0->>'garantia_texto' = 'Garantía hasta ' || to_char(hoy + 90, 'DD/MM/YYYY') AND NOT (r->'lineas'->1 ? 'garantia_hasta'),
    'comprobante: ' || (r->'lineas')::text);
  -- Pendiente de aprobación: sin fecha hasta que se aprueba (la fecha de la venta es la de la aprobación).
  PERFORM pruebas.como('cajero_a');
  vp := public.registrar_venta(e, jsonb_build_object('pagos', '[{"forma":"efectivo"}]'::jsonb,
          'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 10))), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(vp->>'estado' = 'pendiente_aprobacion'
    AND (SELECT garantia_dias = 90 AND garantia_hasta IS NULL FROM public.venta_linea WHERE venta_id = (vp->>'venta_id')::uuid), 'pendiente: sin fecha');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.resolver_aprobacion((vp->>'aprobacion_id')::uuid, true, 'Cliente frecuente', gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT garantia_hasta FROM public.venta_linea WHERE venta_id = (vp->>'venta_id')::uuid) = hoy + 90, 'aprobada: fecha puesta');
  PERFORM pruebas.debe_fallar(format('UPDATE public.venta_linea SET garantia_hasta = %L WHERE venta_id = %L', hoy + 900, vp->>'venta_id'),
    'PROHIBIDO', 'la fecha de garantía no se edita');

  -- ===== 2) Buscar =====
  PERFORM pruebas.como('vendedor_a');
  r := public.buscar_garantia(e, 'pintura');
  PERFORM pruebas.afirmar(jsonb_array_length(r->'lineas') = 3, 'tres galones con garantía: ' || r::text);
  PERFORM pruebas.afirmar((SELECT count(*) FROM jsonb_array_elements(r->'lineas') x WHERE (x->>'vigente')::boolean) = 2, 'dos vigentes');
  r := public.buscar_garantia(e, 'juan p', true);
  PERFORM pruebas.afirmar(jsonb_array_length(r->'lineas') = 1 AND (r->'lineas'->0->>'dias_restantes')::int = 90, 'por cliente y solo vigentes');
  PERFORM pruebas.debe_fallar(format('SELECT public.buscar_garantia(%L, %L)', e, 'x'), 'DATO_INVALIDO', 'texto muy corto');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.buscar_garantia(%L, %L)', e, 'pintura'), 'NO_PERTENECE', 'otra empresa');

  -- ===== 3) Registrar un reclamo =====
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1->'venta_id', 'linea', 2, 'motivo', 'Se doblan')), 'GARANTIA_INVALIDA', 'línea sin garantía');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1, 'cantidad', 2, 'motivo', 'No cubre')), 'GARANTIA_INVALIDA', 'más de lo vendido');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1)), 'FALTA_MOTIVO', 'sin motivo');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1, 'motivo', 'No cubre bien',
         'descripcion', 'Se ve la pared vieja con dos manos'), op);
  r2 := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1, 'motivo', 'No cubre bien'), op);
  PERFORM pruebas.afirmar(r->>'estado' = 'recibido' AND NOT (r->>'duplicado')::boolean AND (r2->>'duplicado')::boolean
    AND r2->>'reclamo_id' = r->>'reclamo_id', 'reclamo y doble envío');
  rec := (r->>'reclamo_id')::uuid;
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_garantia_reclamo WHERE empresa_id = e) = 1, 'el vendedor ve el reclamo');
  -- Vencida: se rechaza; el vendedor no puede autorizarla.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', vv->'venta_id', 'linea', 1, 'motivo', 'Se peló')), 'GARANTIA_VENCIDA', 'garantía vencida');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', vv->'venta_id', 'linea', 1, 'motivo', 'Se peló', 'autorizar_fuera_de_plazo', 'Cliente de años')),
    'SIN_PERMISO', 'el vendedor no autoriza fuera de plazo');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', vv->'venta_id', 'linea', 1, 'motivo', 'Se peló', 'autorizar_fuera_de_plazo', 'no')),
    'FALTA_MOTIVO', 'autorizar sin motivo');
  r2 := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', vv->'venta_id', 'linea', 1, 'motivo', 'Se peló',
          'autorizar_fuera_de_plazo', 'Cliente de años, el admin lo autoriza'), gen_random_uuid());
  PERFORM pruebas.afirmar((r2->>'fuera_de_plazo')::boolean, 'fuera de plazo autorizado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'garantia_reclamo' AND accion = 'INSERT'
    AND motivo = 'Cliente de años, el admin lo autoriza'), 'bitácora de la autorización');

  -- ===== 4) Estados y permisos =====
  PERFORM pruebas.como('cajero_a');
  r := public.cambiar_estado_reclamo(rec, 'en_revision', 'Lo revisa el proveedor', op);
  PERFORM pruebas.afirmar(r->>'estado' = 'en_revision', 'en revisión');
  r := public.cambiar_estado_reclamo(rec, 'en_revision', 'Lo revisa el proveedor', op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'doble envío del cambio de estado');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_estado_reclamo(%L, %L, %L, gen_random_uuid())', rec, 'rechazado', 'No aplica'),
    'SIN_PERMISO', 'el cajero no rechaza');
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_reclamo_garantia(%L, %L, gen_random_uuid())', rec, '{"resolucion": "reparado"}'),
    'SIN_PERMISO', 'el cajero no resuelve');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_estado_reclamo(%L, %L, %L, gen_random_uuid())', r2->>'reclamo_id', 'rechazado', 'no'),
    'FALTA_MOTIVO', 'rechazo sin motivo');
  PERFORM public.cambiar_estado_reclamo((r2->>'reclamo_id')::uuid, 'rechazado', 'Golpe por mal uso, no es defecto', gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.resolver_reclamo_garantia(%L, %L, gen_random_uuid())', r2->>'reclamo_id', '{"resolucion": "reparado"}'),
    'GARANTIA_INVALIDA', 'un rechazado no se resuelve');

  -- ===== 5) Resolver: reparado con costo de reparación (gasto de L 50.00 desde el banco) =====
  op := gen_random_uuid();
  r := public.resolver_reclamo_garantia(rec, jsonb_build_object('resolucion', 'reparado', 'nota', 'Se cambió la base',
         'costo_reparacion', jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 5000)), op);
  r2 := public.resolver_reclamo_garantia(rec, '{"resolucion": "reparado"}', op);
  PERFORM pruebas.afirmar(r->>'estado' = 'resuelto' AND r->>'resolucion' = 'reparado' AND r->>'gasto_id' IS NOT NULL
    AND (r2->>'duplicado')::boolean, 'reparado: ' || r::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado = 'aplicado' AND monto_centavos = 5000 FROM public.gasto WHERE id = (r->>'gasto_id')::uuid)
    AND (SELECT count(*) FROM public.gasto WHERE descripcion LIKE 'Reparación por garantía%') = 1, 'un solo gasto aplicado');
  PERFORM pruebas.afirmar((SELECT string_agg(coalesce(estado_anterior, '-') || '>' || estado_nuevo, ',' ORDER BY id) FROM public.garantia_reclamo_evento
                            WHERE reclamo_id = rec) = '->recibido,recibido>en_revision,en_revision>resuelto', 'historial');
  PERFORM pruebas.debe_fallar(format('UPDATE public.garantia_reclamo SET estado = %L WHERE id = %L', 'recibido', rec), 'PROHIBIDO', 'un resuelto no cambia');
  PERFORM pruebas.como('admin_a');
  r := public.documento_reclamo_garantia(rec);
  PERFORM pruebas.afirmar(r->>'titulo' = 'RECLAMO DE GARANTÍA' AND jsonb_array_length(r->'historial') = 3 AND r->>'resolucion' = 'reparado'
    AND r->>'garantia_hasta' = to_char(hoy + 90, 'DD/MM/YYYY'), 'comprobante del reclamo: ' || r::text);

  -- ===== 6) Cambiado: el cambio de producto de siempre (galón por galón, sin diferencia) =====
  PERFORM pruebas.como('vendedor_a');
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v1->'venta_id', 'linea', 1, 'motivo', 'Vino abierto'), gen_random_uuid());
  PERFORM pruebas.como('dueno_a');
  inv0 := pruebas.existencia('B1', 'P3');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, '{"resolucion": "cambiado", "nota": "Galón nuevo"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'resolucion' = 'cambiado' AND r->'devolucion'->>'estado' = 'aplicada' AND r->'devolucion'->'venta_cambio'->>'estado' = 'emitida'
    AND (SELECT motivo LIKE 'Garantía, reclamo #%' FROM public.devolucion WHERE id = (r->>'devolucion_id')::uuid), 'cambiado: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P3') = inv0, 'inventario: entra uno y sale uno');
  -- La venta nueva del cambio también trae su garantía.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT garantia_hasta FROM public.venta_linea WHERE venta_id = (r->'devolucion'->>'venta_cambio_id')::uuid) = hoy + 90,
    'garantía del galón del cambio');

  -- ===== 7) Devuelto: devolución en dinero desde el banco =====
  PERFORM pruebas.como('dueno_a');
  v2 := public.registrar_venta(e, pruebas.venta('P3', 1, 'efectivo'), gen_random_uuid());
  r := public.registrar_reclamo_garantia(e, jsonb_build_object('venta_id', v2->'venta_id', 'linea', 1, 'motivo', 'Color equivocado'), gen_random_uuid());
  n := pruebas.dinero('BANCO');
  r := public.resolver_reclamo_garantia((r->>'reclamo_id')::uuid, jsonb_build_object('resolucion', 'devuelto', 'destino', 'dinero',
         'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'resolucion' = 'devuelto' AND r->'devolucion'->>'estado' = 'aplicada' AND pruebas.dinero('BANCO') = n - 45000,
    'devuelto: L 450.00 salen del banco: ' || r::text);
  -- Ya devuelto: otro reclamo de esa línea no cabe.
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_reclamo_garantia(%L, %L, gen_random_uuid())', e,
    jsonb_build_object('venta_id', v2->'venta_id', 'linea', 1, 'motivo', 'Otra vez')), 'GARANTIA_INVALIDA', 'línea ya devuelta');

  -- ===== 8) Todo cuadra =====
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.garantia_reclamo) = 0 AND (SELECT count(*) FROM public.garantia_reclamo_evento) = 0, 'B no ve reclamos de A');
  PERFORM pruebas.como('superusuario');
  SELECT count(*) INTO n FROM (SELECT l.asiento_id FROM public.asiento_linea l WHERE l.empresa_id = e
                                GROUP BY l.asiento_id HAVING sum(l.debe_centavos) <> sum(l.haber_centavos)) x;
  PERFORM pruebas.afirmar(n = 0, 'asientos que no cuadran: ' || n);
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora(e)) = 0, 'bitácora íntegra');
END $$;
