-- =====================================================================
-- demo_rubro.sql  -  SOLO BASE LOCAL DE DEMOSTRACIÓN. Crea una empresa de
-- prueba con datos FALSOS de un rubro, para enseñar en la visita.
-- Es demo_datos.sql generalizado: lo que cambia por rubro sale de la
-- plantilla (armador/plantillas/<rubro>.json, sección "demo"), que el Armador
-- pasa antes en la variable armador.demo:
--
--   SELECT set_config('armador.demo', '<json>', false);
--   \i herramientas/demo_rubro.sql
--
-- JSON: {"nombre","rubro","dominio" (correos: dueno@<dominio>...),
--        "modulos": [...], "perfil", "categorias": [...], "unidades": [{codigo,nombre}],
--        "campos_extra": [{donde:"producto",clave,etiqueta,tipo,opciones?}],
--        "usuarios": [{rol,nombre}], "productos": [{codigo,nombre,precio,costo,
--        existencia?,tipo?,categoria?}], "clientes": [{nombre,credito?,plazo?,telefono?}],
--        "ventas": [{dias, cliente? (posición), lineas: [[codigo,cantidad]], pago}],
--        "colores": {principal, acento}}
-- Fechas relativas a hoy (la demo siempre se ve viva). Nunca toca otra empresa.
-- =====================================================================
DO $$
DECLARE
  d       jsonb := current_setting('armador.demo')::jsonb;
  dom     text  := d->>'dominio';
  e       uuid;
  inicio  date  := (date_trunc('month', (now() AT TIME ZONE 'America/Tegucigalpa')::date) - interval '1 month')::date;
  hoy     date;
  s001    uuid;
  caja1   uuid;
  bodega  uuid;
  x       jsonb;
  l       jsonb;
  cats    jsonb := '{}';
  prods   jsonb := '{}';
  clis    jsonb := '[]';
  carga   jsonb := '[]';
  lineas  jsonb;
  dato    jsonb;
  inv     boolean := (d->'modulos') ? 'inventario';
  din     boolean := (d->'modulos') ? 'dinero';
  i       int;
BEGIN
  IF dom !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'DATO_INVALIDO: dominio de la demo'; END IF;
  -- Usuarios de Auth (simulador local): dueño y los de la plantilla.
  INSERT INTO auth.users (email) VALUES ('dueno@' || dom) ON CONFLICT DO NOTHING;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'usuarios', '[]')) LOOP
    INSERT INTO auth.users (email) VALUES ((x->>'rol') || '@' || dom) ON CONFLICT DO NOTHING;
  END LOOP;

  -- 1) La empresa la crea el proveedor (llave service_role).
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  SET LOCAL ROLE service_role;
  e := public.crear_empresa_inicial(jsonb_build_object(
    'nombre', d->>'nombre', 'rubro', d->>'rubro', 'fecha_inicio', inicio, 'perfil', coalesce(d->>'perfil', 'pequeno'),
    'modulos', d->'modulos',
    'dueno', jsonb_build_object('user_id', (SELECT id FROM auth.users WHERE email = 'dueno@' || dom), 'nombre', 'Dueño de la demo')));
  INSERT INTO public.licencia (empresa_id, vence_el) VALUES (e, public.hoy_local() + 90);
  RESET ROLE;
  hoy := public.hoy_local(e);
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  SELECT id INTO caja1 FROM public.caja WHERE empresa_id = e AND punto_emision = '001';

  -- 2) Como el dueño (igual que demo_datos.sql: demo.como).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM auth.users WHERE email = 'dueno@' || dom),
    'role', 'authenticated')::text, true);
  PERFORM set_config('role', 'authenticated', true);

  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'usuarios', '[]')) LOOP
    PERFORM public.agregar_usuario_empresa(e, (x->>'rol') || '@' || dom, x->>'rol', x->>'nombre');
  END LOOP;
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Demo: sin turnos obligatorios');
  IF d->'colores' IS NOT NULL THEN
    PERFORM public.configurar_marca(e, jsonb_build_object('color_principal', d->'colores'->>'principal',
      'color_acento', d->'colores'->>'acento'), 'Demo: colores del rubro');
  END IF;
  IF inv THEN
    bodega := (public.crear_bodega(e, s001, 'B1', 'Bodega principal')->>'bodega_id')::uuid;
  END IF;
  IF din THEN
    PERFORM public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja 1', 'caja_id', caja1));
    PERFORM public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "Banco de la demo", "banco": "Banco Demo",
      "numero_cuenta": "0000-1111-2222", "tipo_cuenta": "cheques"}');
  END IF;

  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'categorias', '[]')) LOOP
    cats := cats || jsonb_build_object(x #>> '{}', public.crear_categoria(e, x #>> '{}')->>'categoria_id');
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'unidades', '[]')) LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.unidad u WHERE u.codigo = upper(x->>'codigo')
                           AND (u.empresa_id IS NULL OR u.empresa_id = e));   -- ya es común
    PERFORM public.crear_unidad(e, x->>'codigo', x->>'nombre');
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'campos_extra', '[]')) LOOP
    CONTINUE WHEN x->>'donde' <> 'producto';
    PERFORM public.crear_campo_extra(e, x->>'clave', x->>'etiqueta', x->>'tipo', x->'opciones', false);
  END LOOP;

  -- 3) Productos y servicios; existencias iniciales de los bienes.
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'productos', '[]')) LOOP
    CONTINUE WHEN coalesce(x->>'tipo', 'bien') = 'bien' AND NOT inv;   -- sin inventario solo servicios
    dato := jsonb_build_object('codigo', x->>'codigo', 'nombre', x->>'nombre',
      'precio_venta_centavos', (x->>'precio')::bigint, 'tipo', coalesce(x->>'tipo', 'bien'));
    IF x->>'categoria' IS NOT NULL AND cats ? (x->>'categoria') THEN
      dato := dato || jsonb_build_object('categoria_id', cats->>(x->>'categoria'));
    END IF;
    IF x->>'tipo' = 'servicio' THEN
      dato := dato || jsonb_build_object('costo_estimado_centavos', (x->>'costo')::bigint);
    END IF;
    prods := prods || jsonb_build_object(x->>'codigo',
      public.crear_producto(e, dato, gen_random_uuid())->>'producto_id');
    IF coalesce(x->>'tipo', 'bien') = 'bien' AND coalesce((x->>'existencia')::numeric, 0) > 0 THEN
      carga := carga || jsonb_build_array(jsonb_build_object('producto_id', prods->>(x->>'codigo'),
        'cantidad', (x->>'existencia')::numeric, 'costo_unitario', (x->>'costo')::bigint));
    END IF;
  END LOOP;
  IF inv AND jsonb_array_length(carga) > 0 THEN
    PERFORM public.cargar_saldo_inicial(e, bodega, inicio, carga, gen_random_uuid(), NULL);
  END IF;

  -- 4) Clientes.
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'clientes', '[]')) LOOP
    dato := jsonb_build_object('nombre', x->>'nombre', 'es_cliente', true);
    IF x ? 'credito' THEN dato := dato || jsonb_build_object('limite_credito_centavos', (x->>'credito')::bigint,
      'plazo_dias', coalesce((x->>'plazo')::int, 30)); END IF;
    IF x ? 'telefono' THEN dato := dato || jsonb_build_object('telefono', x->>'telefono'); END IF;
    clis := clis || jsonb_build_array(public.crear_tercero(e, dato, gen_random_uuid())->>'tercero_id');
  END LOOP;

  -- 5) Ventas de los últimos días (contado, tarjeta y crédito).
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(d->'ventas', '[]')) LOOP
    lineas := '[]';
    FOR l IN SELECT * FROM jsonb_array_elements(x->'lineas') LOOP
      CONTINUE WHEN NOT prods ? (l->>0);
      lineas := lineas || jsonb_build_array(jsonb_build_object('producto_id', prods->>(l->>0), 'cantidad', (l->>1)::numeric));
    END LOOP;
    CONTINUE WHEN jsonb_array_length(lineas) = 0;
    CONTINUE WHEN x->>'pago' <> 'credito' AND NOT din;                 -- sin dinero solo crédito
    dato := jsonb_build_object('lineas', lineas, 'pagos', jsonb_build_array(jsonb_build_object('forma', x->>'pago')));
    IF coalesce((x->>'dias')::int, 0) > 0 THEN dato := dato || jsonb_build_object('fecha', hoy - (x->>'dias')::int); END IF;
    IF x ? 'cliente' THEN
      i := (x->>'cliente')::int;
      dato := dato || jsonb_build_object('cliente_id', clis->>i);
    END IF;
    PERFORM public.registrar_venta(e, dato, gen_random_uuid());
  END LOOP;

  PERFORM set_config('role', 'none', true);
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'EMPRESA_DEMO %', e;
  PERFORM set_config('armador.empresa', e::text, false);
END $$;
SELECT '@@R@@' || current_setting('armador.empresa');
