-- PRUEBA: (0.22.0) tienda y bodegas, datos fiscales: la primera bodega de la sucursal es la tienda y las ventas salen
-- de ahí; cambiar la tienda mueve las ventas; una bodega nueva solo guarda (código automático); no se deja sin tienda una
-- sucursal con cajas; editar pide motivo; el cajero no puede; al desactivar la tienda vende la siguiente; la empresa
-- nueva nace con "Tienda principal" (o sin ella con "bodega_inicial": false); el dueño cambia nombre legal y RTN (con
-- guiones), el admin no; RTN con CAI activo pide confirmar y luego desactiva el CAI; la factura vieja guarda su RTN;
-- la bitácora queda íntegra.
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  r      jsonb;
  v_b3   uuid;
  v_emp  uuid;
  v_fac  uuid;
  v_s001 uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(true);
  v_s001 := (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de tienda y bodegas');

  -- 1) B1 (la primera) es la tienda; B2 solo guarda. La venta sale de B1.
  PERFORM pruebas.afirmar((SELECT string_agg(codigo || ':' || vende, ',' ORDER BY codigo) FROM public.bodega WHERE empresa_id = e)
    = 'B1:true,B2:false', 'B1 tienda, B2 bodega');
  r := public.registrar_venta(e, pruebas.venta('P1', 2, 'efectivo'), gen_random_uuid());
  v_fac := (r->>'venta_id')::uuid;
  PERFORM pruebas.afirmar((SELECT bodega_id FROM public.venta WHERE id = v_fac) = pruebas.id('B1'), 'la venta sale de B1');

  -- 2) Compra a B2 y B2 pasa a ser la tienda: la venta sale de B2; B1 deja de vender.
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B2'),
    'numero_documento', 'F-B2-1', 'condicion', 'credito', 'fecha', public.hoy_local(e),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 5, 'costo_unitario', 1000))), gen_random_uuid());
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_bodega(%L, %L, %L)', e,
    jsonb_build_object('bodega_id', pruebas.id('B2'), 'vende', true), ''), 'FALTA_MOTIVO', 'editar pide motivo');
  r := public.guardar_bodega(e, jsonb_build_object('bodega_id', pruebas.id('B2'), 'vende', true), 'Ahora vendemos desde atrás');
  PERFORM pruebas.afirmar((r->>'vende')::boolean AND NOT (SELECT vende FROM public.bodega WHERE id = pruebas.id('B1')), 'B2 tienda, B1 no');
  r := public.registrar_venta(e, pruebas.venta('P1', 3, 'efectivo'), gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT bodega_id FROM public.venta WHERE id = (r->>'venta_id')::uuid) = pruebas.id('B2'), 'la venta sale de B2');
  PERFORM pruebas.afirmar((SELECT cantidad FROM public.inventario_saldo WHERE bodega_id = pruebas.id('B2') AND producto_id = pruebas.id('P1')) = 2,
    'en B2 quedan 2 tornillos');
  -- Sin tienda no: la sucursal tiene cajas.
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_bodega(%L, %L, %L)', e,
    jsonb_build_object('bodega_id', pruebas.id('B2'), 'vende', false), 'Dejar de vender aquí'), 'NO_PERMITIDO', 'sin tienda con cajas');
  r := public.guardar_bodega(e, jsonb_build_object('bodega_id', pruebas.id('B1'), 'vende', true, 'nombre', 'Mostrador'), 'Volvemos al mostrador');
  PERFORM pruebas.afirmar((r->>'vende')::boolean AND r->>'nombre' = 'Mostrador' AND r->>'codigo' = 'B1', 'B1 vuelve a ser la tienda, con nombre nuevo');

  -- 3) Bodega nueva: código automático, solo guarda; datos raros se rechazan.
  r := public.guardar_bodega(e, jsonb_build_object('sucursal_id', v_s001, 'nombre', 'Exhibidor'), NULL);
  v_b3 := (r->>'bodega_id')::uuid;
  PERFORM pruebas.afirmar(r->>'codigo' = 'B03' AND NOT (r->>'vende')::boolean AND (r->>'nueva')::boolean, 'nueva: B03, solo guarda: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_bodega(%L, %L, NULL)', e,
    jsonb_build_object('sucursal_id', v_s001, 'nombre', 'X')), 'DATO_INVALIDO', 'nombre corto');
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_bodega(%L, %L, NULL)', e,
    jsonb_build_object('sucursal_id', v_s001, 'nombre', 'Otra', 'codigo', 'Z9')), 'DATO_INVALIDO', 'campo desconocido');
  -- 4) Si la tienda se desactiva, vende la siguiente activa (por código).
  PERFORM public.guardar_bodega(e, jsonb_build_object('bodega_id', v_b3, 'vende', true), 'Probar el exhibidor');
  PERFORM public.desactivar_bodega(e, v_b3, 'Ya no usamos el exhibidor');
  PERFORM pruebas.afirmar((SELECT string_agg(codigo, ',') FROM public.bodega WHERE empresa_id = e AND activa AND vende) = 'B1',
    'al desactivar la tienda vende B1');
  -- Reactivar la que vendía no crea dos tiendas.
  PERFORM public.reactivar_bodega(e, v_b3, 'La volvemos a usar');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bodega WHERE empresa_id = e AND activa AND vende) = 1, 'una sola tienda al reactivar');
  -- El cajero no administra bodegas.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.guardar_bodega(%L, %L, NULL)', e,
    jsonb_build_object('sucursal_id', v_s001, 'nombre', 'Del cajero')), 'SIN_PERMISO', 'cajero no');

  -- 5) Empresa nueva: con su tienda, o sin ella si la ficha lo pide.
  PERFORM pruebas.como('service_role');
  v_emp := public.crear_empresa_inicial('{"nombre": "Tienda Nueva", "fecha_inicio": "2026-01-01", "dueno": {"correo": "sin_empresa@prueba.hn"}}');
  PERFORM pruebas.afirmar((SELECT string_agg(b.codigo || ':' || b.nombre || ':' || b.vende || ':' || s.codigo, ',') FROM public.bodega b
    JOIN public.sucursal s ON s.id = b.sucursal_id WHERE b.empresa_id = v_emp) = 'T001:Tienda principal:true:001', 'empresa nueva con su tienda');
  v_emp := public.crear_empresa_inicial('{"nombre": "Sin Tienda", "fecha_inicio": "2026-01-01", "dueno": {"correo": "sin_empresa@prueba.hn"}, "bodega_inicial": false}');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.bodega WHERE empresa_id = v_emp), 'sin tienda si la ficha lo pide');
  PERFORM pruebas.debe_fallar('SELECT public.crear_empresa_inicial(''{"nombre": "Mala", "fecha_inicio": "2026-01-01", "dueno": {"correo": "sin_empresa@prueba.hn"}, "bodega_inicial": "no"}'')',
    'FICHA_INVALIDA', 'bodega_inicial no booleano');

  -- 6) Datos fiscales: solo el dueño.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_datos_fiscales(%L, %L, %L)', e,
    '{"nombre": "Otra cosa"}', 'Cambio del admin'), 'SIN_PERMISO', 'el admin no');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_datos_fiscales(%L, %L, %L)', e,
    '{"nombre": "Otra cosa"}', 'no'), 'FALTA_MOTIVO', 'motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_datos_fiscales(%L, %L, %L)', e,
    '{"rtn": "0801-1999"}', 'RTN equivocado'), 'DATO_INVALIDO', 'RTN corto');
  r := public.configurar_datos_fiscales(e, '{"nombre": "  Ferretería El Martillo S. de R.L. "}', 'Nombre legal completo');
  PERFORM pruebas.afirmar(r->>'nombre' = 'Ferretería El Martillo S. de R.L.' AND r->>'rtn' = '08011999000001', 'nombre cambiado: ' || r::text);
  -- RTN nuevo con CAI activo: pide confirmar y no cambia nada.
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_datos_fiscales(%L, %L, %L)', e,
    '{"rtn": "0801-1999-000099"}', 'El RTN estaba mal escrito'), 'CAI_ACTIVO', 'RTN con CAI activo');
  PERFORM pruebas.afirmar((SELECT rtn FROM public.empresa WHERE id = e) = '08011999000001' AND
    (SELECT activo FROM public.cai_rango WHERE id = pruebas.id('CAI1')), 'no cambió nada');
  r := public.configurar_datos_fiscales(e, '{"rtn": "0801-1999-000099", "desactivar_cai": true}', 'El RTN estaba mal escrito');
  PERFORM pruebas.afirmar(r->>'rtn' = '08011999000099' AND (r->>'cai_desactivados')::integer = 1, 'RTN cambiado, 1 CAI desactivado: ' || r::text);
  PERFORM pruebas.afirmar(NOT (SELECT activo FROM public.cai_rango WHERE id = pruebas.id('CAI1')), 'el CAI quedó desactivado');
  PERFORM pruebas.afirmar((SELECT emisor_rtn FROM public.venta WHERE id = v_fac) = '08011999000001', 'la factura vieja guarda su RTN');
  PERFORM pruebas.afirmar(public.marca_empresa(e)->>'rtn' = '08011999000099', 'marca_empresa muestra el RTN nuevo');
  -- Sin RTN también se puede (negocio sin RTN); ya no hay CAI activo.
  r := public.configurar_datos_fiscales(e, '{"rtn": null}', 'Quitamos el RTN por ahora');
  PERFORM pruebas.afirmar(r->>'rtn' IS NULL, 'sin RTN');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
