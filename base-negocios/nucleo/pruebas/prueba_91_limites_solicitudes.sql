-- PRUEBA: límites del contrato (usuarios, cajas, sucursales, bodegas): solo el proveedor los escribe; crear o reactivar más allá del límite da LIMITE_CONTRATO con el mensaje del plan; los desactivados y el usuario del proveedor no cuentan; bajar el límite no desactiva nada ni bloquea operar; mi_perfil trae límite y uso; solicitudes al proveedor (dueño y admin, aun con licencia vencida; el proveedor responde una vez)
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  s   uuid;
  v   jsonb;
  u5  uuid := gen_random_uuid();
  u6  uuid := gen_random_uuid();
  op  uuid := gen_random_uuid();
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (id, email) VALUES (u5, 'quinto@prueba.hn'), (u6, 'sexto@prueba.hn');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'inventario');
  s := (SELECT id FROM public.sucursal WHERE empresa_id = e AND codigo = '001');

  -- 1) Sin límites: todo como antes. Solo el proveedor (su llave) los pone.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'limites' = '{"cajas": {"uso": 1, "limite": null}, "bodegas": {"uso": 0, "limite": null},
    "usuarios": {"uso": 4, "limite": null}, "sucursales": {"uso": 1, "limite": null}}', 'sin límites: ' || (public.mi_perfil(e)->'limites')::text);
  PERFORM pruebas.debe_fallar(format('INSERT INTO public.limite_contrato (empresa_id, usuarios) VALUES (%L, 99)', e), '42501', 'el dueño no escribe límites');
  PERFORM pruebas.debe_fallar(format('SELECT public.aplicar_ficha(%L, %L, %L)', e, '{"limites": {"usuarios": 99}}', 'Me subo el plan'), '42501', 'ni con aplicar_ficha');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_ficha(%L, %L)', e, '{}'), '42501', 'el admin tampoco');
  PERFORM pruebas.como('service_role');
  v := public.aplicar_ficha(e, '{"limites": {"usuarios": 5, "cajas": 1, "sucursales": 1, "bodegas": 2}}', 'Contrato inicial');
  PERFORM pruebas.afirmar((v->>'aplicado')::boolean AND v->'limites'->'usuarios'->>'nuevo' = '5', 'límites puestos: ' || v::text);

  -- 2) Usuarios: 4 de 5 (dueño, admin, cajero, vendedor; el proveedor no cuenta).
  PERFORM pruebas.como('dueno_a');
  PERFORM public.agregar_usuario_empresa(e, 'quinto@prueba.hn', 'vendedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'sexto@prueba.hn', 'cajero'),
    'Llegaste al máximo de tu plan. Solicita una ampliación a tu proveedor.', 'sexto usuario');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'sexto@prueba.hn', 'cajero'), 'LIMITE_CONTRATO', 'clave del error');
  PERFORM public.desactivar_usuario_empresa(e, u5, 'Ya no trabaja aquí');
  PERFORM public.agregar_usuario_empresa(e, 'sexto@prueba.hn', 'cajero');          -- el desactivado no cuenta
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'quinto@prueba.hn', 'vendedor'),
    'LIMITE_CONTRATO', 'reactivar también cuenta');

  -- 3) Cajas, sucursales y bodegas.
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e, s, 'Caja 2', '002'), 'LIMITE_CONTRATO', 'segunda caja');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '002', 'Sucursal 2'), 'LIMITE_CONTRATO', 'segunda sucursal');
  PERFORM public.crear_bodega(e, s, 'B1', 'Bodega 1');
  PERFORM public.crear_bodega(e, s, 'B2', 'Bodega 2');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_bodega(%L, %L, %L, %L)', e, s, 'B3', 'Bodega 3'), 'LIMITE_CONTRATO', 'tercera bodega');

  -- 4) El proveedor baja el límite por debajo de lo que hay: nada se desactiva y se sigue operando.
  PERFORM pruebas.como('service_role');
  v := public.vista_previa_ficha(e, '{"limites": {"usuarios": 2, "bodegas": null}}');
  PERFORM pruebas.afirmar(v->'limites'->'usuarios'->>'aviso' LIKE '%nada se desactiva%' AND v->'limites'->'bodegas'->'nuevo' = 'null'
    AND NOT (v->'limites' ? 'cajas'), 'vista previa con aviso: ' || (v->'limites')::text);
  PERFORM public.aplicar_ficha(e, '{"limites": {"usuarios": 2, "bodegas": null}}', 'Contrato más chico');
  PERFORM pruebas.como('admin_a');
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Sigue operando', pruebas.lineas('1.1.01.01', '4.2.01.01', 100), gen_random_uuid());
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'limites'->'usuarios' = '{"uso": 5, "limite": 2}'
    AND public.mi_perfil(e)->'limites'->'bodegas' = '{"uso": 2, "limite": null}', 'mi_perfil: uso y límite');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.crear_bodega(e, s, 'B3', 'Bodega 3');                              -- bodegas ya sin límite
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.usuario_empresa WHERE empresa_id = e AND activo AND rol <> 'proveedor') = 5, 'nadie se desactivó');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE empresa_id = e AND tabla = 'limite_contrato' AND motivo = 'Contrato más chico'), 'bitácora');
  PERFORM pruebas.debe_fallar(format('DELETE FROM public.limite_contrato WHERE empresa_id = %L', e), 'no se borran', 'no se borran');

  -- 5) Solicitudes al proveedor.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_al_proveedor(%L, %L, %L, gen_random_uuid())', e, 'ampliacion', 'Otra caja'), 'SIN_PERMISO', 'cajero no pide');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.solicitud_proveedor) = 0, 'el cajero no las ve');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.solicitar_al_proveedor(%L, %L, %L, gen_random_uuid())', e, 'regalo', 'Otra caja'), 'DATO_INVALIDO', 'tipo');
  v := public.solicitar_al_proveedor(e, 'ampliacion', 'Necesitamos una segunda caja', op);
  PERFORM pruebas.afirmar(v->>'estado' = 'pendiente' AND (v->>'numero')::integer = 1, 'solicitud creada');
  PERFORM pruebas.afirmar(public.solicitar_al_proveedor(e, 'ampliacion', 'Necesitamos una segunda caja', op)->>'solicitud_id' = v->>'solicitud_id', 'reintento');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_asiento(%L, %L, %L, %L, %L)', e, '2026-01-10', 'x', pruebas.lineas('1.1.01.01', '4.2.01.01', 1), op),
    'ID_OPERACION_USADO', 'id de la solicitud en otra operación');
  PERFORM pruebas.como('superusuario');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) - 60 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.solicitar_al_proveedor(e, 'modulo', 'Queremos el módulo de compras', gen_random_uuid());
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.solicitud_proveedor WHERE estado = 'pendiente') = 2, 'el dueño pide aun con licencia vencida y las ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.responder_solicitud_proveedor(%L, %L, %L)', v->>'solicitud_id', 'atendida', 'Listo'), '42501', 'el dueño no responde');
  PERFORM pruebas.como('service_role');
  PERFORM public.responder_solicitud_proveedor((v->>'solicitud_id')::uuid, 'atendida', 'Caja 2 activada en su plan');
  PERFORM pruebas.debe_fallar(format('SELECT public.responder_solicitud_proveedor(%L, %L, %L)', v->>'solicitud_id', 'rechazada', 'Otra vez'),
    'PROHIBIDO', 'se responde una vez');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT estado || '/' || respuesta FROM public.solicitud_proveedor WHERE id = (v->>'solicitud_id')::uuid)
    = 'atendida/Caja 2 activada en su plan', 'respondida');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');
END $$;
