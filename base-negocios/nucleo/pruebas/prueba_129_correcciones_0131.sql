-- PRUEBA: correcciones de la revisión de 0.13.0 (cifras a mano): sesión cerrada por session_id (el token renovado de la sesión vieja sigue rechazado; una sesión nueva sí entra); no se reabre un mes con reparto de utilidades vigente; resumen_hoy, alertas_activas y exportar_plantilla solo con las sucursales del usuario restringido (el dueño ve todo); conciliación: sucursal de la cuenta de banco al importar y emparejar; tipo "otro" sin cuentas de un módulo
-- Cada parte va en su propio bloque: contra 0.13.0 fallan las partes 1 a 5 (la preparación pasa en las dos).

-- ===================== Preparación (pasa en 0.13.0 y 0.13.1) =====================
-- Enero de preparar_enero (CLI1 debe 25,000 de V_ENE_2, emitida en la principal; vence 11/02).
-- Sucursal Norte (002) con su caja y efectivo (CAJA2) y bodega B3; 10 tornillos (P1) de B1 a B3.
-- El admin queda restringido a la principal (001).
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  s1 uuid;
  s2 uuid;
  c2 uuid;
BEGIN
  PERFORM pruebas.preparar_enero();
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de sucursales');
  SELECT id INTO s1 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  s2 := pruebas.guardar('S2', (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid);
  c2 := pruebas.guardar('C2', (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid);
  PERFORM pruebas.guardar('CAJA2', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja',
    'nombre', 'Caja Norte', 'caja_id', c2))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('B3', (public.crear_bodega(e, s2, 'B3', 'Bodega Norte')->>'bodega_id')::uuid);
  PERFORM public.trasladar_inventario(e, pruebas.id('B1'), pruebas.id('B3'), public.hoy_local(e),
    jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10)), gen_random_uuid(), 'Surtir la Norte');
  PERFORM pruebas.guardar('CLI_N', (public.crear_tercero(e, '{"nombre": "Ferretería del Norte", "es_cliente": true,
    "limite_credito_centavos": 500000, "plazo_dias": 30}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM pruebas.guardar('BANCO_N', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'banco', 'nombre', 'Banco Norte',
    'banco', 'BAC', 'numero_cuenta', '300-111-222', 'tipo_cuenta', 'cheques', 'sucursal_id', s2))->>'cuenta_dinero_id')::uuid);
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('admin_a'), ARRAY[s1], 'Encargado de la principal');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos'), (e, 'conciliacion')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
END $$;

-- ===================== 1) Sesión cerrada: el token renovado no la salta =====================
DO $$
DECLARE
  e       uuid := pruebas.empresa('A');
  cajero  uuid := pruebas.usuario('cajero_a');
  s_vieja uuid := md5('sesion:' || pruebas.usuario('cajero_a')::text)::uuid;   -- iniciada ayer (preparar_datos)
  s_nueva uuid := gen_random_uuid();
  ahora   bigint := extract(epoch FROM now())::bigint;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cerrar_sesion_usuario(e, cajero, 'Celular perdido');
  -- Supabase renueva el token: "iat" nuevo (una hora después del cierre) y el MISMO session_id.
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', cajero, 'role', 'authenticated',
    'session_id', s_vieja, 'iat', ahora + 3600)::text, true);
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'SESION_CERRADA', 'token renovado de la sesión cerrada');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L::jsonb, gen_random_uuid())', e, pruebas.venta('P1', 1)),
    'SESION_CERRADA', 'tampoco vende con el token renovado');
  PERFORM pruebas.afirmar((public.mi_estado_sesion(e)->>'debe_salir')::boolean, 'la app sabe que debe sacarlo (token renovado)');
  -- Una sesión que ya no existe en Supabase (salió o se revocó) tampoco entra.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', cajero, 'role', 'authenticated',
    'session_id', gen_random_uuid(), 'iat', ahora + 3600)::text, true);
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'SESION_CERRADA', 'sesión que no existe');
  -- Entra de nuevo: sesión nueva iniciada después del cierre.
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.sessions (id, user_id, created_at) VALUES (s_nueva, cajero, now() + interval '1 second');
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', cajero, 'role', 'authenticated',
    'session_id', s_nueva, 'iat', ahora + 3600)::text, true);
  PERFORM pruebas.afirmar(NOT (public.mi_estado_sesion(e)->>'debe_salir')::boolean, 'la sesión nueva vale');
  PERFORM public.resumen_hoy(e);
  -- La sesión nueva de otro usuario no le sirve (debe ser suya).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', cajero, 'role', 'authenticated',
    'session_id', md5('sesion:' || pruebas.usuario('dueno_a')::text)::uuid, 'iat', ahora + 3600)::text, true);
  PERFORM pruebas.debe_fallar(format('SELECT public.resumen_hoy(%L)', e), 'SESION_CERRADA', 'sesión de otro usuario');
  -- A los demás no les afecta.
  PERFORM pruebas.como('vendedor_a');
  PERFORM public.resumen_hoy(e);
END $$;

-- ===================== 2) No se reabre un mes con reparto vigente =====================
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  reinv uuid;
  r     jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  reinv := (public.crear_fondo(e, '{"nombre": "Reinversión", "tipo": "reinversion", "meta_tipo": "monto", "meta_monto_centavos": 100000}',
            'Fondo para crecer')->>'fondo_id')::uuid;
  PERFORM public.guardar_regla_distribucion(e, jsonb_build_object('fondos', jsonb_build_array(jsonb_build_object('fondo_id', reinv, 'porcentaje', 100))),
    'Todo a reinversión');
  PERFORM public.cerrar_mes(e, 2026, 1);
  -- A mano: utilidad cobrada de enero 35,159 (prueba 121); 100 % a reinversión = 35,159.
  r := public.distribuir_utilidades(e, 2026, 1, '{"fecha": "2026-02-15"}', 'Reparto de enero', gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'base_centavos')::bigint = 35159, 'reparto de enero 35,159: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.reabrir_periodo(%L, 2026, 1, %L)', e, 'Falta una factura'),
    'MES_CON_REPARTO', 'enero con reparto vigente no se reabre');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 1) = 'cerrado'
    AND EXISTS (SELECT 1 FROM public.cierre WHERE empresa_id = e AND anio = 2026 AND mes = 1 AND estado = 'vigente'), 'enero sigue cerrado con su foto');
  -- Primero se anula el reparto; después sí se reabre.
  PERFORM public.anular_distribucion((r->>'distribucion_id')::uuid, 'Hay que reabrir enero', gen_random_uuid(), '2026-02-15');
  PERFORM public.reabrir_periodo(e, 2026, 1, 'Falta una factura');
  PERFORM pruebas.afirmar((SELECT estado FROM public.periodo WHERE empresa_id = e AND anio = 2026 AND mes = 1) = 'abierto', 'reabierto sin reparto');
END $$;

-- ===================== 3) Lecturas de toda la empresa para el restringido =====================
-- Hoy: principal 1 tornillo = 1,500 (CAJA1); Norte 2 tornillos = 3,000 (efectivo en CAJA2).
-- Norte 01/08/2026 al crédito a CLI_N: 1 h de servicio = 23,000 a 30 días (vencida desde 31/08).
-- Tornillos: B1 = 100 - 10 (10/01) - 10 (traslado) - 1 = 79; B3 = 10 - 2 = 8; total 87. Mínimo 80.
-- Dueño: ventas hoy 4,500 (2); te deben 25,000 + 23,000 = 48,000 (2 clientes); sin alerta de tornillos (87 > 80).
-- Admin (solo principal): ventas hoy 1,500 (1); te deben 25,000 (1 cliente); alerta de tornillos (79 <= 80);
--   dinero = el del dueño - 3,000 (CAJA2); sin ganancia; en Excel existencia 79, sin B3 y CLI_N con saldo 0.
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  rd   jsonb;
  ra   jsonb;
  ad   jsonb;
  aa   jsonb;
  x    jsonb;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 1) || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 2) || jsonb_build_object('caja_id', pruebas.id('C2')), gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('S1', 1, 'credito', 'CLI_N')
    || jsonb_build_object('caja_id', pruebas.id('C2'), 'fecha', '2026-08-01'), gen_random_uuid());
  PERFORM pruebas.como('superusuario');
  UPDATE public.producto SET stock_minimo = 80 WHERE id = pruebas.id('P1');
  PERFORM pruebas.afirmar(pruebas.existencia('B1', 'P1') = 79 AND pruebas.existencia('B3', 'P1') = 8 AND pruebas.dinero('CAJA2') = 3000,
    'tornillos 79 + 8 y CAJA2 3,000');

  PERFORM pruebas.como('dueno_a');
  rd := public.resumen_hoy(e);
  ad := public.alertas_activas(e);
  PERFORM pruebas.como('admin_a');
  ra := public.resumen_hoy(e);
  aa := public.alertas_activas(e);

  -- resumen_hoy
  PERFORM pruebas.afirmar((rd->'ventas_hoy'->>'total_centavos')::bigint = 4500 AND (rd->'ventas_hoy'->>'cantidad')::integer = 2
    AND (rd->'te_deben'->>'total_centavos')::bigint = 48000 AND (rd->'te_deben'->>'clientes')::integer = 2
    AND rd->'ganancia_hoy' <> 'null'::jsonb AND NOT coalesce((rd->>'solo_mis_sucursales')::boolean, false), 'dueño ve todo: ' || rd::text);
  PERFORM pruebas.afirmar((ra->'ventas_hoy'->>'total_centavos')::bigint = 1500 AND (ra->'ventas_hoy'->>'cantidad')::integer = 1,
    'restringido: ventas de hoy solo de la principal: ' || (ra->'ventas_hoy')::text);
  PERFORM pruebas.afirmar((ra->'te_deben'->>'total_centavos')::bigint = 25000 AND (ra->'te_deben'->>'clientes')::integer = 1,
    'restringido: no ve la CxC de la Norte: ' || (ra->'te_deben')::text);
  PERFORM pruebas.afirmar((rd->'dinero'->>'disponible_centavos')::bigint - (ra->'dinero'->>'disponible_centavos')::bigint = 3000,
    'restringido: no cuenta CAJA2: ' || (rd->'dinero')::text || ' / ' || (ra->'dinero')::text);
  PERFORM pruebas.afirmar(ra->'ganancia_hoy' = 'null'::jsonb AND ra->'ganancia_mes' = 'null'::jsonb
    AND ra->'ocultos' ? 'ganancia_hoy' AND (ra->>'solo_mis_sucursales')::boolean, 'restringido: ganancia de la empresa oculta');

  -- alertas_activas
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(ad->'alertas') a WHERE a->>'tipo' = 'credito_vencido'
      AND (a->'datos'->>'cliente_id')::uuid = pruebas.id('CLI_N') AND (a->'datos'->>'saldo_vencido_centavos')::bigint = 23000)
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ad->'alertas') a WHERE a->>'tipo' = 'stock_minimo'
      AND (a->'datos'->>'producto_id')::uuid = pruebas.id('P1')), 'dueño: crédito vencido de la Norte y tornillos sin alerta');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(aa->'alertas') a WHERE a->>'tipo' = 'credito_vencido'
      AND (a->'datos'->>'cliente_id')::uuid = pruebas.id('CLI1'))
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(aa->'alertas') a WHERE a->>'tipo' = 'credito_vencido'
      AND (a->'datos'->>'cliente_id')::uuid = pruebas.id('CLI_N')), 'restringido: no ve el crédito de la Norte: ' || (aa->'alertas')::text);
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(aa->'alertas') a WHERE a->>'tipo' = 'stock_minimo'
      AND (a->'datos'->>'producto_id')::uuid = pruebas.id('P1') AND (a->'datos'->>'existencia')::numeric = 79),
    'restringido: tornillos con la existencia de SU bodega (79)');

  -- exportar_plantilla
  x := public.exportar_plantilla(e, 'productos');
  PERFORM pruebas.afirmar((SELECT (f->>'existencia_total')::numeric FROM jsonb_array_elements(x->'filas') f WHERE f->>'codigo' = 'TOR-001') = 79,
    'restringido: existencia total sin la Norte');
  x := public.exportar_plantilla(e, 'conteo_fisico');
  PERFORM pruebas.afirmar(jsonb_array_length(x->'filas') > 0
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'filas') f WHERE f->>'bodega' = 'B3'), 'restringido: conteo sin la bodega de la Norte');
  x := public.exportar_plantilla(e, 'clientes_proveedores');
  PERFORM pruebas.afirmar((SELECT (f->>'saldo_por_cobrar')::numeric FROM jsonb_array_elements(x->'filas') f WHERE f->>'nombre' = 'Ferretería del Norte') = 0
    AND (SELECT (f->>'saldo_por_cobrar')::numeric FROM jsonb_array_elements(x->'filas') f WHERE f->>'nombre' = 'Constructora Ríos') = 250,
    'restringido: saldo del cliente de la Norte en 0');

  PERFORM pruebas.como('dueno_a');
  x := public.exportar_plantilla(e, 'productos');
  PERFORM pruebas.afirmar((SELECT (f->>'existencia_total')::numeric FROM jsonb_array_elements(x->'filas') f WHERE f->>'codigo' = 'TOR-001') = 87,
    'dueño: existencia total 87');
  x := public.exportar_plantilla(e, 'conteo_fisico');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM jsonb_array_elements(x->'filas') f WHERE f->>'bodega' = 'B3'), 'dueño: conteo con B3');
  x := public.exportar_plantilla(e, 'clientes_proveedores');
  PERFORM pruebas.afirmar((SELECT (f->>'saldo_por_cobrar')::numeric FROM jsonb_array_elements(x->'filas') f WHERE f->>'nombre' = 'Ferretería del Norte') = 230,
    'dueño: saldo del cliente de la Norte 230.00');
END $$;

-- ===================== 4) Conciliación: la sucursal de la cuenta de banco =====================
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  fila jsonb := '{"filas":[{"fecha":"2026-09-10","descripcion":"DEPOSITO","monto_centavos":1000}]}';
BEGIN
  PERFORM pruebas.como('dueno_a');
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO_N'), 2026, 9, fila, gen_random_uuid());
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 9, %L, gen_random_uuid())', e, pruebas.id('BANCO_N'),
    '{"filas":[{"fecha":"2026-09-11","descripcion":"OTRO","monto_centavos":500}]}'), 'SUCURSAL_NO_PERMITIDA', 'no importa el banco de la Norte');
  PERFORM pruebas.debe_fallar(format('SELECT public.emparejar_conciliacion(%L)', r->>'conciliacion_id'), 'SUCURSAL_NO_PERMITIDA',
    'no empareja la conciliación de la Norte');
  -- El banco de toda la empresa (sin sucursal) sí.
  PERFORM public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 9, fila, gen_random_uuid());
END $$;

-- ===================== 5) Conciliación "otro": no a una cuenta de un módulo =====================
-- Hoy ninguna cuenta que controla un módulo es de ingresos, costos o gastos; se simula una (6.1.02.05)
-- para que la regla quede vigilada si un módulo futuro la agrega.
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  c  uuid;
  b1 uuid;
  b2 uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla)
  VALUES ('prueba_gasto_de_modulo', '6.1.02.05', 'Prueba: gasto que mueve un módulo', 'ventas');
  PERFORM pruebas.como('dueno_a');
  c := (public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 7, '{"filas":[
    {"fecha":"2026-07-15","descripcion":"CHEQUE 1001","monto_centavos":-2000},
    {"fecha":"2026-07-16","descripcion":"CHEQUE 1002","monto_centavos":-3000}]}', gen_random_uuid())->>'conciliacion_id')::uuid;
  SELECT id INTO b1 FROM public.banco_movimiento WHERE conciliacion_id = c AND monto_centavos = -2000;
  SELECT id INTO b2 FROM public.banco_movimiento WHERE conciliacion_id = c AND monto_centavos = -3000;
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_diferencia_banco(%L, %L, %L, gen_random_uuid())', c, b1,
    '{"tipo":"otro","cuenta":"6.1.02.05"}'), 'CUENTA_INVALIDA', 'otro: cuenta que mueve un módulo no');
  PERFORM public.registrar_diferencia_banco(c, b2, '{"tipo":"otro","cuenta":"6.1.02.06","descripcion":"Cheque 1002"}', gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '6.1.02.06') >= 3000, 'otro: cuenta de gasto normal sí');
END $$;
