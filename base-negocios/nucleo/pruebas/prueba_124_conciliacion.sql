-- PRUEBA: conciliación bancaria (cifras a mano): módulo propio (necesita dinero); importar el estado de cuenta como filas (solo banco, fechas del mes, la misma fila no se repite, reintento); emparejamiento automático por monto y fecha ± días (y referencia), manual y deshacer con motivo; diferencias en banco y en sistema; crear desde el banco la comisión y los intereses con asiento y rastro; cerrar por mes en orden solo si saldo banco = sistema ± pendientes; cerrada no cambia; permisos
DO $$
DECLARE
  e      uuid := pruebas.empresa('A');
  r      jsonb;
  c1     uuid;
  c2     uuid;
  b_com  uuid;
  b_int  uuid;
  b_dep  uuid;
  b_chq  uuid;
  m_dep  bigint;
  m_gas  bigint;
  par    uuid;
  filas_ene jsonb := '[
    {"fecha":"2026-01-22","descripcion":"PAGO ENEE","referencia":"ENEE-01","monto_centavos":-11500},
    {"fecha":"2026-01-27","descripcion":"TRANSF DISTRIBUIDORA LARA","monto_centavos":-100000},
    {"fecha":"2026-01-31","descripcion":"COMISION MANEJO CUENTA","monto_centavos":-5750},
    {"fecha":"2026-01-31","descripcion":"INTERESES GANADOS","monto_centavos":1234}]';
BEGIN
  -- Enero (preparar_enero): BANCO = saldo inicial 1,000,000 (02/01) - gasto 11,500 (22/01) - abono a proveedor 100,000 (25/01).
  -- El depósito de 50,000 (28/01) se confirma el 29/01 con referencia "Boleta 1": + 50,000.
  -- Sistema al 31/01 = 1,000,000 - 11,500 - 100,000 + 50,000 = 938,500.
  PERFORM pruebas.preparar_enero();
  PERFORM public.confirmar_deposito(pruebas.id('DEP_ENE'), gen_random_uuid(), '2026-01-29', 'Boleta 1');
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 938500, 'banco en el sistema 938,500: ' || pruebas.dinero('BANCO'));

  -- Sin el módulo: no se importa.
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 1, %L, gen_random_uuid())',
    e, pruebas.id('BANCO'), jsonb_build_object('filas', filas_ene)), 'MODULO_INACTIVO', 'sin el módulo conciliacion');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'conciliacion');
  PERFORM pruebas.como('dueno_a');

  -- Datos inválidos: solo bancos, fechas del mes.
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 1, %L, gen_random_uuid())',
    e, pruebas.id('FUERTE'), jsonb_build_object('filas', filas_ene)), 'solo se concilian cuentas de banco', 'caja fuerte no');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 1, %L, gen_random_uuid())',
    e, pruebas.id('BANCO'), '{"filas":[{"fecha":"2026-02-01","descripcion":"X","monto_centavos":5}]}'), 'DATO_INVALIDO', 'fila de otro mes');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 1, %L, gen_random_uuid())',
    e, pruebas.id('BANCO'), '{"filas":[{"fecha":"2026-01-05","descripcion":"X","monto_centavos":5.5}]}'), 'centavos enteros', 'monto con decimales');

  -- 1) Importar enero con 1 día de tolerancia: solo la ENEE empareja (mismo día); la transferencia (2 días) no.
  --    Banco: inicial 1,000,000; final 1,000,000 - 11,500 - 100,000 - 5,750 + 1,234 = 883,984.
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 1, jsonb_build_object('archivo', 'bac_enero.csv',
         'saldo_inicial_centavos', 1000000, 'saldo_final_centavos', 883984, 'dias_tolerancia', 1, 'filas', filas_ene), gen_random_uuid());
  c1 := (r->>'conciliacion_id')::uuid;
  PERFORM pruebas.afirmar((r->>'filas_nuevas')::integer = 4 AND (r->>'emparejadas_automaticamente')::integer = 1, 'importar enero: ' || r::text);
  PERFORM pruebas.afirmar((r->'resumen'->>'estado_cuenta_completo')::boolean, 'inicial + filas = final del banco');
  -- 2) Con 3 días: empareja la transferencia (25/01 en el sistema, 27/01 en el banco).
  r := public.emparejar_conciliacion(c1, 3);
  PERFORM pruebas.afirmar((r->>'emparejadas_automaticamente')::integer = 1, 'con 3 días empareja la transferencia: ' || r::text);
  -- A mano: en sistema y no en banco = +50,000 (depósito); en banco y no en sistema = -5,750 + 1,234 = -4,516.
  --         calculado = 938,500 - 50,000 - 4,516 = 883,984 = lo que dice el banco.
  r := public.ver_conciliacion(c1);
  PERFORM pruebas.afirmar((r->>'saldo_sistema_centavos')::bigint = 938500 AND (r->>'en_sistema_no_en_banco_centavos')::bigint = 50000
    AND (r->>'en_banco_no_en_sistema_centavos')::bigint = -4516 AND (r->>'saldo_banco_calculado_centavos')::bigint = 883984
    AND (r->>'cuadra')::boolean AND jsonb_array_length(r->'conciliados') = 2, 'diferencias de enero: ' || (r - 'conciliados' - 'empresa')::text);

  -- 3) La misma carga otra vez: nada se repite; mismo id_operacion = la misma carga.
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 1, jsonb_build_object('filas', filas_ene), '00000000-0000-0000-0000-00000000c124');
  PERFORM pruebas.afirmar((r->>'filas_nuevas')::integer = 0 AND (r->>'filas_repetidas')::integer = 4, 'segunda carga sin repetir: ' || r::text);
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 1, jsonb_build_object('filas', filas_ene), '00000000-0000-0000-0000-00000000c124');
  PERFORM pruebas.afirmar((r->>'duplicado')::boolean, 'reintento');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.banco_movimiento WHERE conciliacion_id = c1) = 4, 'siguen 4 filas');

  -- 4) Deshacer con motivo y volver a emparejar a mano.
  SELECT p.id INTO par FROM public.conciliacion_pareja p JOIN public.banco_movimiento b ON b.id = p.banco_movimiento_id
   WHERE b.referencia = 'ENEE-01' AND p.deshecha_en IS NULL;
  PERFORM pruebas.debe_fallar(format('SELECT public.deshacer_emparejamiento(%L, %L)', par, 'mal'), 'FALTA_MOTIVO', 'deshacer pide motivo');
  r := public.deshacer_emparejamiento(par, 'Revisar con el recibo de la ENEE');
  PERFORM pruebas.afirmar((r->'resumen'->>'en_sistema_no_en_banco_centavos')::bigint = 50000 - 11500
    AND (r->'resumen'->>'en_banco_no_en_sistema_centavos')::bigint = -4516 - 11500 AND (r->'resumen'->>'cuadra')::boolean,
    'deshecho: la ENEE queda pendiente en los dos lados y sigue cuadrando');
  PERFORM pruebas.afirmar((SELECT deshecha_en IS NOT NULL AND motivo_deshacer = 'Revisar con el recibo de la ENEE' FROM public.conciliacion_pareja WHERE id = par),
    'el emparejamiento no se borra: queda deshecho con su motivo');
  SELECT id INTO m_gas FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id('BANCO') AND operacion = 'gasto';
  SELECT id INTO m_dep FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id('BANCO') AND monto_centavos = 50000;
  SELECT id INTO b_com FROM public.banco_movimiento WHERE conciliacion_id = c1 AND monto_centavos = -5750;
  SELECT id INTO b_int FROM public.banco_movimiento WHERE conciliacion_id = c1 AND monto_centavos = 1234;
  PERFORM pruebas.debe_fallar(format('SELECT public.emparejar_manual(%L, %L, %L)', c1, b_int, m_dep), 'NO_EMPAREJA', 'montos distintos');
  PERFORM public.emparejar_manual(c1, (SELECT banco_movimiento_id FROM public.conciliacion_pareja WHERE id = par), m_gas, 'Recibo revisado');
  PERFORM pruebas.debe_fallar(format('SELECT public.emparejar_manual(%L, %L, %L)', c1,
    (SELECT banco_movimiento_id FROM public.conciliacion_pareja WHERE id = par), m_gas), 'YA_CONCILIADO', 'no se empareja dos veces');

  -- 5) Crear desde el banco la comisión que falta: Dr 6.2.01.02 Comisiones bancarias 5,750 / Cr BANCO 5,750 (con rastro).
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_diferencia_banco(%L, %L, %L, gen_random_uuid())', c1, b_int,
    '{"tipo":"comision_bancaria"}'), 'DATO_INVALIDO', 'una entrada no es comisión');
  r := public.registrar_diferencia_banco(c1, b_com, '{"tipo":"comision_bancaria"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'cuenta' = '6.2.01.02' AND pruebas.saldo_libros(e, '6.2.01.02') = 5750, 'comisión al gasto: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 932750 AND pruebas.dinero_libros('BANCO') = 932750, 'banco 938,500 - 5,750 = 932,750 con rastro');
  PERFORM pruebas.afirmar((SELECT operacion = 'diferencia_banco' AND documento_tipo = 'banco_diferencia' FROM public.dinero_movimiento
                            WHERE id = (r->>'dinero_movimiento_id')::bigint), 'rastro de la comisión');
  -- A mano: 932,750 - 50,000 + 1,234 = 883,984.
  PERFORM pruebas.afirmar((r->'resumen'->>'en_banco_no_en_sistema_centavos')::bigint = 1234 AND (r->'resumen'->>'cuadra')::boolean,
    'tras la comisión: ' || (r->'resumen')::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_diferencia_banco(%L, %L, %L, gen_random_uuid())', c1, b_com,
    '{"tipo":"comision_bancaria"}'), 'YA_CONCILIADO', 'no se crea dos veces');

  -- 6) Febrero: el depósito llega al banco el 02/02 (4 días: no empareja solo) y un cheque de 20,000 que no está en el sistema.
  --    Banco: inicial 883,984; final 883,984 + 50,000 - 20,000 = 913,984.
  r := public.importar_estado_cuenta(e, pruebas.id('BANCO'), 2026, 2, jsonb_build_object('saldo_inicial_centavos', 883984,
         'saldo_final_centavos', 913984, 'filas', '[
           {"fecha":"2026-02-02","descripcion":"DEPOSITO","referencia":"Boleta 1","monto_centavos":50000},
           {"fecha":"2026-02-10","descripcion":"CHEQUE 1001","referencia":"1001","monto_centavos":-20000}]'::jsonb), gen_random_uuid());
  c2 := (r->>'conciliacion_id')::uuid;
  PERFORM pruebas.afirmar((r->>'emparejadas_automaticamente')::integer = 0, 'febrero: nada empareja solo');
  -- En orden: febrero no se cierra con enero abierto.
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_conciliacion(%L)', c2), 'CONCILIACION_EN_ORDEN', 'primero enero');

  -- 7) Cerrar enero: con un saldo que no cuadra no; con el del banco sí (quedan pendientes 50,000 y 1,234).
  PERFORM pruebas.debe_fallar(format('SELECT public.cerrar_conciliacion(%L, 883000)', c1), 'CONCILIACION_NO_CUADRA', 'no cuadra por 984');
  r := public.cerrar_conciliacion(c1, 883984);
  PERFORM pruebas.afirmar(r->>'estado' = 'cerrada' AND (r->'resumen'->>'en_sistema_no_en_banco_centavos')::bigint = 50000
    AND (r->'resumen'->>'en_banco_no_en_sistema_centavos')::bigint = 1234, 'enero cerrado con sus pendientes: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 1, %L, gen_random_uuid())',
    e, pruebas.id('BANCO'), jsonb_build_object('filas', filas_ene)), 'CONCILIACION_CERRADA', 'enero cerrado no recibe filas');
  SELECT p.id INTO par FROM public.conciliacion_pareja p WHERE p.conciliacion_id = c1 AND p.deshecha_en IS NULL LIMIT 1;
  PERFORM pruebas.debe_fallar(format('SELECT public.deshacer_emparejamiento(%L, %L)', par, 'Ya no se puede'), 'CONCILIACION_CERRADA', 'cerrada no se deshace');
  PERFORM pruebas.afirmar((public.ver_conciliacion(c1)->>'foto')::boolean, 'enero se lee de su foto');

  -- 8) Febrero: el depósito a mano; el cheque contra 6.1.02.05 (otro); los intereses de enero (fila del banco que quedó
  --    pendiente) Dr BANCO 1,234 / Cr 4.2.01.01 Ingresos financieros con fecha 31/01.
  SELECT id INTO b_dep FROM public.banco_movimiento WHERE conciliacion_id = c2 AND monto_centavos = 50000;
  SELECT id INTO b_chq FROM public.banco_movimiento WHERE conciliacion_id = c2 AND monto_centavos = -20000;
  PERFORM public.emparejar_manual(c2, b_dep, m_dep, 'El banco lo acreditó el lunes');
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_diferencia_banco(%L, %L, %L, gen_random_uuid())', c2, b_chq,
    '{"tipo":"otro","cuenta":"1.1.02.01"}'), 'CUENTA_INVALIDA', 'contrapartida de activo no');
  PERFORM public.registrar_diferencia_banco(c2, b_chq, '{"tipo":"otro","cuenta":"6.1.02.05","descripcion":"Cheque 1001 papelería"}', gen_random_uuid());
  r := public.registrar_diferencia_banco(c2, b_int, '{"tipo":"interes"}', gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'cuenta' = '4.2.01.01' AND pruebas.saldo_libros(e, '4.2.01.01') = 1234, 'intereses al ingreso: ' || r::text);
  -- A mano: sistema al 28/02 = 932,750 + 1,234 - 20,000 = 913,984; sin pendientes = banco 913,984.
  r := public.cerrar_conciliacion(c2);
  PERFORM pruebas.afirmar((r->'resumen'->>'saldo_sistema_centavos')::bigint = 913984 AND (r->'resumen'->>'en_sistema_no_en_banco_centavos')::bigint = 0
    AND (r->'resumen'->>'en_banco_no_en_sistema_centavos')::bigint = 0, 'febrero cerrado sin pendientes: ' || r::text);
  PERFORM pruebas.afirmar(pruebas.dinero('BANCO') = 913984 AND pruebas.dinero_libros('BANCO') = 913984, 'banco = libros = 913,984');
  -- La foto de enero no cambió aunque después se crearon los intereses.
  PERFORM pruebas.afirmar((public.ver_conciliacion(c1)->>'en_banco_no_en_sistema_centavos')::bigint = 1234, 'foto de enero intacta');

  -- 9) Permisos: el contador ve pero no concilia; el cajero no ve.
  PERFORM pruebas.crear_contador();
  PERFORM pruebas.como('contador');
  PERFORM pruebas.afirmar((public.ver_conciliacion(c2)->>'estado') = 'cerrada' AND (SELECT count(*) FROM public.v_conciliacion) = 2, 'el contador ve');
  PERFORM pruebas.debe_fallar(format('SELECT public.importar_estado_cuenta(%L, %L, 2026, 3, %L, gen_random_uuid())',
    e, pruebas.id('BANCO'), '{"filas":[{"fecha":"2026-03-01","descripcion":"X","monto_centavos":5}]}'), 'SIN_PERMISO', 'contador no importa');
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.ver_conciliacion(%L)', c1), 'SIN_PERMISO', 'cajero no ve bancos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.banco_movimiento) = 0, 'cajero no lee filas del banco');
  -- Nada se borra.
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.debe_fallar('DELETE FROM public.banco_movimiento', 'no se borra', 'filas del banco no se borran');
  PERFORM pruebas.debe_fallar('DELETE FROM public.conciliacion_pareja', 'no se borra', 'emparejamientos no se borran');
END $$;
