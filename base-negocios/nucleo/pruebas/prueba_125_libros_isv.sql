-- PRUEBA: libros de ISV por mes (cifras a mano): libro de ventas (facturas con CAI y RTN, exento, 15 % y 18 %, nota de crédito en negativo, anulada en el mismo mes en cero, anulada el mes siguiente en negativo en ese mes) y libro de compras (compras por tasa, gastos con factura 15 % y 18 %, gasto sin factura fuera, compra anulada el mes siguiente); totales = isv_mes (débito y crédito) y base de ventas = ventas netas de los libros; columnas para exportar; permisos
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v1   jsonb; v4 jsonb; v5 jsonb;
  dp   jsonb;
  s    jsonb;
  px   uuid;
  lv   jsonb;
  lc   jsonb;
  l    jsonb;
  isv  jsonb;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de libros de ISV');
  PERFORM public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tipo_documento', 'nota_credito',
    'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7', 'rango_desde', '001-001-03-00000001', 'rango_hasta', '001-001-03-00000100',
    'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')));

  -- VENTAS de enero (a mano, ISV por línea con mitades hacia arriba):
  --   V1 10/01 10 tornillos 15,000 = 13,043 + ISV15 1,957
  --   V2 12/01 1 galón a CLI1 (RTN 08011999000222) 45,000 = 38,136 + ISV18 6,864
  --   V3 13/01 2 lb de arroz exento = 4,400
  --   V4 14/01 2 tornillos 3,000 = 2,609 + 391, anulada el 16/01 (mismo mes: fila en cero "ANULADA")
  --   NC 20/01 devolución de 1 tornillo de V1: 1/10 de 13,043 = 1,304 y 1/10 de 1,957 = 196 (1,500), en negativo
  --   V5 30/01 4 tornillos 6,000 = 5,217 + 783, anulada el 03/02 (en febrero va en negativo)
  v1 := public.registrar_venta(e, pruebas.venta('P1', 10) || '{"fecha": "2026-01-10"}', gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1') || '{"fecha": "2026-01-12"}', gen_random_uuid());
  PERFORM public.registrar_venta(e, pruebas.venta('P2', 2) || '{"fecha": "2026-01-13"}', gen_random_uuid());
  v4 := public.registrar_venta(e, pruebas.venta('P1', 2) || '{"fecha": "2026-01-14"}', gen_random_uuid());
  s := public.solicitar_anulacion_venta((v4->>'venta_id')::uuid, 'Factura a nombre equivocado', gen_random_uuid());
  PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Revisado por el dueño', gen_random_uuid(), '2026-01-16');
  dp := public.registrar_devolucion((v1->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'motivo', 'Tornillo dañado', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1'), 'fecha', '2026-01-20'), gen_random_uuid());
  IF dp->>'estado' = 'pendiente_aprobacion' THEN
    PERFORM public.resolver_aprobacion((dp->>'aprobacion_id')::uuid, true, 'Aprobada por el dueño', gen_random_uuid(), '2026-01-20');
  END IF;
  v5 := public.registrar_venta(e, pruebas.venta('P1', 4) || '{"fecha": "2026-01-30"}', gen_random_uuid());
  s := public.solicitar_anulacion_venta((v5->>'venta_id')::uuid, 'Cliente desistió de la compra', gen_random_uuid());
  PERFORM public.resolver_aprobacion((s->>'aprobacion_id')::uuid, true, 'Revisado por el dueño', gen_random_uuid(), '2026-02-03');

  -- COMPRAS de enero (a mano):
  --   F-INI-1 05/01 (preparar_ventas): 100,000 al 15 % (ISV 15,000) + 75,000 exento + 300,000 al 18 % (ISV 54,000)
  --   gasto 22/01 con factura FAC-001-55: 11,500 con ISV15 = 10,000 + 1,500
  --   gasto 23/01 SIN factura: 2,000 (no va al libro)
  --   gasto 24/01 con factura FAC-002-9: 11,800 con ISV de 1,800 = 10,000 al 18 % (la tasa se reconoce: 10,000 x 18 % = 1,800)
  --   PX-9 26/01 a PROV2: 10 tornillos a 1,000 = 10,000 + ISV15 1,500, anulada el 05/02 (en febrero va en negativo)
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 11500, 'impuesto', 'ISV15', 'descripcion', 'ENEE enero', 'fecha', '2026-01-22',
    'documento', jsonb_build_object('numero', 'FAC-001-55', 'rtn', '08011999000333', 'cai', 'B1B2B3-C4C5C6-D7D8D9-E1E2E3-F4F5F6-01')), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 2000, 'descripcion', 'Fotocopias', 'fecha', '2026-01-23'), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_PAPEL'),
    'monto_centavos', 11800, 'isv_centavos', 1800, 'descripcion', 'Tóner', 'fecha', '2026-01-24',
    'documento', jsonb_build_object('numero', 'FAC-002-9', 'rtn', '08011999000444')), gen_random_uuid());
  px := (public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'bodega_id', pruebas.id('B1'),
    'numero_documento', 'PX-9', 'fecha', '2026-01-26', 'condicion', 'credito', 'fecha_vencimiento', '2026-02-26',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'costo_unitario', 1000))),
    gen_random_uuid())->>'compra_id')::uuid;
  PERFORM public.anular_compra(px, 'Factura duplicada del proveedor', gen_random_uuid(), '2026-02-05');

  -- 1) Libro de ventas de enero: 6 filas (V1, V2, V3, V4 en cero, NC, V5).
  --    15 %: 13,043 + 5,217 - 1,304 = 16,956 (ISV 1,957 + 783 - 196 = 2,544); 18 %: 38,136 (6,864); exento 4,400.
  --    ISV = 2,544 + 6,864 = 9,408; base = 16,956 + 38,136 + 4,400 = 59,492; total 68,900.
  lv := public.libro_ventas(e, 2026, 1);
  PERFORM pruebas.afirmar((lv->>'cantidad_filas')::integer = 6, 'filas de ventas: ' || (lv->'filas')::text);
  PERFORM pruebas.afirmar((lv->'totales'->>'base_15_centavos')::bigint = 16956 AND (lv->'totales'->>'isv_15_centavos')::bigint = 2544
    AND (lv->'totales'->>'base_18_centavos')::bigint = 38136 AND (lv->'totales'->>'isv_18_centavos')::bigint = 6864
    AND (lv->'totales'->>'exento_centavos')::bigint = 4400 AND (lv->'totales'->>'isv_centavos')::bigint = 9408
    AND (lv->'totales'->>'total_centavos')::bigint = 68900, 'totales de ventas: ' || (lv->'totales')::text);
  isv := public.isv_mes(e, 2026, 1);
  PERFORM pruebas.afirmar((lv->'cuadre'->>'cuadra')::boolean AND (isv->>'debito_fiscal_centavos')::bigint = 9408
    AND (lv->'cuadre'->>'ventas_netas_contabilidad_centavos')::bigint = 59492, 'cuadra con isv_mes y las ventas netas: ' || (lv->'cuadre')::text);
  SELECT x INTO l FROM jsonb_array_elements(lv->'filas') x WHERE x->>'numero_documento' = v4->>'numero_documento';
  PERFORM pruebas.afirmar(l->>'estado' = 'ANULADA' AND (l->>'total_centavos')::bigint = 0 AND l->>'cai' = 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6',
    'anulada en el mismo mes: en cero con su número y CAI: ' || l::text);
  SELECT x INTO l FROM jsonb_array_elements(lv->'filas') x WHERE x->>'tipo_documento' = 'nota_credito';
  PERFORM pruebas.afirmar((l->>'base_15_centavos')::bigint = -1304 AND (l->>'isv_15_centavos')::bigint = -196
    AND l->>'documento_referencia' = v1->>'numero_documento' AND l->>'numero_documento' LIKE '001-001-03-%'
    AND l->>'cai' = 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D7', 'nota de crédito en negativo: ' || l::text);
  SELECT x INTO l FROM jsonb_array_elements(lv->'filas') x WHERE (x->>'base_18_centavos')::bigint > 0;
  PERFORM pruebas.afirmar(l->>'rtn' = '08011999000222' AND l->>'nombre' = 'Constructora Ríos' AND l->>'fecha' = '2026-01-12', 'RTN y nombre del cliente');
  PERFORM pruebas.afirmar(jsonb_array_length(lv->'columnas') = 18 AND lv->'columnas'->2->>'titulo' = 'Número de documento', 'columnas para exportar');

  -- 2) Febrero: solo la anulación de V5 en negativo (-5,217 / -783) = débito de febrero.
  lv := public.libro_ventas(e, 2026, 2);
  PERFORM pruebas.afirmar((lv->>'cantidad_filas')::integer = 1 AND lv->'filas'->0->>'tipo_documento' = 'anulacion'
    AND (lv->'totales'->>'base_15_centavos')::bigint = -5217 AND (lv->'totales'->>'isv_centavos')::bigint = -783
    AND (lv->'cuadre'->>'cuadra')::boolean AND (public.isv_mes(e, 2026, 2)->>'debito_fiscal_centavos')::bigint = -783, 'ventas de febrero: ' || lv::text);

  -- 3) Libro de compras de enero: 4 filas (F-INI-1, FAC-001-55, FAC-002-9, PX-9).
  --    15 %: 100,000 + 10,000 + 10,000 = 120,000 (ISV 15,000 + 1,500 + 1,500 = 18,000); 18 %: 300,000 + 10,000 = 310,000
  --    (ISV 54,000 + 1,800 = 55,800); exento 75,000; ISV total 73,800.
  lc := public.libro_compras(e, 2026, 1);
  PERFORM pruebas.afirmar((lc->>'cantidad_filas')::integer = 4, 'filas de compras: ' || (lc->'filas')::text);
  PERFORM pruebas.afirmar((lc->'totales'->>'base_15_centavos')::bigint = 120000 AND (lc->'totales'->>'isv_15_centavos')::bigint = 18000
    AND (lc->'totales'->>'base_18_centavos')::bigint = 310000 AND (lc->'totales'->>'isv_18_centavos')::bigint = 55800
    AND (lc->'totales'->>'exento_centavos')::bigint = 75000 AND (lc->'totales'->>'isv_centavos')::bigint = 73800,
    'totales de compras: ' || (lc->'totales')::text);
  PERFORM pruebas.afirmar((lc->'cuadre'->>'cuadra')::boolean AND (isv->>'credito_fiscal_centavos')::bigint = 73800, 'compras cuadran con isv_mes');
  SELECT x INTO l FROM jsonb_array_elements(lc->'filas') x WHERE x->>'numero_documento' = 'FAC-001-55';
  PERFORM pruebas.afirmar(l->>'rtn' = '08011999000333' AND l->>'cai' = 'B1B2B3-C4C5C6-D7D8D9-E1E2E3-F4F5F6-01' AND l->>'nombre' = 'ENEE enero'
    AND (l->>'base_15_centavos')::bigint = 10000, 'gasto con factura: ' || l::text);
  SELECT x INTO l FROM jsonb_array_elements(lc->'filas') x WHERE x->>'numero_documento' = 'FAC-002-9';
  PERFORM pruebas.afirmar((l->>'base_18_centavos')::bigint = 10000 AND (l->>'isv_18_centavos')::bigint = 1800, 'gasto al 18 %: ' || l::text);
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(lc->'filas') x WHERE x->>'nombre' = 'Fotocopias'), 'gasto sin factura fuera');
  -- Febrero: la anulación de PX-9 en negativo.
  lc := public.libro_compras(e, 2026, 2);
  PERFORM pruebas.afirmar((lc->>'cantidad_filas')::integer = 1 AND (lc->'totales'->>'isv_centavos')::bigint = -1500 AND (lc->'cuadre'->>'cuadra')::boolean,
    'compras de febrero: ' || lc::text);

  -- 4) Los dos juntos: ISV a pagar de enero = 9,408 - 73,800 = -64,392 (crédito a favor) = a_pagar de isv_mes.
  l := public.libros_isv(e, 2026, 1);
  PERFORM pruebas.afirmar((l->>'isv_a_pagar_centavos')::bigint = -64392 AND (isv->>'a_pagar_centavos')::bigint = -64392 AND (l->>'cuadra')::boolean,
    'libros juntos: ' || (l->>'isv_a_pagar_centavos'));

  -- 5) Permisos: el contador los lee; el cajero no.
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((public.libros_isv(e, 2026, 1)->>'cuadra')::boolean, 'el contador lee los libros');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.libro_ventas(%L, 2026, 1)', e), 'SIN_PERMISO', 'el cajero no lee los libros');
END $$;
