-- PRUEBA: un asiento correcto se guarda con número, usuario, hora y saldos bien calculados
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  r  jsonb;
  r2 jsonb;
  a  public.asiento;
BEGIN
  PERFORM pruebas.como('dueno_a');

  -- Venta al contado de L 100.00 + 15% ISV (L 15.00) = L 115.00
  -- Cálculo a mano: 10000 + 1500 = 11500 centavos.
  r := public.registrar_asiento(e, '2026-01-10', 'Venta de contado factura 001',
    '[{"cuenta":"1.1.01.01","debe":11500,"descripcion":"Cobro"},
      {"cuenta":"4.1.01.01","haber":10000},
      {"cuenta":"2.1.02.01","haber":1500}]', gen_random_uuid());

  PERFORM pruebas.afirmar((r->>'duplicado')::boolean = false, 'no debe ser duplicado');
  PERFORM pruebas.afirmar((r->>'numero')::bigint = 1, 'el primer asiento debe ser el número 1');

  SELECT * INTO a FROM public.asiento WHERE id = (r->>'asiento_id')::uuid;
  PERFORM pruebas.afirmar(a.total_centavos = 11500, 'total debe ser 11500');
  PERFORM pruebas.afirmar(a.creado_por = pruebas.usuario('dueno_a'), 'creado_por debe ser el dueño');
  PERFORM pruebas.afirmar(a.registrado_en IS NOT NULL, 'debe tener hora del servidor');
  PERFORM pruebas.afirmar(a.fecha_contable = '2026-01-10', 'fecha contable');
  PERFORM pruebas.afirmar(a.sucursal_id IS NOT NULL, 'debe tomar la sucursal principal');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.asiento_linea WHERE asiento_id = a.id) = 3, 'debe tener 3 líneas');

  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.01') = 11500, 'caja general = 11500');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '4.1.01.01') = 10000, 'ventas = 10000');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '2.1.02.01') = 1500,  'ISV por pagar = 1500');

  -- El admin también puede; el número sigue sin huecos.
  PERFORM pruebas.como('admin_a');
  r2 := public.registrar_asiento(e, '2026-01-11', 'Aporte de capital',
    pruebas.lineas('1.1.01.03', '3.1.01.01', 5000000), gen_random_uuid());
  PERFORM pruebas.afirmar((r2->>'numero')::bigint = 2, 'el segundo asiento debe ser el número 2');
  PERFORM pruebas.afirmar(pruebas.saldo(e, '1.1.01.03') = 5000000, 'bancos = 5,000,000 centavos (L 50,000.00)');

  -- Estado visible en la vista.
  PERFORM pruebas.afirmar((SELECT estado FROM public.v_asiento WHERE id = a.id) = 'vigente', 'estado vigente');
END $$;
