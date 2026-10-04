-- PRUEBA: mi_perfil() devuelve usuario, empresa, rol, permisos, módulos y licencia para dueño, admin, cajero, vendedor y proveedor
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  p jsonb;
BEGIN
  -- Dueño: todos los permisos.
  PERFORM pruebas.como('dueno_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'usuario'->>'id' = pruebas.usuario('dueno_a')::text, 'usuario');
  PERFORM pruebas.afirmar(p->'usuario'->>'correo' = 'dueno_a@prueba.hn' AND p->'usuario'->>'nombre' = 'Dueño A', 'correo y nombre');
  PERFORM pruebas.afirmar(p->'empresa'->>'id' = e::text AND p->'empresa'->>'nombre' = 'Ferretería El Martillo', 'empresa');
  PERFORM pruebas.afirmar(p->'empresa'->>'moneda' = 'HNL' AND p->'empresa'->>'pais' = 'HN', 'moneda y país');
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'dueno' AND p->'rol'->>'nombre' = 'Dueño', 'rol dueño');
  PERFORM pruebas.afirmar(jsonb_array_length(p->'permisos') = (SELECT count(*) FROM public.permiso), 'dueño con todos los permisos');
  PERFORM pruebas.afirmar(p->'modulos' = '["contabilidad"]', 'módulos');
  PERFORM pruebas.afirmar(p->'licencia'->>'estado' = 'activa' AND (p->'licencia'->>'dias')::int = 30, 'licencia activa, 30 días');
  PERFORM pruebas.afirmar(jsonb_array_length(p->'empresas') = 1, 'una empresa');
  PERFORM pruebas.afirmar(p->>'soporte_vigente_hasta' IS NULL, 'sin soporte');

  -- Admin.
  PERFORM pruebas.como('admin_a');
  p := public.mi_perfil(e);
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'admin', 'rol admin');
  PERFORM pruebas.afirmar(p->'permisos' = '["adjuntos.agregar", "apartados.cancelar", "apartados.registrar", "aprobaciones.ver", "arranque.gestionar", "asientos.anular", "asientos.registrar", "bitacora.ver", "bodegas.administrar", "cai.administrar", "caja.supervisar", "caja.turno", "cobros.anular", "cobros.condonar", "comisiones.pagar", "comisiones.ver", "compras.anular", "compras.pagar", "compras.registrar", "compras.ver", "contabilidad.ver", "dinero.administrar", "dinero.anular", "dinero.trasladar", "dinero.ver", "fondos.ver", "gastos.anular", "gastos.aprobar", "gastos.registrar", "inventario.ajustar", "inventario.anular", "inventario.carga_inicial", "inventario.costos", "inventario.trasladar", "inventario.ver", "periodos.cerrar", "productos.editar", "productos.precios", "proveedor.solicitar", "sucursales.administrar", "terceros.credito", "terceros.desactivar", "terceros.editar", "terceros.ver", "usuarios.administrar", "ventas.anular", "ventas.aprobar", "ventas.cobrar", "ventas.cotizar", "ventas.devolver", "ventas.promociones", "ventas.solicitar_anulacion", "ventas.vender", "ventas.ver"]', 'permisos admin: ' || (p->'permisos')::text);

  -- Cajero y vendedor: sin contabilidad ni costos; ven existencias y registran clientes (0.3.0).
  PERFORM pruebas.como('cajero_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'cajero' AND p->'permisos' = '["adjuntos.agregar", "apartados.registrar", "caja.turno", "inventario.ver", "terceros.editar", "terceros.ver", "ventas.cobrar", "ventas.cotizar", "ventas.devolver", "ventas.solicitar_anulacion", "ventas.vender"]', 'cajero: su turno, comprobantes, existencias y clientes');
  PERFORM pruebas.como('vendedor_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'vendedor' AND p->'permisos' = '["apartados.registrar", "inventario.ver", "terceros.editar", "terceros.ver", "ventas.cotizar", "ventas.solicitar_anulacion", "ventas.vender"]' AND p->'modulos' = '["contabilidad"]', 'vendedor');

  -- Proveedor: sin permisos; con soporte, solo lectura.
  PERFORM pruebas.como('proveedor');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'rol'->>'codigo' = 'proveedor' AND p->'permisos' = '[]', 'proveedor sin permisos');
  PERFORM pruebas.como('dueno_a');
  PERFORM public.otorgar_acceso_soporte(e, now() + interval '1 day', 'Configurar reportes');
  PERFORM pruebas.como('proveedor');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'permisos' = '["aprobaciones.ver", "bitacora.ver", "comisiones.ver", "compras.ver", "contabilidad.ver", "dinero.ver", "fondos.ver", "inventario.costos", "terceros.ver", "ventas.ver"]', 'proveedor con soporte');
  PERFORM pruebas.afirmar(p->>'soporte_vigente_hasta' ~ '^\d{4}-\d{2}-\d{2}T', 'muestra hasta cuándo');

  -- Estados de licencia.
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) - 3, dias_gracia = 5 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'licencia'->>'estado' = 'en_gracia' AND (p->'licencia'->>'dias')::int = 2, 'en gracia, quedan 2 días: ' || (p->'licencia')::text);
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) - 30 WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'licencia'->>'estado' = 'solo_lectura' AND p->'licencia'->>'motivo' = 'vencida'
                          AND (p->'licencia'->>'dias')::int = 25, 'solo lectura hace 25 días: ' || (p->'licencia')::text);
  PERFORM pruebas.como('service_role');
  UPDATE public.licencia SET vence_el = public.hoy_local(e) + 10, suspendida = true WHERE empresa_id = e;
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar(public.mi_perfil()->'licencia'->>'motivo' = 'suspendida', 'suspendida');

  -- Usuario con dos empresas: sin indicar, la app debe preguntar cuál.
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.usuario_empresa (user_id, empresa_id, rol) VALUES (pruebas.usuario('dueno_b'), e, 'vendedor');
  PERFORM pruebas.como('dueno_b');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'empresa' = 'null' AND jsonb_array_length(p->'empresas') = 2, 'dos empresas: elegir');
  PERFORM pruebas.afirmar(public.mi_perfil(e)->'rol'->>'codigo' = 'vendedor', 'en A es vendedor');
  PERFORM pruebas.afirmar(public.mi_perfil(pruebas.empresa('B'))->'rol'->>'codigo' = 'dueno', 'en B es dueño');

  -- Sin empresa, ajeno, sin sesión.
  PERFORM pruebas.como('sin_empresa');
  p := public.mi_perfil();
  PERFORM pruebas.afirmar(p->'empresa' = 'null' AND p->'empresas' = '[]', 'sin empresa');
  PERFORM pruebas.debe_fallar(format('SELECT public.mi_perfil(%L)', e), 'NO_PERTENECE', 'empresa ajena');
  PERFORM pruebas.como('sin_sesion');
  PERFORM pruebas.debe_fallar('SELECT public.mi_perfil()', 'SIN_SESION', 'sin sesión');
  PERFORM pruebas.como('anon');
  PERFORM pruebas.debe_fallar('SELECT public.mi_perfil()', '42501', 'anon');
END $$;
