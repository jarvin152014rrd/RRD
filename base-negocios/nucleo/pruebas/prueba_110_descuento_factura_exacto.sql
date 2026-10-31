-- PRUEBA: (0.9.1, menor) descuento de factura en monto: exacto al centavo también con precios SIN ISV (antes podía salir 1 centavo de más o de menos por línea); se ajusta la última línea que puede dar el monto exacto
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  v  jsonb;
  r  jsonb;
  m  integer;
  i  integer;
  p  integer[] := ARRAY[1000, 333, 777];
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de descuento exacto');
  -- Tres servicios con precio SIN ISV (15 %): 10.00, 3.33 y 7.77.
  FOR i IN 1..3 LOOP
    PERFORM pruebas.guardar('X' || i, (public.crear_producto(e, jsonb_build_object('codigo', 'X' || i, 'nombre', 'Servicio ' || i, 'tipo', 'servicio',
      'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'SERV'), 'precio_venta_centavos', p[i],
      'precio_incluye_isv', false), gen_random_uuid())->>'producto_id')::uuid);
  END LOOP;

  -- Con ISV: 1,000 + 150 = 1,150; 333 + round(49.95) = 383; 777 + round(116.55) = 894. Total 2,427. Descuento de factura: 107.
  -- Reparto por el total con ISV: 107 x 1,150 / 2,427 = 50.70; x 383 = 16.88; x 894 = 39.41 -> 50 + 16 + 39 = 105 y los 2
  -- que faltan a los restos mayores: 51, 17, 39. Sin ISV: round(51/1.15) = 44, round(17/1.15) = 15, round(39/1.15) = 34.
  -- Con el ISV recalculado: 956 + 143 = 1,099 (51); 318 + 48 = 366 (17); 743 + 111 = 854 (40) -> 108, uno de más.
  -- Ajuste: la última línea no puede dar 39 (con 33 da 38, con 34 da 40); la del medio con 14: 319 + round(47.85) = 367 (16).
  -- Descuento 51 + 16 + 40 = 107 exacto. Total 2,427 - 107 = 2,320.
  v := public.registrar_venta(e, jsonb_build_object('lineas', jsonb_build_array(
         jsonb_build_object('producto_id', pruebas.id('X1'), 'cantidad', 1), jsonb_build_object('producto_id', pruebas.id('X2'), 'cantidad', 1),
         jsonb_build_object('producto_id', pruebas.id('X3'), 'cantidad', 1)),
         'descuento_factura', '{"monto_centavos": 107}'::jsonb, 'pagos', '[{"forma":"efectivo"}]'::jsonb), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 2320, 'total 2,320: ' || v::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT array_agg(total_centavos ORDER BY linea) FROM public.venta_linea WHERE venta_id = (v->>'venta_id')::uuid)
    = ARRAY[1099, 367, 854]::bigint[], 'líneas 1,099 / 367 / 854');

  -- Cualquier monto de 1.00 a 4.00: el descuento con ISV es exactamente el pedido.
  FOR m IN 100..400 LOOP
    r := interno.calcular_venta(e, public.hoy_local(e), jsonb_build_array(
      jsonb_build_object('producto_id', pruebas.id('X1'), 'cantidad', 1), jsonb_build_object('producto_id', pruebas.id('X2'), 'cantidad', 1),
      jsonb_build_object('producto_id', pruebas.id('X3'), 'cantidad', 1)), jsonb_build_object('monto_centavos', m));
    PERFORM pruebas.afirmar(2427 - (r->>'total_centavos')::bigint = m, 'monto ' || m || ': se descontó ' || (2427 - (r->>'total_centavos')::bigint));
  END LOOP;
END $$;
