-- PRUEBA: (0.9.1, importante 3) devoluciones en partes: base, ISV y costo por cantidad ACUMULADA (lo que corresponde a todo lo devuelto menos lo ya devuelto). 10 kg a L 11.50 + ISV devueltos de 0.5 en 0.5: cada nota lleva 86 u 87 de ISV, a las 2 y a las 4 lo acumulado es lo de 1 kg y 2 kg, y al final todo cuadra sin perder centavos
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  v    jsonb;
  d    jsonb;
  k    integer;
  isv  bigint := 0;
  tot  bigint := 0;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de devoluciones parciales');
  -- Queso por kilo: L 11.50 SIN ISV (15 %), con fracciones; compra de 20 kg a L 8.00 (costo).
  PERFORM pruebas.guardar('Q', (public.crear_producto(e, jsonb_build_object('codigo', 'QUE-001', 'nombre', 'Queso',
    'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'KG'), 'permite_fracciones', true,
    'precio_venta_centavos', 1150, 'precio_incluye_isv', false), gen_random_uuid())->>'producto_id')::uuid);
  PERFORM public.registrar_compra(e, pruebas.compra('PROV1', 'B1', 'F-QUE-1', public.hoy_local(e), 'credito', 'Q', 20, 800), gen_random_uuid());

  -- Venta: 10 kg x 11.50 = 11,500 sin ISV; ISV round(1,725.0) = 1,725; total 13,225; costo 8,000.
  v := public.registrar_venta(e, pruebas.venta('Q', 10), gen_random_uuid());
  PERFORM pruebas.afirmar((v->>'total_centavos')::bigint = 13225 AND (v->>'impuesto_centavos')::bigint = 1725, 'venta 13,225: ' || v::text);

  -- 20 devoluciones de 0.5 kg. Acumulado tras k notas: total round(13,225 x k / 20), base 575 x k, ISV = total - base.
  --   k=1: 661 (661.25) - 575 = 86      k=2: 1,323 (1,322.5) - 1,150 = 173 (la 2a lleva 87)
  --   k=3: 1,984 (1,983.75) - 1,725 = 259   k=4: 2,645 - 2,300 = 345     k=20: 13,225 - 11,500 = 1,725
  -- (Antes, cada nota llevaba 661 = 575 + 86 y la última 666 = 575 + 91: a las 4, 2,644 y 344.)
  FOR k IN 1..20 LOOP
    d := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":0.5}]'::jsonb,
           'motivo', 'Devuelve medio kilo', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
    isv := isv + (d->>'impuesto_centavos')::bigint;
    tot := tot + (d->>'total_centavos')::bigint;
    PERFORM pruebas.afirmar((d->>'impuesto_centavos')::bigint IN (86, 87) AND (d->>'subtotal_centavos')::bigint = 575,
      'nota ' || k || ': base 575 e ISV 86 u 87: ' || d::text);
    IF k = 2 THEN
      PERFORM pruebas.afirmar(isv = 173 AND tot = 1323, 'a 1 kg: total 1,323, ISV 173 (no 172)');
    ELSIF k = 4 THEN
      PERFORM pruebas.afirmar(isv = 345 AND tot = 2645, 'a 2 kg: total 2,645, ISV 345 (no 344)');
    END IF;
  END LOOP;
  PERFORM pruebas.afirmar(isv = 1725 AND tot = 13225, 'todo devuelto: 13,225 con 1,725 de ISV');

  -- Libros: ISV por pagar en 0; devoluciones 11,500; costo 8,000 de vuelta al inventario; caja en 0.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '2.1.02.01') = 0 AND pruebas.saldo_libros(e, '4.1.01.04') = 11500
    AND (SELECT sum(costo_centavos) FROM public.devolucion WHERE venta_id = (v->>'venta_id')::uuid) = 8000
    AND (SELECT min(costo_centavos) = 400 AND max(costo_centavos) = 400 FROM public.devolucion WHERE venta_id = (v->>'venta_id')::uuid)
    AND pruebas.existencia('B1', 'Q') = 20 AND pruebas.dinero('CAJA1') = 0
    AND (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = e) = pruebas.saldo_libros(e, '1.1.03.01'),
    'ISV, ingreso, costo, kardex y caja cuadran');
END $$;
