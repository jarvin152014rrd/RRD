-- PRUEBA: "¿dónde está mi dinero hoy?" (saldo por cuenta, por tipo, en tránsito con alerta y cuentas de efectivo sin rastro) y estado de cuenta de una cuenta de dinero entre dos fechas (saldo inicial, cada movimiento con origen o destino, usuario y referencia, saldo final), con cifras a mano y permisos
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  dep  jsonb;
  r    jsonb;
  m    jsonb;
BEGIN
  PERFORM pruebas.preparar_dinero();
  -- Inicio: BAC 1,000,000 y caja fuerte 300,000 (saldos iniciales del 02/01, los cargó el dueño).
  PERFORM pruebas.como('admin_a');
  dep := public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'),
    'monto_centavos', 100000, 'fecha', '2026-01-10', 'referencia', 'Boleta 1'), gen_random_uuid());
  PERFORM public.trasladar_dinero(e, jsonb_build_object('tipo', 'retiro', 'origen_id', pruebas.id('BANCO'), 'destino_id', pruebas.id('FUERTE'),
    'monto_centavos', 50000, 'fecha', '2026-01-12', 'referencia', 'Cheque 7'), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 11500, 'descripcion', 'Luz enero', 'fecha', '2026-02-03'), gen_random_uuid());
  -- Caja general (1.1.01.01, sin rastro) con 12,345 por un asiento manual del dueño.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(e, '2026-01-20', 'Venta vieja en caja general', pruebas.lineas('1.1.01.01', '4.1.01.01', 12345), gen_random_uuid());
  PERFORM public.desactivar_cuenta_dinero(e, pruebas.id('CCHICA'), 'Todavía no se usa');

  -- Antes de confirmar: BAC 1,000,000 - 50,000 - 11,500 = 938,500; caja fuerte 300,000 - 100,000 + 50,000 = 250,000;
  -- tránsito 100,000; total 1,288,500; más 12,345 sin rastro = 1,300,845.
  PERFORM pruebas.como('admin_a');
  r := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 1288500 AND (r->>'total_con_otras_centavos')::bigint = 1300845, 'totales: ' || r::text);
  PERFORM pruebas.afirmar((r->'por_tipo'->>'banco')::bigint = 938500 AND (r->'por_tipo'->>'efectivo_caja')::bigint = 250000
    AND (r->'por_tipo'->>'transito')::bigint = 100000 AND (r->'por_tipo'->>'caja_chica')::bigint = 0, 'por tipo');
  PERFORM pruebas.afirmar((r->'en_transito'->>'total_centavos')::bigint = 100000 AND (r->'en_transito'->>'con_alerta')::int = 1
    AND jsonb_array_length(r->'en_transito'->'depositos') = 1 AND r->'en_transito'->'depositos'->0->>'banco' = 'BAC cheques', 'en tránsito');
  PERFORM pruebas.afirmar(r->'otras_cuentas_efectivo_sin_rastro' = '[{"nombre": "Caja general", "cuenta_codigo": "1.1.01.01", "saldo_centavos": 12345}]'::jsonb,
    'cuenta sin rastro visible');
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'nombre', ',' ORDER BY x->>'nombre') FROM jsonb_array_elements(r->'cuentas') x)
    = 'BAC cheques,Caja 1,Caja fuerte,Depósitos en tránsito', 'la caja chica desactivada y en 0 no sale');
  PERFORM pruebas.afirmar((SELECT x->>'numero_enmascarado' FROM jsonb_array_elements(r->'cuentas') x WHERE x->>'nombre' = 'BAC cheques') = '****6789', 'banco enmascarado');

  -- Confirmado el depósito (05/02): BAC 1,038,500; tránsito 0.
  PERFORM public.confirmar_deposito((dep->>'operacion_id')::uuid, gen_random_uuid(), '2026-02-05', 'Conf 9');
  r := public.donde_esta_mi_dinero(e);
  PERFORM pruebas.afirmar((r->'por_tipo'->>'banco')::bigint = 1038500 AND (r->'en_transito'->>'total_centavos')::bigint = 0
    AND (r->>'total_centavos')::bigint = 1288500, 'después de confirmar');
  PERFORM pruebas.afirmar((SELECT saldo_centavos FROM public.v_cuenta_dinero WHERE cuenta_dinero_id = pruebas.id('BANCO')) = 1038500, 'v_cuenta_dinero');

  -- Estado de cuenta del BAC en enero desde el 05: inicial 1,000,000; sale el retiro 50,000; final 950,000.
  r := public.estado_cuenta_dinero(pruebas.id('BANCO'), '2026-01-05', '2026-01-31');
  PERFORM pruebas.afirmar((r->>'saldo_inicial_centavos')::bigint = 1000000 AND (r->>'entradas_centavos')::bigint = 0
    AND (r->>'salidas_centavos')::bigint = 50000 AND (r->>'saldo_final_centavos')::bigint = 950000
    AND jsonb_array_length(r->'movimientos') = 1, 'enero: ' || r::text);
  m := r->'movimientos'->0;
  PERFORM pruebas.afirmar(m->>'fecha' = '2026-01-12' AND (m->>'salida_centavos')::bigint = 50000 AND m->>'origen_o_destino' = 'Caja fuerte'
    AND m->>'referencia' = 'Cheque 7' AND m->>'usuario' = 'admin_a@prueba.hn' AND m->>'operacion' = 'dinero_retiro'
    AND (m->>'saldo_centavos')::bigint = 950000, 'movimiento del retiro: ' || m::text);
  -- Todo el año: 4 movimientos; saldos 1,000,000 / 950,000 / 938,500 / 1,038,500.
  r := public.estado_cuenta_dinero(pruebas.id('BANCO'), '2026-01-01', '2026-12-31');
  PERFORM pruebas.afirmar((r->>'saldo_inicial_centavos')::bigint = 0 AND (r->>'entradas_centavos')::bigint = 1100000
    AND (r->>'salidas_centavos')::bigint = 61500 AND (r->>'saldo_final_centavos')::bigint = 1038500, 'año');
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'saldo_centavos', ',' ORDER BY (x->>'fecha')) FROM jsonb_array_elements(r->'movimientos') x)
    = '1000000,950000,938500,1038500', 'saldo corrido');
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'origen_o_destino', ' | ' ORDER BY (x->>'fecha')) FROM jsonb_array_elements(r->'movimientos') x)
    = '3.3.01.03 Saldos de apertura | Caja fuerte | 6.1.02.02 Energía eléctrica | Depósitos en tránsito', 'de dónde y a dónde');
  PERFORM pruebas.afirmar((r->'movimientos'->0->>'usuario') = 'Dueño A' AND (r->'movimientos'->0->>'referencia') = 'Estado de cuenta dic-2025', 'usuario y referencia');
  -- La caja fuerte: el depósito salió hacia "Depósitos en tránsito".
  r := public.estado_cuenta_dinero(pruebas.id('FUERTE'), '2026-01-10', '2026-01-10');
  PERFORM pruebas.afirmar(r->'movimientos'->0->>'origen_o_destino' = 'Depósitos en tránsito' AND (r->>'saldo_final_centavos')::bigint = 200000, 'caja fuerte');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_dinero(%L, %L, %L)', pruebas.id('BANCO'), '2026-02-01', '2026-01-01'), 'FECHA_INVALIDA', 'fechas al revés');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_dinero(%L, %L, %L)', gen_random_uuid(), '2026-01-01', '2026-01-31'), 'NO_EXISTE', 'cuenta inventada');

  -- Permisos: vendedor y cajero no ven el dinero; otra empresa tampoco.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.donde_esta_mi_dinero(%L)', e), 'SIN_PERMISO', 'vendedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_dinero(%L, %L, %L)', pruebas.id('BANCO'), '2026-01-01', '2026-01-31'), 'SIN_PERMISO', 'vendedor estado');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.v_cuenta_dinero) = 0 AND (SELECT count(*) FROM public.v_deposito_transito) = 0, 'vendedor no ve bancos');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.donde_esta_mi_dinero(%L)', e), 'SIN_PERMISO', 'cajero');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.estado_cuenta_dinero(%L, %L, %L)', pruebas.id('BANCO'), '2026-01-01', '2026-01-31'), 'NO_PERTENECE', 'otra empresa');
  PERFORM pruebas.debe_fallar(format('SELECT public.donde_esta_mi_dinero(%L)', e), 'NO_PERTENECE', 'otra empresa: dónde está');
  -- Con la llave del proveedor (service_role) se puede leer para soporte técnico.
  PERFORM pruebas.como('service_role');
  PERFORM pruebas.afirmar((public.donde_esta_mi_dinero(e)->>'total_centavos')::bigint = 1288500, 'service_role');
END $$;
