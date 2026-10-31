-- PRUEBA: perfiles por tamaño (pequeno, mediano, grande) como datos: vista previa sin cambiar nada; aplicar solo el dueño, con motivo y bitácora; nunca borra datos ni activa o desactiva módulos; topes del perfil (admin L 5,000); crear_empresa_inicial con "perfil" en la ficha
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  p      jsonb;
  v      jsonb;
  r      jsonb;
  n_cta  bigint;
  n_rp   bigint;
  n_mov  bigint;
  e2     uuid;
  e3     uuid;
  e4     uuid;
BEGIN
  -- 1) Los tres perfiles, en orden, con lo que traen.
  PERFORM pruebas.como('cajero_a');
  p := public.perfiles_negocio();
  PERFORM pruebas.afirmar((SELECT string_agg(x->>'perfil', ',') FROM jsonb_array_elements(p) x) = 'pequeno,mediano,grande', 'tres perfiles');
  PERFORM pruebas.afirmar(p->0->'modulos_sugeridos' = '["contabilidad", "dinero", "inventario", "ventas"]'
    AND NOT (p->0->>'turnos_obligatorios')::boolean AND NOT (p->0->>'contabilidad_visible')::boolean
    AND NOT (p->0->>'doble_aprobacion')::boolean, 'pequeño: ' || (p->0)::text);
  PERFORM pruebas.afirmar((p->1->>'turnos_obligatorios')::boolean AND (p->1->>'contabilidad_visible')::boolean
    AND NOT (p->1->>'doble_aprobacion')::boolean AND p->1->'modulos_sugeridos' ? 'compras', 'mediano');
  PERFORM pruebas.afirmar((p->2->>'doble_aprobacion')::boolean AND (p->2->>'turnos_obligatorios')::boolean, 'grande');
  PERFORM pruebas.afirmar((SELECT bool_and((x->'topes'->0->>'sin_aprobacion_centavos')::bigint = 500000
                                           AND (x->'topes'->0->>'aprueba_hasta_centavos')::bigint = 500000 AND x->'topes'->0->>'rol' = 'admin')
                             FROM jsonb_array_elements(p) x), 'tope del admin L 5,000 en los tres');

  -- 2) Vista previa: solo el dueño; NO cambia nada.
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_perfil(%L, %L)', e, 'pequeno'), 'SIN_PERMISO', 'cajero no ve la vista previa');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_perfil(%L, %L)', e, 'pequeno'), 'SIN_PERMISO', 'admin no ve la vista previa');
  PERFORM pruebas.debe_fallar(format('SELECT public.aplicar_perfil(%L, %L, %L)', e, 'pequeno', 'Somos pequeños'), 'SIN_PERMISO', 'admin no aplica');
  PERFORM pruebas.preparar_dinero();                         -- dueño; módulo dinero activo, BAC 1,000,000
  PERFORM public.configurar_tope_rol(e, 'admin', 'gasto', 300000, 300000, 'Tope más bajo');
  PERFORM pruebas.debe_fallar(format('SELECT public.vista_previa_perfil(%L, %L)', e, 'enorme'), 'PERFIL_INVALIDO', 'perfil inventado');
  v := public.vista_previa_perfil(e, 'pequeno');
  PERFORM pruebas.afirmar(v->'cambios' = '[{"campo": "perfil", "nuevo": "pequeno", "actual": null},
      {"campo": "turnos_obligatorios", "nuevo": false, "actual": true},
      {"campo": "contabilidad_visible", "nuevo": false, "actual": true},
      {"campo": "vendedor_cobra", "nuevo": true, "actual": false}]'::jsonb, 'cambios: ' || (v->'cambios')::text);
  PERFORM pruebas.afirmar(v->'topes' = '[{"rol": "admin", "tipo": "gasto", "actual_sin_aprobacion_centavos": 300000,
      "nuevo_sin_aprobacion_centavos": 500000, "actual_aprueba_hasta_centavos": 300000, "nuevo_aprueba_hasta_centavos": 500000}]'::jsonb,
    'topes: ' || (v->'topes')::text);
  PERFORM pruebas.afirmar(v->'modulos'->'activos' = '["contabilidad", "dinero"]' AND v->'modulos'->'faltan' = '["inventario", "ventas"]'
    AND v->'modulos'->'activos_no_sugeridos' = '[]', 'módulos: ' || (v->'modulos')::text);
  PERFORM pruebas.afirmar((v->>'hay_cambios')::boolean AND jsonb_array_length(v->'avisos') = 4, 'avisos: ' || (v->'avisos')::text);
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT perfil IS NULL AND turnos_obligatorios AND contabilidad_visible FROM public.empresa WHERE id = e)
    AND (SELECT sin_aprobacion_centavos FROM public.tope_rol WHERE empresa_id = e AND rol = 'admin') = 300000, 'la vista previa no cambió nada');

  -- 3) Aplicar: con motivo; cambia lo de la vista previa; módulos y datos intactos; bitácora.
  SELECT count(*) INTO n_cta FROM public.cuenta WHERE empresa_id = e;
  SELECT count(*) INTO n_rp FROM public.rol_permiso WHERE empresa_id = e;
  SELECT count(*) INTO n_mov FROM public.dinero_movimiento WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.aplicar_perfil(%L, %L, %L)', e, 'pequeno', ''), 'FALTA_MOTIVO', 'sin motivo');
  r := public.aplicar_perfil(e, 'pequeno', 'Somos un negocio pequeño');
  PERFORM pruebas.afirmar((r->>'aplicado')::boolean AND r->'cambios' = v->'cambios', 'aplica lo de la vista previa');
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'empresa' @> '{"perfil": "pequeno", "turnos_obligatorios": false, "contabilidad_visible": false, "doble_aprobacion": false}',
    'mi_perfil con el perfil: ' || (public.mi_perfil(e)->'empresa')::text);
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'modulos' = '["contabilidad", "dinero"]', 'el perfil no activa módulos');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT sin_aprobacion_centavos || '/' || aprueba_hasta_centavos FROM public.tope_rol WHERE empresa_id = e AND rol = 'admin')
    = '500000/500000', 'tope del admin L 5,000');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta WHERE empresa_id = e) = n_cta
    AND (SELECT count(*) FROM public.rol_permiso WHERE empresa_id = e) = n_rp
    AND (SELECT count(*) FROM public.dinero_movimiento WHERE empresa_id = e) = n_mov
    AND pruebas.dinero('BANCO') = 1000000, 'no se borró ni se movió nada');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE empresa_id = e AND motivo = 'Perfil pequeno: Somos un negocio pequeño'
                             AND tabla IN ('empresa', 'tope_rol')) = 2, 'bitácora: empresa y tope con el motivo');

  -- 4) Repetir: sin cambios. Pasar a "grande": módulos activos que no sugiere se quedan.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(NOT (public.vista_previa_perfil(e, 'pequeno')->>'hay_cambios')::boolean, 'mismo perfil: sin cambios');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'inventario'), (e, 'compras');  -- 0.8.0: compras necesita inventario
  PERFORM pruebas.como('dueno_a');
  v := public.vista_previa_perfil(e, 'pequeno');
  PERFORM pruebas.afirmar(v->'modulos'->'activos_no_sugeridos' = '["compras"]' AND NOT (v->>'hay_cambios')::boolean, 'compras no se desactiva');
  r := public.aplicar_perfil(e, 'grande', 'Abrimos otra sucursal');
  PERFORM pruebas.afirmar(r->'cambios' @> '[{"campo": "doble_aprobacion", "nuevo": true}]' AND r->'topes' = '[]', 'grande: ' || (r->'cambios')::text);
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'empresa' @> '{"perfil": "grande", "turnos_obligatorios": true, "contabilidad_visible": true, "doble_aprobacion": true}', 'flags de grande');
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'modulos' = '["compras", "contabilidad", "dinero", "inventario"]', 'módulos intactos');
  -- Después cada cosa se cambia sola (el perfil solo es el punto de partida).
  PERFORM public.configurar_empresa(e, '{"contabilidad_visible": false}', 'Esconder la contabilidad');
  PERFORM pruebas.afirmar(NOT (public.mi_perfil(e)->'empresa'->>'contabilidad_visible')::boolean, 'cambio individual');

  -- 5) crear_empresa_inicial con perfil (la usa el proveedor con service_role).
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (id, email) VALUES ('d0000000-0000-0000-0000-000000000001', 'perfil1@prueba.hn'),
    ('d0000000-0000-0000-0000-000000000002', 'perfil2@prueba.hn'), ('d0000000-0000-0000-0000-000000000003', 'perfil3@prueba.hn');
  PERFORM pruebas.como('service_role');
  e2 := public.crear_empresa_inicial('{"nombre": "Pulpería Pequeña", "fecha_inicio": "2026-01-01", "perfil": "pequeno",
    "dueno": {"correo": "perfil1@prueba.hn"}}');
  e3 := public.crear_empresa_inicial('{"nombre": "Distribuidora Grande", "fecha_inicio": "2026-01-01", "perfil": "grande",
    "modulos": ["contabilidad", "inventario", "compras"], "dueno": {"correo": "perfil2@prueba.hn"}}');
  e4 := public.crear_empresa_inicial('{"nombre": "Sin perfil", "fecha_inicio": "2026-01-01", "perfil": null,
    "dueno": {"correo": "perfil3@prueba.hn"}}');
  PERFORM pruebas.debe_fallar('SELECT public.crear_empresa_inicial(''{"nombre": "X", "fecha_inicio": "2026-01-01", "perfil": "enorme", "dueno": {"correo": "perfil1@prueba.hn"}}'')',
    'FICHA_INVALIDA', 'perfil inventado en la ficha');
  PERFORM pruebas.debe_fallar('SELECT public.crear_empresa_inicial(''{"nombre": "X", "fecha_inicio": "2026-01-01", "perfiles": "grande", "dueno": {"correo": "perfil1@prueba.hn"}}'')',
    'no se reconoce', 'campo mal escrito');
  PERFORM pruebas.debe_fallar('SELECT public.crear_empresa_inicial(''{"nombre": "X", "fecha_inicio": "2026-01-01", "modulos": ["compras"], "dueno": {"correo": "perfil1@prueba.hn"}}'')',
    'MODULO_DEPENDENCIA', '0.8.0: compras sin inventario en la ficha');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT string_agg(modulo, ',' ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = e2)
    = 'contabilidad,dinero,inventario,ventas', 'sin "modulos" en la ficha: los del perfil');
  PERFORM pruebas.afirmar((SELECT perfil = 'pequeno' AND NOT turnos_obligatorios AND NOT contabilidad_visible AND NOT doble_aprobacion
                             FROM public.empresa WHERE id = e2), 'empresa pequeña');
  PERFORM pruebas.afirmar((SELECT string_agg(modulo, ',' ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = e3)
    = 'compras,contabilidad,inventario', 'con "modulos" en la ficha: los de la ficha');
  PERFORM pruebas.afirmar((SELECT perfil = 'grande' AND turnos_obligatorios AND contabilidad_visible AND doble_aprobacion
                             FROM public.empresa WHERE id = e3), 'empresa grande');
  PERFORM pruebas.afirmar((SELECT perfil IS NULL AND turnos_obligatorios AND contabilidad_visible AND NOT doble_aprobacion
                             FROM public.empresa WHERE id = e4)
    AND (SELECT string_agg(modulo, ',') FROM public.modulo_activo WHERE empresa_id = e4) = 'contabilidad', 'sin perfil: como antes');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.tope_rol WHERE empresa_id IN (e2, e3, e4)), 'topes = plantilla (L 5,000), sin filas de más');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.verificar_bitacora()), 'bitácora intacta');

  -- 6) Las plantillas no las ve ni las cambia la app.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar('SELECT * FROM interno.plantilla_perfil', '42501', 'plantilla oculta');
END $$;
