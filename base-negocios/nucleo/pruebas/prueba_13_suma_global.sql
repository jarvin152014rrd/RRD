-- PRUEBA: en toda la base la suma del debe es igual a la del haber; un asiento descuadrado no entra ni a la fuerza
DO $$
DECLARE
  a  uuid := pruebas.empresa('A');
  b  uuid := pruebas.empresa('B');
  r  jsonb;
  v_detectado boolean := false;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_asiento(a, '2026-01-02', 'Capital inicial', pruebas.lineas('1.1.01.03', '3.1.01.01', 10000000), gen_random_uuid());
  PERFORM public.registrar_asiento(a, '2026-01-03', 'Compra de mercadería con ISV',
    '[{"cuenta":"1.1.03.01","debe":200000},{"cuenta":"1.1.04.01","debe":30000},{"cuenta":"2.1.01.01","haber":230000}]', gen_random_uuid());
  r := public.registrar_asiento(a, '2026-01-04', 'Venta con ISV',
    '[{"cuenta":"1.1.02.01","debe":345000},{"cuenta":"4.1.01.01","haber":300000},{"cuenta":"2.1.02.01","haber":45000}]', gen_random_uuid());
  PERFORM public.registrar_asiento(a, '2026-01-04', 'Costo de la venta', pruebas.lineas('5.1.01.01', '1.1.03.01', 150000), gen_random_uuid());
  PERFORM public.anular_asiento((r->>'asiento_id')::uuid, 'Factura emitida por error');
  PERFORM pruebas.como('dueno_b');
  PERFORM public.registrar_asiento(b, '2026-01-05', 'Venta B', pruebas.lineas('1.1.01.01', '4.1.01.01', 12345), gen_random_uuid());

  PERFORM pruebas.como('superusuario');
  -- Suma global.
  PERFORM pruebas.afirmar((SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea), 'suma global debe = haber');
  -- Cada asiento cuadra y coincide con su total.
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.asiento x JOIN public.asiento_linea l ON l.asiento_id = x.id
    GROUP BY x.id, x.total_centavos
    HAVING sum(l.debe_centavos) <> sum(l.haber_centavos) OR sum(l.debe_centavos) <> x.total_centavos), 'cada asiento cuadra');
  -- Saldos a mano: inventario 200000 - 150000 = 50000; clientes 345000 - 345000 = 0.
  PERFORM pruebas.afirmar(pruebas.saldo(a, '1.1.03.01') = 50000, 'inventario = 50000');
  PERFORM pruebas.afirmar(pruebas.saldo(a, '1.1.02.01') = 0, 'clientes = 0 tras anular la venta');
  PERFORM pruebas.afirmar(pruebas.saldo(a, '2.1.01.01') = 230000, 'proveedores = 230000');

  -- A la fuerza (superusuario, sin funciones): asiento descuadrado.
  BEGIN
    INSERT INTO public.asiento (empresa_id, sucursal_id, numero, fecha_contable, descripcion, id_operacion, total_centavos)
    SELECT a, s.id, 999999, '2026-01-06', 'A la fuerza', gen_random_uuid(), 100
    FROM public.sucursal s WHERE s.empresa_id = a;
    INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos)
    SELECT a, x.id, 1, c.id, 100 FROM public.asiento x, public.cuenta c
    WHERE x.numero = 999999 AND x.empresa_id = a AND c.empresa_id = a AND c.codigo = '1.1.01.01';
    INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, haber_centavos)
    SELECT a, x.id, 2, c.id, 90 FROM public.asiento x, public.cuenta c
    WHERE x.numero = 999999 AND x.empresa_id = a AND c.empresa_id = a AND c.codigo = '4.1.01.01';
    SET CONSTRAINTS ALL IMMEDIATE;   -- revisar ya, como al confirmar
  EXCEPTION WHEN OTHERS THEN
    v_detectado := SQLERRM LIKE 'NO_CUADRA%';
    IF NOT v_detectado THEN RAISE EXCEPTION 'FALLA: error inesperado: %', SQLERRM; END IF;
  END;
  PERFORM pruebas.afirmar(v_detectado, 'el asiento descuadrado a la fuerza debe ser rechazado');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento WHERE numero = 999999) = 0, 'no quedó guardado');

  -- A la fuerza: línea contra una cuenta de agrupación.
  PERFORM pruebas.debe_fallar(format(
    'INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos)
     SELECT %L, x.id, 99, c.id, 1 FROM public.asiento x, public.cuenta c
     WHERE x.empresa_id = %L AND x.numero = 1 AND c.empresa_id = %L AND c.codigo = %L', a, a, a, '1.1'),
    'CUENTA_INVALIDA', 'línea en cuenta de agrupación');
END $$;
