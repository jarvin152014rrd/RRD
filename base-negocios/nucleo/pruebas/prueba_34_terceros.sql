-- PRUEBA: clientes y proveedores en una tabla: RTN, teléfono y correo validados, crédito con permiso y tope, desactivar sin borrar, historial en bitácora
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  op uuid := gen_random_uuid();
  t1 uuid; t2 uuid;
  r  jsonb;
  v  public.tercero;
BEGIN
  PERFORM pruebas.como('vendedor_a');
  -- Crear: RTN y teléfono con guiones se guardan solo con dígitos.
  r := public.crear_tercero(e, '{"nombre": "  Juan Pérez ", "es_cliente": true, "rtn": "0801-1990-123456",
                                 "telefono": "(504) 9999-8888", "correo": "Juan@Correo.HN"}', op);
  t1 := (r->>'tercero_id')::uuid;
  PERFORM pruebas.afirmar(NOT (r->>'duplicado')::boolean, 'creado');
  SELECT * INTO v FROM public.tercero WHERE id = t1;
  PERFORM pruebas.afirmar(v.nombre = 'Juan Pérez' AND v.rtn = '08011990123456' AND v.telefono = '50499998888'
    AND v.correo = 'juan@correo.hn' AND v.es_cliente AND NOT v.es_proveedor AND v.activo, 'datos normalizados');
  -- Reintento (sin internet): mismo id_operacion = mismo tercero.
  r := public.crear_tercero(e, '{"nombre": "Juan Pérez", "es_cliente": true}', op);
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean AND (r->>'tercero_id')::uuid = t1, 'reintento no duplica');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero WHERE empresa_id = e) = 1, 'uno solo');

  -- Datos malos.
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"rtn":"0801-1990"}'), 'RTN_INVALIDO', 'RTN corto');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"rtn":"0801199012345A"}'), 'RTN_INVALIDO', 'RTN con letra');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"rtn":"08011990123456"}'), 'YA_EXISTE', 'RTN repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"telefono":"123"}'), 'teléfono', 'teléfono corto');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"correo":"sin-arroba"}'), 'correo', 'correo malo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X"}'), 'cliente, proveedor', 'sin rol');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"   ","es_cliente":true}'), 'DATO_INVALIDO', 'nombre vacío');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"apodo":"x"}'), '"apodo"', 'campo desconocido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, NULL)', e, '{"nombre":"X","es_cliente":true}'), 'FALTA_ID_OPERACION', 'sin id_operacion');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"X","es_cliente":true,"plazo_dias":400}'), 'plazo_dias', 'plazo largo');

  -- Crédito: el vendedor no lo da; el admin hasta el tope del dueño; el dueño sin tope.
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', e, t1, '{"limite_credito_centavos": 100000}'), 'SIN_PERMISO', 'vendedor da crédito');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_tercero(%L, %L, gen_random_uuid())', e, '{"nombre":"Y","es_cliente":true,"plazo_dias":15}'), 'SIN_PERMISO', 'vendedor da plazo');
  PERFORM public.editar_tercero(e, t1, '{"telefono": "3333-4444", "direccion": "Col. Kennedy"}', 'Cambió de número');

  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', e, t1, '{"limite_credito_centavos": 1}'), 'TOPE_CREDITO', 'tope 0 por defecto');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"tope_credito_centavos": 500000}', 'Tope L 5,000 para el admin');
  PERFORM pruebas.como('admin_a');
  PERFORM public.editar_tercero(e, t1, '{"limite_credito_centavos": 500000, "plazo_dias": 30}', 'Cliente frecuente');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', e, t1, '{"limite_credito_centavos": 500001}'), 'TOPE_CREDITO', 'admin pasa el tope');
  PERFORM public.editar_tercero(e, t1, '{"limite_credito_centavos": 300000}', 'Bajar límite');   -- bajar sí
  PERFORM pruebas.como('dueno_a');
  PERFORM public.editar_tercero(e, t1, '{"limite_credito_centavos": 2000000}', 'El dueño autoriza L 20,000');
  -- El admin puede editar otros datos aunque el límite (del dueño) pase su tope.
  PERFORM pruebas.como('admin_a');
  PERFORM public.editar_tercero(e, t1, '{"es_proveedor": true}', 'También nos vende');
  SELECT * INTO v FROM public.tercero WHERE id = t1;
  PERFORM pruebas.afirmar(v.limite_credito_centavos = 2000000 AND v.plazo_dias = 30 AND v.es_proveedor
    AND v.telefono = '33334444' AND v.direccion = 'Col. Kennedy', 'ediciones guardadas');

  -- Historial en bitácora (antes / después / motivo / quién).
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'tercero' AND accion = 'UPDATE'
    AND registro_id = t1::text AND antes->>'limite_credito_centavos' = '300000' AND despues->>'limite_credito_centavos' = '2000000'
    AND motivo = 'El dueño autoriza L 20,000' AND usuario_id = pruebas.usuario('dueno_a')), 'historial del límite');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'tercero' AND registro_id = t1::text) = 6, 'alta + 5 cambios en bitácora');

  -- Desactivar: con permiso y motivo; nunca borrar.
  PERFORM pruebas.como('vendedor_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_tercero(%L, %L, %L)', e, t1, 'no compra'), 'SIN_PERMISO', 'vendedor desactiva');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_tercero(%L, %L, %L)', e, t1, 'no'), 'FALTA_MOTIVO', 'sin motivo');
  r := public.desactivar_tercero(e, t1, 'Cerró su negocio');
  PERFORM pruebas.afirmar(NOT (r->>'activo')::boolean AND NOT (r->>'ya_estaba')::boolean, 'desactivado');
  r := public.desactivar_tercero(e, t1, 'Cerró su negocio');
  PERFORM pruebas.afirmar((r->>'ya_estaba')::boolean, 'reintento seguro');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.tercero WHERE id = %L', t1), 'PROHIBIDO', 'borrar a la fuerza');
  PERFORM pruebas.debe_fallar(format('UPDATE public.tercero SET empresa_id = %L WHERE id = %L', pruebas.empresa('B'), t1), 'PROHIBIDO', 'mover de empresa');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.tercero WHERE id = %L', t1), '42501', 'usuario borra directo');

  -- Ligado por id: dos terceros con el mismo nombre son distintos.
  t2 := (public.crear_tercero(e, '{"nombre": "Juan Pérez", "es_cliente": true}', gen_random_uuid())->>'tercero_id')::uuid;
  PERFORM pruebas.afirmar(t2 <> t1 AND (SELECT count(*) FROM public.tercero WHERE nombre = 'Juan Pérez') = 2, 'mismo nombre, distinto id');

  -- Aislamiento: B no ve ni edita los de A.
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.tercero) = 0, 'B no ve terceros de A');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', e, t2, '{"nombre":"X"}'), 'NO_PERTENECE', 'B edita A');
  PERFORM pruebas.debe_fallar(format('SELECT public.editar_tercero(%L, %L, %L)', pruebas.empresa('B'), t2, '{"nombre":"X"}'), 'NO_EXISTE', 'B edita A desde B');
END $$;
