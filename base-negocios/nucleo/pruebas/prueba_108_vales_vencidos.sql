-- PRUEBA: (0.9.1, menor) vales vencidos: solo el dueño los da de baja (cobros.baja_vales), con motivo y bitácora; uno por código o todos los vencidos; el saldo del vale queda en 0 y pasa de Saldos a favor (2.1.04.02) a otros ingresos (4.2.01.04); un vale vigente no se da de baja; reintento; sin vencidos con saldo: SIN_VALES_VENCIDOS
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  hace date;
  v    jsonb;
  va   text; vc text; vb text;
  b    jsonb;
  op   uuid := gen_random_uuid();
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false, "vale_dias_vigencia": 1}', 'Vales vencen al día siguiente');
  hace := public.hoy_local(e) - 5;

  -- Hace 5 días: venta sin cliente de 2 tornillos (3,000) y dos devoluciones de 1 tornillo a vale (1,500 c/u): vencen hace 4 días.
  v := public.registrar_venta(e, pruebas.venta('P1', 2) || jsonb_build_object('fecha', hace), gen_random_uuid());
  va := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'motivo', 'Lo cambia otro día', 'destino', 'saldo_favor', 'fecha', hace), gen_random_uuid())->'saldo_favor'->>'codigo';
  vc := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'motivo', 'Lo cambia otro día', 'destino', 'saldo_favor', 'fecha', hace), gen_random_uuid())->'saldo_favor'->>'codigo';
  -- Hoy: otro vale de 1,500 (vigente).
  v := public.registrar_venta(e, pruebas.venta('P1', 1), gen_random_uuid());
  vb := public.registrar_devolucion((v->>'venta_id')::uuid, jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb,
          'motivo', 'Lo cambia otro día', 'destino', 'saldo_favor'), gen_random_uuid())->'saldo_favor'->>'codigo';
  PERFORM pruebas.afirmar(va LIKE 'VALE-%' AND vc LIKE 'VALE-%' AND vb LIKE 'VALE-%', 'tres vales');
  PERFORM pruebas.afirmar(public.consultar_vale(e, va)->>'estado' = 'vencido' AND public.consultar_vale(e, vb)->>'estado' = 'vigente', 'A vencido, B vigente');

  -- Solo el dueño (opción del dueño).
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.dar_baja_vales_vencidos(%L, %L, %L, gen_random_uuid())', e, '{}', 'Vales viejos'),
    'SIN_PERMISO', 'el admin no');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.dar_baja_vales_vencidos(%L, %L, %L, gen_random_uuid())', e, '{}', 'Vales viejos'),
    'SIN_PERMISO', 'el cajero no');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.dar_baja_vales_vencidos(%L, %L, %L, gen_random_uuid())', e, '{}', 'no'),
    'FALTA_MOTIVO', 'con motivo');
  PERFORM pruebas.debe_fallar(format('SELECT public.dar_baja_vales_vencidos(%L, %L, %L, gen_random_uuid())', e,
    jsonb_build_object('vales', jsonb_build_array(vb)), 'Vale viejo'), 'DATO_INVALIDO', 'un vale vigente no');

  -- 1) Baja del vale A por su código: 1,500 a otros ingresos.
  b := public.dar_baja_vales_vencidos(e, jsonb_build_object('vales', jsonb_build_array(va)), 'Vencido y no reclamado', op);
  PERFORM pruebas.afirmar((b->>'monto_centavos')::bigint = 1500 AND (b->>'vales')::integer = 1 AND NOT (b->>'duplicado')::boolean, 'baja de A: ' || b::text);
  PERFORM pruebas.afirmar((public.dar_baja_vales_vencidos(e, jsonb_build_object('vales', jsonb_build_array(va)), 'Vencido y no reclamado', op)->>'duplicado')::boolean,
    'reintento');
  PERFORM pruebas.afirmar((public.consultar_vale(e, va)->>'saldo_centavos')::bigint = 0, 'A queda en 0');

  -- 2) Sin lista: todos los vencidos con saldo (solo C); B sigue vigente.
  b := public.dar_baja_vales_vencidos(e, '{}', 'Limpieza de vales vencidos', gen_random_uuid());
  PERFORM pruebas.afirmar((b->>'monto_centavos')::bigint = 1500 AND b->'detalle'->0->>'codigo' = vc, 'baja de C');
  PERFORM pruebas.debe_fallar(format('SELECT public.dar_baja_vales_vencidos(%L, %L, %L, gen_random_uuid())', e, '{}', 'Otra limpieza'),
    'SIN_VALES_VENCIDOS', 'ya no hay vencidos con saldo');
  PERFORM pruebas.afirmar((public.consultar_vale(e, vb)->>'saldo_centavos')::bigint = 1500, 'B intacto');

  -- Libros: otros ingresos 3,000; saldos a favor = solo B (1,500) = su pasivo; bitácora con el motivo.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(pruebas.saldo_libros(e, '4.2.01.04') = 3000 AND interno.total_saldo_favor(e) = 1500
    AND pruebas.saldo_libros(e, '2.1.04.02') = 1500, 'otros ingresos 3,000; pasivo 1,500');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.bitacora WHERE tabla = 'saldo_favor_baja' AND motivo = 'Vencido y no reclamado') = 1
    AND (SELECT count(*) FROM public.verificar_bitacora()) = 0, 'bitácora con motivo e intacta');
  PERFORM pruebas.debe_fallar(format('UPDATE public.saldo_favor_baja SET motivo = %L', 'Otro'), 'no se edita', 'no se edita');
END $$;
