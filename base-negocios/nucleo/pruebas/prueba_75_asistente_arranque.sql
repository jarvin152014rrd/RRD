-- PRUEBA: asistente de arranque: 7 pasos que se marcan "hechos" solos con los datos reales, se pueden saltar o volver a pendiente, porcentaje y nunca bloquea operar; "empezar en cero" y saldo inicial de cajas y bancos (una vez por cuenta, anulable); valores iniciales aprobados (admin L 5,000, arqueo a ciegas, solo la moneda de la empresa)
DO $$
DECLARE
  b    uuid := pruebas.empresa('B');
  a    uuid := pruebas.empresa('A');
  s    jsonb;
  gav  uuid;
  bco  uuid;
  si   jsonb;
  t    jsonb;
BEGIN
  -- 1) Empresa nueva (B: tiene RTN, solo el dueño): 1 de 7 = 14 %.
  PERFORM pruebas.como('dueno_b');
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'paso' || '=' || (x->>'estado'), ',' ORDER BY (x->>'orden')::int) FROM jsonb_array_elements(s->'pasos') x)
    = 'datos_negocio=hecho,usuarios=pendiente,cuentas_dinero=pendiente,productos=pendiente,clientes=pendiente,proveedores=pendiente,primera_venta=pendiente',
    'estado inicial: ' || (s->'pasos')::text);
  PERFORM pruebas.afirmar((s->>'hechos')::int = 1 AND (s->>'pendientes')::int = 6 AND (s->>'porcentaje')::int = 14 AND NOT (s->>'terminado')::boolean,
    '1 de 7 = 14 %');
  PERFORM pruebas.afirmar(s->'pasos'->2->>'detalle' = 'Todavía no hay cajas ni bancos registrados.', 'detalle de cajas');

  -- 2) Quién puede.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_arranque(%L)', b), 'NO_PERTENECE', 'otra empresa');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_arranque(%L)', a), 'SIN_PERMISO', 'cajero no');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_paso_arranque(%L, %L, %L)', a, 'productos', 'saltado'), 'SIN_PERMISO', 'cajero no marca');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar((public.estado_arranque(a)->>'porcentaje')::int >= 0, 'el admin sí ve el avance');

  -- 3) Saltar y volver a pendiente (el programa recuerda; nunca bloquea).
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_paso_arranque(%L, %L, %L)', b, 'ventas', 'saltado'), 'DATO_INVALIDO', 'paso inventado');
  PERFORM pruebas.debe_fallar(format('SELECT public.marcar_paso_arranque(%L, %L, %L)', b, 'productos', 'hecho'), 'DATO_INVALIDO', 'hecho no se marca a mano');
  s := public.marcar_paso_arranque(b, 'primera_venta', 'saltado');
  PERFORM pruebas.afirmar(s->'pasos'->6->>'estado' = 'saltado' AND (s->>'saltados')::int = 1 AND (s->>'pendientes')::int = 5
    AND (s->>'porcentaje')::int = 14, 'saltado: ' || s::text);
  s := public.marcar_paso_arranque(b, 'productos', 'saltado');
  s := public.marcar_paso_arranque(b, 'productos', 'pendiente');
  PERFORM pruebas.afirmar(s->'pasos'->3->>'estado' = 'pendiente', 'vuelve a pendiente');

  -- 4) Usuarios: agregar un cajero lo marca hecho (2 de 7 = 29 %).
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('cajero_b@prueba.hn');
  PERFORM pruebas.como('dueno_b');
  PERFORM public.agregar_usuario_empresa(b, 'cajero_b@prueba.hn', 'cajero', 'Cajero B');
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar(s->'pasos'->1->>'estado' = 'hecho' AND (s->>'porcentaje')::int = 29, 'usuarios hecho, 29 %');

  -- 5) Cajas y bancos: cada cuenta con saldo inicial o "empezar en cero".
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (b, 'dinero'), (b, 'inventario');
  PERFORM pruebas.como('dueno_b');
  gav := (public.crear_cuenta_dinero(b, '{"tipo":"efectivo_caja","nombre":"Gaveta"}')->>'cuenta_dinero_id')::uuid;
  bco  := (public.crear_cuenta_dinero(b, '{"tipo":"banco","nombre":"Atlántida","banco":"Banco Atlántida"}')->>'cuenta_dinero_id')::uuid;
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar(s->'pasos'->2->>'estado' = 'pendiente' AND jsonb_array_length(s->'cuentas_sin_saldo_inicial') = 2
    AND s->'pasos'->2->>'detalle' = '2 cuenta(s) sin saldo inicial ni "empezar en cero".', 'dos cuentas pendientes');
  -- Saldo inicial del banco: L 5,000.00 contra Saldos de apertura (3.3.01.03).
  si := public.registrar_saldo_inicial_dinero(b, jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 500000), gen_random_uuid());
  PERFORM pruebas.afirmar((si->>'saldo_destino_centavos')::bigint = 500000 AND pruebas.saldo_libros(b, '3.3.01.03') = 500000, 'saldo inicial 500,000');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_saldo_inicial_dinero(%L, %L, gen_random_uuid())', b,
    jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 1000)), 'SALDO_INICIAL_YA_CARGADO', 'una sola vez por cuenta');
  PERFORM pruebas.debe_fallar(format('SELECT public.empezar_cuenta_en_cero(%L, %L)', b, bco), 'SALDO_INICIAL_YA_CARGADO', 'con saldo no empieza en cero');
  -- La gaveta empieza en cero (no mueve dinero).
  PERFORM pruebas.afirmar(NOT (public.empezar_cuenta_en_cero(b, gav)->>'ya_estaba')::boolean, 'gaveta en cero');
  PERFORM pruebas.afirmar((public.empezar_cuenta_en_cero(b, gav)->>'ya_estaba')::boolean, 'repetir: ya estaba');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = gav AND saldo_centavos <> 0), 'no movió dinero');
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar(s->'pasos'->2->>'estado' = 'hecho' AND (s->>'porcentaje')::int = 43, 'cajas y bancos hecho, 43 %');
  -- Anular el saldo inicial del banco (estaba mal): el paso vuelve a pendiente; se carga otra vez (L 4,500.00).
  PERFORM public.anular_operacion_dinero((si->>'operacion_id')::uuid, 'Era otro monto', gen_random_uuid());
  PERFORM pruebas.afirmar(public.estado_arranque(b)->'pasos'->2->>'estado' = 'pendiente', 'anulado: pendiente otra vez');
  PERFORM public.registrar_saldo_inicial_dinero(b, jsonb_build_object('cuenta_dinero_id', bco, 'monto_centavos', 450000), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(b, '3.3.01.03') = 450000 AND public.estado_arranque(b)->'pasos'->2->>'estado' = 'hecho',
    'cargado otra vez: 450,000');
  -- Solo quien tiene dinero.saldo_inicial (el dueño).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.empezar_cuenta_en_cero(%L, %L)', a, gen_random_uuid()), 'SIN_PERMISO', 'admin no');

  -- 6) Productos, clientes y proveedores: se marcan solos al existir.
  PERFORM pruebas.como('dueno_b');
  PERFORM public.crear_producto(b, '{"codigo": "CAF-1", "nombre": "Café molido", "precio_venta_centavos": 4500}', gen_random_uuid());
  PERFORM public.crear_tercero(b, '{"nombre": "Doña Marta", "es_cliente": true}', gen_random_uuid());
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar(s->'pasos'->3->>'estado' = 'hecho' AND s->'pasos'->4->>'estado' = 'hecho' AND s->'pasos'->5->>'estado' = 'pendiente'
    AND (s->>'porcentaje')::int = 71, 'productos y clientes: 5 de 7 = 71 %');
  -- Saltar un paso ya hecho no lo cambia.
  s := public.marcar_paso_arranque(b, 'clientes', 'saltado');
  PERFORM pruebas.afirmar(s->'pasos'->4->>'estado' = 'hecho', 'hecho gana a saltado');
  PERFORM public.crear_tercero(b, '{"nombre": "Café Marcala", "es_proveedor": true}', gen_random_uuid());
  s := public.estado_arranque(b);
  PERFORM pruebas.afirmar((s->>'hechos')::int = 6 AND (s->>'saltados')::int = 1 AND (s->>'pendientes')::int = 0
    AND (s->>'porcentaje')::int = 86 AND (s->>'terminado')::boolean, 'terminado con la venta saltada: 86 %');
  s := public.marcar_paso_arranque(b, 'primera_venta', 'pendiente');
  PERFORM pruebas.afirmar(NOT (s->>'terminado')::boolean AND (s->>'pendientes')::int = 1, 'la venta queda pendiente');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = b AND tabla = 'arranque_paso') >= 5, 'marcas en la bitácora');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.arranque_paso WHERE empresa_id = %L', b), 'PROHIBIDO', 'no se borran');

  -- 7) Valores iniciales aprobados por el dueño.
  PERFORM pruebas.afirmar((SELECT sin_aprobacion_centavos || '/' || aprueba_hasta_centavos FROM interno.plantilla_tope_rol
                            WHERE rol = 'admin' AND tipo = 'gasto') = '500000/500000', 'admin registra y aprueba hasta L 5,000.00');
  PERFORM pruebas.afirmar((SELECT x.sin_aprobacion || '/' || x.aprueba_hasta FROM interno.tope_rol(b, 'admin', 'gasto') x) = '500000/500000'
    AND (SELECT x.sin_aprobacion || '/' || x.aprueba_hasta FROM interno.tope_rol(b, 'cajero', 'gasto') x) = '0/0', 'tope de una empresa nueva');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_cuenta_dinero(%L, %L)', b, '{"tipo":"banco","nombre":"Dólares","banco":"BAC","moneda":"USD"}'),
    'MONEDA_NO_SOPORTADA', 'solo la moneda de la empresa');
  t := public.abrir_turno(b, (SELECT id FROM public.caja WHERE empresa_id = b AND punto_emision = '001'), 0, gen_random_uuid());
  PERFORM pruebas.afirmar(public.mi_turno(b)->'turno' ? 'fondo_inicial_centavos'
    AND NOT (public.mi_turno(b)->'turno' ? 'esperado_centavos') AND NOT (public.mi_turno(b)->'turno' ? 'entradas_centavos'),
    'arqueo a ciegas: mi_turno no muestra el esperado');
END $$;
