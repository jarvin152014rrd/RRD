-- PRUEBA: turnos de caja obligatorios o no (por empresa, solo el dueño): obligatorios = sin turno no entra efectivo (regla de siempre); no obligatorios = el efectivo entra a la caja sin turno (cifras a mano, rastro sin turno y cuadra con los libros); nunca se mezcla con el turno abierto de otro cajero; los turnos siguen funcionando igual
DO $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s001 uuid;
  cj2  uuid;
  d    public.cuenta_dinero;
  t    public.turno_caja;
  r    jsonb;
  tur  jsonb;
  ast  uuid;
BEGIN
  PERFORM pruebas.preparar_dinero();
  PERFORM pruebas.como('superusuario');
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  PERFORM pruebas.afirmar((SELECT turnos_obligatorios FROM public.empresa WHERE id = e), 'por defecto los turnos son obligatorios');

  -- 1) Obligatorios: el cajero sin turno no recibe efectivo.
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('role', 'none', true);                -- llamar funciones internas con la sesión del cajero
  PERFORM pruebas.debe_fallar(format('SELECT interno.exigir_turno_abierto(%L)', e), 'SIN_TURNO_ABIERTO', 'obligatorio: exigir turno');
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, NULL)', e), 'SIN_TURNO_ABIERTO', 'obligatorio: sin turno no cobra');

  -- 2) Solo el dueño lo cambia, con motivo; queda en la bitácora.
  PERFORM pruebas.como('admin_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"turnos_obligatorios": false}', 'Negocio pequeño'),
    'SIN_PERMISO', 'el admin no lo cambia');
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.configurar_empresa(%L, %L, %L)', e, '{"turnos_obligatorios": "no"}', 'Negocio pequeño'),
    'DATO_INVALIDO', 'debe ser true o false');
  r := public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Negocio pequeño, un solo cajero');
  PERFORM pruebas.afirmar(NOT (r->>'turnos_obligatorios')::boolean AND (r->>'contabilidad_visible')::boolean, 'turnos no obligatorios: ' || r::text);
  PERFORM pruebas.afirmar(NOT (public.mi_perfil(e)->'empresa'->>'turnos_obligatorios')::boolean, 'mi_perfil lo muestra');
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.bitacora WHERE tabla = 'empresa' AND accion = 'UPDATE'
    AND motivo = 'Negocio pequeño, un solo cajero' AND despues->>'turnos_obligatorios' = 'false'), 'bitácora');

  -- 3) No obligatorios: el efectivo entra a la caja SIN turno.
  --    Cobro simulado (la venta llega en 2b-2) de 11,500: Dr Caja 1 / Cr 4.1.01.01. Caja 1: 0 + 11,500 = 11,500.
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('role', 'none', true);
  t := interno.exigir_turno_abierto(e);
  PERFORM pruebas.afirmar(t.id IS NULL, 'sin turno ya no es error (turno vacío)');
  d := interno.cuenta_efectivo_cobro(e, NULL);                -- una sola caja activa: esa
  PERFORM pruebas.afirmar(d.id = pruebas.id('CAJA1'), 'entra a la cuenta de la única caja');
  ast := interno.asiento_sistema(e, NULL, '2026-01-20', 'Cobro de contado (simulado)', 'prueba', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('cuenta', (SELECT codigo FROM public.cuenta WHERE id = d.cuenta_id), 'debe', 11500),
                      jsonb_build_object('cuenta', '4.1.01.01', 'haber', 11500)));
  PERFORM interno.rastrear_dinero(ast, 'cobro', 'prueba', gen_random_uuid(), 'Factura 1', 'Caja 1');
  PERFORM pruebas.afirmar((SELECT turno_id IS NULL AND monto_centavos = 11500 AND creado_por = pruebas.usuario('cajero_a')
                             FROM public.dinero_movimiento WHERE asiento_id = ast), 'rastro sin turno, con el cajero');
  PERFORM pruebas.afirmar(pruebas.dinero('CAJA1') = 11500 AND pruebas.dinero_libros('CAJA1') = 11500, 'Caja 1 = 11,500 = libros');

  -- 4) Con dos cajas hay que decir cuál; la nueva caja recibe su cuenta de efectivo sola.
  PERFORM pruebas.como('dueno_a');
  cj2 := (public.crear_caja(e, s001, 'Caja 2', '002')->>'caja_id')::uuid;
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('role', 'none', true);
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, NULL)', e), 'indique en qué caja', 'dos cajas: cuál');
  d := interno.cuenta_efectivo_cobro(e, cj2);
  PERFORM pruebas.afirmar(d.nombre = 'Efectivo Caja 2 (001-002)' AND d.caja_id = cj2 AND d.tipo = 'efectivo_caja', 'cuenta creada: ' || d.nombre);

  -- 5) Los turnos se pueden usar igual. El admin abre turno en la caja 001 (fondo = 11,500 del sistema).
  PERFORM pruebas.como('admin_a');
  tur := public.abrir_turno(e, pruebas.id('CAJA001'), 11500, gen_random_uuid());
  PERFORM pruebas.afirmar(tur->>'estado' = 'abierto', 'turno abierto');
  -- El cajero sin turno no cobra en esa caja (no se mezcla con el arqueo del admin).
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('role', 'none', true);
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, %L)', e, pruebas.id('CAJA001')), 'CAJA_OCUPADA', 'caja con turno de otro');
  -- Quien tiene turno cobra en su caja (y no en otra).
  PERFORM pruebas.como('admin_a');
  PERFORM set_config('role', 'none', true);
  PERFORM pruebas.afirmar((interno.cuenta_efectivo_cobro(e, NULL)).id = pruebas.id('CAJA1'), 'con turno: su caja');
  PERFORM pruebas.afirmar((interno.exigir_turno_abierto(e)).id = (tur->>'turno_id')::uuid, 'devuelve su turno');
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, %L)', e, cj2), 'cobre en esa caja', 'con turno no cobra en otra');
  PERFORM pruebas.como('admin_a');
  r := public.cerrar_turno((tur->>'turno_id')::uuid, 11500, gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'diferencia_estado' = 'sin_diferencia' AND (r->>'esperado_centavos')::bigint = 11500, 'arqueo igual que siempre');

  -- 6) De vuelta a obligatorios: otra vez la regla de siempre.
  PERFORM pruebas.como('dueno_a');
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": true}', 'Ya hay varios cajeros');
  PERFORM pruebas.como('cajero_a');
  PERFORM set_config('role', 'none', true);
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, %L)', e, cj2), 'SIN_TURNO_ABIERTO', 'obligatorio otra vez');

  -- La app no puede llamar las funciones internas.
  PERFORM pruebas.como('cajero_a');
  PERFORM pruebas.debe_fallar(format('SELECT interno.cuenta_efectivo_cobro(%L, NULL)', e), '42501', 'interno oculto');
END $$;
