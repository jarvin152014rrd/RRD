-- PRUEBA: el admin administra usuarios, sucursales y catálogos; no nombra dueños, no se da más permisos ni cambia permisos de rol; permisos solo del dueño
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  nuevo uuid;
  r     jsonb;
  s002  uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('nuevo@prueba.hn') RETURNING id INTO nuevo;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('nuevo', nuevo);

  -- Por defecto el admin tiene usuarios y sucursales; NO los del dueño.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.afirmar(public.tiene_permiso('usuarios.administrar', e) AND public.tiene_permiso('sucursales.administrar', e)
    AND public.tiene_permiso('bodegas.administrar', e) AND public.tiene_permiso('productos.precios', e)
    AND public.tiene_permiso('terceros.credito', e), 'admin con sus permisos nuevos');
  PERFORM pruebas.afirmar(NOT public.tiene_permiso('permisos.editar', e) AND NOT public.tiene_permiso('periodos.reabrir', e)
    AND NOT public.tiene_permiso('soporte.otorgar', e) AND NOT public.tiene_permiso('empresa.configurar', e), 'admin sin los del dueño');

  -- Admin agrega un cajero, lo cambia a vendedor y lo desactiva.
  r := public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'cajero', 'Nuevo');
  PERFORM pruebas.afirmar((r->>'nuevo')::boolean AND r->>'rol' = 'cajero', 'admin agrega cajero');
  PERFORM public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'vendedor');
  PERFORM public.desactivar_usuario_empresa(e, nuevo, 'Prueba de desactivar');
  -- Puede dar el rol admin (mismos permisos que él, no más).
  PERFORM public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'admin');
  PERFORM pruebas.afirmar((SELECT rol FROM public.usuario_empresa WHERE user_id = nuevo AND empresa_id = e) = 'admin', 'admin da rol admin');
  PERFORM public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'cajero');

  -- No: dueños, proveedor, ni roles con más permisos que los suyos.
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'dueno'), 'PROHIBIDO', 'admin nombra dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'dueno_a@prueba.hn', 'cajero'), 'PROHIBIDO', 'admin cambia al dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, pruebas.usuario('dueno_a'), 'golpe de estado'), 'PROHIBIDO', 'admin desactiva dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, pruebas.usuario('proveedor'), 'sin proveedor'), 'PROHIBIDO', 'admin desactiva proveedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'proveedor@prueba.hn', 'cajero'), 'PROHIBIDO', 'admin cambia rol del proveedor');

  -- El dueño le da al cajero un permiso que el admin no tiene: desde ahí
  -- el admin ya no puede asignar el rol cajero ni tocar a los cajeros.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'cajero', 'inventario.negativo', true, 'Cajero de confianza');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'vendedor_a@prueba.hn', 'cajero'), 'PROHIBIDO', 'admin sube a un rol con más permisos');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, nuevo, 'quitar cajero'), 'PROHIBIDO', 'admin desactiva rol con más permisos');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'cajero_a@prueba.hn', 'vendedor'), 'PROHIBIDO', 'admin cambia rol de quien tiene más');

  -- El admin no se da permisos ni cambia permisos de roles.
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'inventario.negativo', 'me lo doy'), 'SIN_PERMISO', 'admin se da permisos');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, false, %L)', e, 'cajero', 'inventario.ver', 'quitar al cajero'), 'SIN_PERMISO', 'admin cambia permisos de otro rol');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"tope_credito_centavos": 99999999}', 'subir tope'), 'SIN_PERMISO', 'admin cambia el tope');

  -- Ni el dueño puede pasar a otro rol los permisos que son solo suyos.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'periodos.reabrir', 'delegar reabrir'), 'PROHIBIDO', 'reabrir solo dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'permisos.editar', 'delegar permisos'), 'PROHIBIDO', 'permisos solo dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.cambiar_permiso_rol(%L, %L, %L, true, %L)', e, 'admin', 'empresa.configurar', 'delegar config'), 'PROHIBIDO', 'configurar solo dueño');
  -- El dueño sí puede nombrar otro dueño.
  PERFORM public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'dueno');

  -- Sucursales y cajas: el admin ya puede.
  PERFORM pruebas.como('admin_a');
  s002 := (public.crear_sucursal(e, '002', 'Sucursal Centro')->>'sucursal_id')::uuid;
  PERFORM public.crear_caja(e, s002, 'Caja 2', '001');
  PERFORM public.desactivar_sucursal(e, s002, 'Se cerró el local');

  -- Configuración (solo dueño): datos malos y bitácora.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"tope_credito_centavos": -1}', 'tope negativo'), 'DATO_INVALIDO', 'tope negativo');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"tope_credito_centavos": 10.5}', 'tope decimal'), 'DATO_INVALIDO', 'tope con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"tope": 1}', 'campo malo'), 'DATO_INVALIDO', 'campo desconocido');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"tope_credito_centavos": 1}', 'no'), 'FALTA_MOTIVO', 'sin motivo');
  r := public.configurar_empresa(e, '{"tope_credito_centavos": 500000}', 'Tope de crédito L 5,000');
  PERFORM pruebas.afirmar((r->>'tope_credito_centavos')::bigint = 500000 AND NOT (r->>'permite_existencia_negativa')::boolean, 'tope fijado');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'empresa' AND accion = 'UPDATE'
    AND motivo = 'Tope de crédito L 5,000' AND despues->>'tope_credito_centavos' = '500000'), 'configuración en bitácora');
END $$;
