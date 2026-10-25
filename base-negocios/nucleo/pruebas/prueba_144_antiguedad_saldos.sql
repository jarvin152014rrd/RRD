-- PRUEBA: (0.18.0) antigüedad de saldos (cifras a mano): por cliente, corriente (no vencido), 1-30, 31-60, 61-90 y más de 90 días VENCIDO a una fecha de corte; incluye saldos iniciales; los cobros bajan el saldo; totales; cuadra con la cuenta de Clientes de los libros a esa fecha (y a hoy); ordenado por el mayor saldo; también proveedores (cuadra con Proveedores); un usuario limitado a su sucursal recibe solo lo suyo (sin saldos iniciales); permisos (vendedor no; cajero con cobros.ver_saldos sí; otra empresa no)
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  r    jsonb;
  cli  jsonb;
  s2   uuid;
  c2   uuid;
BEGIN
  -- Enero (preparar_enero): V_ENE_2 a CLI1, 45,000 del 12/01, vence 11/02; cobro de 20,000: queda 25,000.
  PERFORM pruebas.preparar_enero();
  -- Saldo inicial de CLI2: 30,000, factura del 10/12/2025 que vence el 20/12/2025.
  PERFORM public.registrar_saldo_inicial_cxc(e, jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-OLD-9',
    'fecha_documento', '2025-12-10', 'fecha_vencimiento', '2025-12-20', 'monto_centavos', 30000, 'fecha', '2026-01-01'), gen_random_uuid());
  -- Hoy: venta al crédito a CLI1 de 15,000 (10 tornillos), vence en 30 días: corriente.
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 10, 'credito', 'CLI1'), gen_random_uuid());

  -- ===== 1) Al 01/03/2026: V_ENE_2 lleva 18 días vencida (1-30); F-OLD-9 lleva 71 (61-90) =====
  r := public.antiguedad_saldos(e, '2026-03-01');
  PERFORM pruebas.afirmar((r->'totales'->>'saldo_centavos')::bigint = 55000 AND (r->'totales'->>'de_1_a_30_centavos')::bigint = 25000
    AND (r->'totales'->>'de_61_a_90_centavos')::bigint = 30000 AND (r->'totales'->>'corriente_centavos')::bigint = 0
    AND (r->'totales'->>'vencido_centavos')::bigint = 55000, 'al 01/03: ' || (r->'totales')::text);
  PERFORM pruebas.afirmar((r->>'cuadra')::boolean AND (r->>'saldo_libros_centavos')::bigint = 55000 AND r->>'cuenta_libros' = '1.1.02.01',
    'cuadra con Clientes al 01/03');
  -- Mayor saldo primero: CLI2 (30,000) y luego CLI1 (25,000).
  PERFORM pruebas.afirmar(r->'terceros'->0->>'tercero_id' = pruebas.id('CLI2')::text AND (r->'terceros'->1->>'saldo_centavos')::bigint = 25000,
    'orden por mayor saldo');
  PERFORM pruebas.afirmar((SELECT d->>'tramo' FROM jsonb_array_elements(r->'documentos') d WHERE d->>'numero_documento' = 'F-OLD-9') = 'de_61_a_90'
    AND (SELECT (d->>'dias_vencido')::int FROM jsonb_array_elements(r->'documentos') d WHERE d->>'numero_documento' = 'F-OLD-9') = 71, 'días del saldo inicial');
  -- Al 05/02/2026 V_ENE_2 todavía no vence: corriente. Al 11/02 (el día que vence) también.
  r := public.antiguedad_saldos(e, '2026-02-11');
  PERFORM pruebas.afirmar((SELECT (t->>'corriente_centavos')::bigint FROM jsonb_array_elements(r->'terceros') t WHERE t->>'tercero_id' = pruebas.id('CLI1')::text) = 25000,
    'el día que vence es corriente');
  r := public.antiguedad_saldos(e, '2026-02-12');
  PERFORM pruebas.afirmar((SELECT (t->>'de_1_a_30_centavos')::bigint FROM jsonb_array_elements(r->'terceros') t WHERE t->>'tercero_id' = pruebas.id('CLI1')::text) = 25000,
    'un día después: 1-30');
  -- Al 15/01 (antes del cobro del 20/01): V_ENE_2 completa 45,000, corriente.
  r := public.antiguedad_saldos(e, '2026-01-15');
  PERFORM pruebas.afirmar((r->'totales'->>'saldo_centavos')::bigint = 75000 AND (r->>'cuadra')::boolean, 'al 15/01: ' || (r->'totales')::text);

  -- ===== 2) Hoy: las de enero ya pasan de 90 días; la de hoy es corriente; cuadra =====
  r := public.antiguedad_saldos(e);
  PERFORM pruebas.afirmar((r->'totales'->>'corriente_centavos')::bigint = 15000 AND (r->'totales'->>'mas_de_90_centavos')::bigint = 55000
    AND (r->'totales'->>'saldo_centavos')::bigint = pruebas.saldo_libros(e, '1.1.02.01') AND (r->>'cuadra')::boolean, 'hoy: ' || (r->'totales')::text);

  -- ===== 3) Proveedores =====
  r := public.antiguedad_saldos(e, NULL, 'cxp');
  PERFORM pruebas.afirmar((r->>'cuadra')::boolean AND (r->'totales'->>'saldo_centavos')::bigint
    = pruebas.saldo_libros(e, r->>'cuenta_libros') AND (r->'totales'->>'saldo_centavos')::bigint > 0 AND jsonb_array_length(r->'terceros') = 1, 'proveedores: ' || (r->'totales')::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.antiguedad_saldos(%L, NULL, %L)', e, 'otra'), 'DATO_INVALIDO', 'tipo inválido');

  -- ===== 4) Permisos y sucursal =====
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.antiguedad_saldos(%L)', e), 'SIN_PERMISO', 'el vendedor no la ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.antiguedad_saldos(%L, NULL, %L)', e, 'cxp'), 'SIN_PERMISO', 'ni la de proveedores');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.antiguedad_saldos(%L)', e), 'NO_PERTENECE', 'otra empresa');
  -- Sucursal Norte con una venta al crédito de un servicio (23,000); el cajero queda solo en la Norte.
  PERFORM pruebas.como('dueno_a');
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  c2 := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  PERFORM public.registrar_venta(e, pruebas.venta('S1', 1, 'credito', 'CLI2') || jsonb_build_object('caja_id', c2), gen_random_uuid());
  PERFORM public.asignar_sucursales_usuario(e, pruebas.usuario('cajero_a'), ARRAY[s2], 'Cajero de la Norte');
  PERFORM pruebas.como('cajero_a');
  r := public.antiguedad_saldos(e);
  PERFORM pruebas.afirmar((r->'totales'->>'saldo_centavos')::bigint = 23000 AND (r->>'solo_mis_sucursales')::boolean AND r->'cuadra' = 'null'
    AND jsonb_array_length(r->'terceros') = 1, 'cajero de la Norte: solo lo suyo: ' || (r - 'documentos')::text);
  PERFORM pruebas.como('dueno_a');
  r := public.antiguedad_saldos(e);
  PERFORM pruebas.afirmar((r->'totales'->>'saldo_centavos')::bigint = 93000 AND (r->>'cuadra')::boolean, 'el dueño ve todo y cuadra');
END $$;
