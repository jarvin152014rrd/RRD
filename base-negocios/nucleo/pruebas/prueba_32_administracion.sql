-- PRUEBA: administración con permisos y bitácora: usuarios (agregar/desactivar, nunca borrar), sucursales, cajas y subcuentas
DO $$
DECLARE
  e     uuid := pruebas.empresa('A');
  nuevo uuid;
  s002  uuid;
  s001  uuid;
  c1    uuid;
  r     jsonb;
  cta   public.cuenta;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('nuevo@prueba.hn') RETURNING id INTO nuevo;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('nuevo', nuevo);
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';

  -- ===== Usuarios =====
  PERFORM pruebas.como('cajero_a');  -- el cajero no administra usuarios (el admin sí, desde 0.3.0: ver prueba 33)
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'cajero'), 'SIN_PERMISO', 'cajero agrega');

  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nadie@prueba.hn', 'cajero'), 'USUARIO_NO_EXISTE', 'correo no registrado');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'proveedor'), 'PROHIBIDO', 'dar rol proveedor');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'jefe'), 'NO_EXISTE', 'rol inexistente');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'dueno_a@prueba.hn', 'cajero'), 'PROHIBIDO', 'cambiarse a sí mismo');

  r := public.agregar_usuario_empresa(e, 'Nuevo@Prueba.hn', 'cajero', 'Carlos Caja');
  PERFORM pruebas.afirmar((r->>'nuevo')::boolean AND r->>'rol' = 'cajero', 'agregado como cajero');
  PERFORM pruebas.como('nuevo');
  PERFORM pruebas.afirmar(public.mi_perfil()->'rol'->>'codigo' = 'cajero', 'el nuevo entra como cajero');

  PERFORM pruebas.como('dueno_a');
  r := public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'vendedor');
  PERFORM pruebas.afirmar(NOT (r->>'nuevo')::boolean AND r->>'rol' = 'vendedor', 'cambio de rol');

  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, nuevo, 'no'), 'FALTA_MOTIVO', 'desactivar sin motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, pruebas.usuario('dueno_a'), 'me voy'), 'PROHIBIDO', 'desactivarse');
  r := public.desactivar_usuario_empresa(e, nuevo, 'Ya no trabaja aquí');
  PERFORM pruebas.afirmar(NOT (r->>'activo')::boolean, 'desactivado');
  PERFORM pruebas.como('nuevo');
  PERFORM pruebas.afirmar(public.mi_perfil()->'empresa' = 'null', 'desactivado ya no entra');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.empresa) = 0, 'desactivado no ve nada');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.usuario_empresa WHERE user_id = nuevo AND empresa_id = e AND NOT activo), 'no se borró');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'usuario_empresa' AND accion = 'UPDATE'
    AND despues->>'user_id' = nuevo::text AND despues->>'activo' = 'false' AND motivo = 'Ya no trabaja aquí'
    AND usuario_id = pruebas.usuario('dueno_a')), 'desactivación en bitácora');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'usuario_empresa' AND accion = 'INSERT'
    AND despues->>'user_id' = nuevo::text AND usuario_id = pruebas.usuario('dueno_a')), 'alta en bitácora');

  -- Reactivar = volver a agregar.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.agregar_usuario_empresa(e, 'nuevo@prueba.hn', 'cajero');
  PERFORM pruebas.como('nuevo');
  PERFORM pruebas.afirmar(public.mi_perfil()->'rol'->>'codigo' = 'cajero', 'reactivado');

  -- Si el dueño delega la administración al admin, el admin no toca dueños.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.cambiar_permiso_rol(e, 'admin', 'usuarios.administrar', true, 'El admin maneja el personal');
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'dueno'), 'PROHIBIDO', 'admin nombra dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_usuario_empresa(%L, %L, %L)', e, pruebas.usuario('dueno_a'), 'golpe de estado'), 'PROHIBIDO', 'admin desactiva dueño');
  PERFORM public.desactivar_usuario_empresa(e, pruebas.usuario('vendedor_a'), 'Fin de contrato');

  -- Con licencia vencida se puede desactivar (seguridad) pero no crear.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() - 60 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.desactivar_usuario_empresa(e, nuevo, 'Desactivar en solo lectura');
  PERFORM pruebas.debe_fallar(format('SELECT public.agregar_usuario_empresa(%L, %L, %L)', e, 'nuevo@prueba.hn', 'cajero'), 'LICENCIA_VENCIDA', 'agregar en solo lectura');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '009', 'X'), 'LICENCIA_VENCIDA', 'crear sucursal en solo lectura');
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local() + 30 WHERE empresa_id = e;

  -- ===== Sucursales y cajas =====
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '002', 'Centro'), 'SIN_PERMISO', 'cajero crea sucursal');
  PERFORM pruebas.como('dueno_a');
  s002 := (public.crear_sucursal(e, '002', '  Sucursal Centro ')->>'sucursal_id')::uuid;
  PERFORM pruebas.afirmar((SELECT nombre FROM public.sucursal WHERE id = s002) = 'Sucursal Centro', 'sucursal creada');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '002', 'Otra'), 'YA_EXISTE', 'código repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '2', 'Otra'), 'DATO_INVALIDO', 'código de 1 dígito');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_sucursal(%L, %L, %L)', e, '003', ' '), 'DATO_INVALIDO', 'sin nombre');

  c1 := (public.crear_caja(e, s002, 'Caja 1 Centro', '001')->>'caja_id')::uuid;   -- 001 se repite en otra sucursal: válido
  PERFORM public.crear_caja(e, s002, 'Caja 2 Centro', '002');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e, s002, 'Repetida', '001'), 'YA_EXISTE', 'punto de emisión repetido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e, s002, 'Mala', 'A1'), 'DATO_INVALIDO', 'punto de emisión malo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, NULL, %L, %L)', e, 'X', '005'), 'SUCURSAL_INVALIDA', 'sin sucursal');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e, gen_random_uuid(), 'Inventada', '009'), 'SUCURSAL_INVALIDA', 'sucursal inventada');

  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_caja(%L, %L, %L)', e, c1, 'x'), 'FALTA_MOTIVO', 'caja sin motivo');
  r := public.desactivar_caja(e, c1, 'Se dañó la impresora');
  PERFORM pruebas.afirmar(NOT (r->>'activa')::boolean, 'caja desactivada');
  r := public.desactivar_sucursal(e, s002, 'Se cerró el local');
  PERFORM pruebas.afirmar((r->>'cajas_desactivadas')::int = 1, 'desactiva también su caja activa');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_caja(%L, %L, %L, %L)', e, s002, 'Tarde', '003'), 'SUCURSAL_INVALIDA', 'caja en sucursal inactiva');
  PERFORM pruebas.debe_fallar(format('SELECT public.desactivar_sucursal(%L, %L, %L)', e, s001, 'cerrar todo'), 'ULTIMA_SUCURSAL', 'última sucursal');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.caja WHERE sucursal_id = s002) = 2, 'cajas no se borran');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'caja' AND accion = 'UPDATE'
    AND registro_id = c1::text AND motivo = 'Se dañó la impresora'), 'caja en bitácora con motivo');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'sucursal' AND accion = 'UPDATE'
    AND registro_id = s002::text AND motivo = 'Se cerró el local'), 'sucursal en bitácora con motivo');

  -- ===== Subcuentas =====
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.02.20', 'Vigilancia'), 'SIN_PERMISO', 'cajero crea cuenta');
  PERFORM pruebas.como('dueno_b');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.02.20', 'Vigilancia'), 'NO_PERTENECE', 'otra empresa');
  PERFORM pruebas.como('dueno_a');
  r := public.crear_subcuenta(e, '6.1.02', '6.1.02.20', ' Vigilancia ');
  SELECT * INTO cta FROM public.cuenta WHERE id = (r->>'cuenta_id')::uuid;
  PERFORM pruebas.afirmar(cta.es_detalle AND cta.tipo = 'gasto' AND cta.naturaleza = 'deudora' AND cta.nombre = 'Vigilancia'
    AND cta.padre_id = (SELECT id FROM public.cuenta WHERE empresa_id = e AND codigo = '6.1.02'), 'subcuenta de detalle bajo 6.1.02');
  PERFORM public.registrar_asiento(e, '2026-01-10', 'Pago de vigilancia', pruebas.lineas('6.1.02.20', '1.1.01.01', 30000), gen_random_uuid());
  PERFORM pruebas.afirmar(pruebas.saldo(e, '6.1.02.20') = 30000, 'la subcuenta recibe movimientos');
  -- Cuenta "contra" con naturaleza propia.
  r := public.crear_subcuenta(e, '1.2.01', '1.2.01.07', 'Depreciación acumulada de vehículos', 'acreedora');
  PERFORM pruebas.afirmar((SELECT naturaleza FROM public.cuenta WHERE id = (r->>'cuenta_id')::uuid) = 'acreedora', 'cuenta contra');

  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02.01', '6.1.02.01.01', 'Bajo detalle'), 'CUENTA_INVALIDA', 'bajo cuenta de detalle');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '9.9', '9.9.01', 'Inventada'), 'CUENTA_INVALIDA', 'madre inexistente');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.03.01', 'Otro código'), 'CUENTA_INVALIDA', 'código que no sigue a la madre');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.02.20.5', 'Dos niveles'), 'CUENTA_INVALIDA', 'dos niveles');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.02.20', 'Repetida'), 'YA_EXISTE', 'repetida');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L)', e, '6.1.02', '6.1.02.21', ''), 'DATO_INVALIDO', 'sin nombre');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_subcuenta(%L, %L, %L, %L, %L)', e, '6.1.02', '6.1.02.21', 'Rara', 'neutra'), 'DATO_INVALIDO', 'naturaleza rara');

  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'cuenta' AND accion = 'INSERT'
    AND despues->>'codigo' = '6.1.02.20' AND usuario_id = pruebas.usuario('dueno_a')), 'subcuenta en bitácora');
  PERFORM pruebas.afirmar(NOT EXISTS (
    SELECT 1 FROM public.cuenta c
    WHERE c.es_detalle = EXISTS (SELECT 1 FROM public.cuenta h WHERE h.padre_id = c.id)), 'árbol de cuentas sigue coherente');
  -- La bitácora sigue íntegra después de todo.
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora íntegra');
END $$;
