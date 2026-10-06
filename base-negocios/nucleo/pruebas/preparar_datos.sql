-- =====================================================================
-- preparar_datos.sql  -  SOLO PRUEBAS. Datos y ayudantes comunes.
--   Empresa A: dueño, admin, cajero, vendedor y proveedor.
--   Empresa B: su dueño (para probar que A y B no se ven).
-- Las empresas se crean con la llave service_role, como en la vida real,
-- con fecha de inicio 01/01/2026.
-- =====================================================================

CREATE SCHEMA pruebas;
GRANT USAGE ON SCHEMA pruebas TO anon, authenticated, service_role;

CREATE TABLE pruebas.usuario (apodo text PRIMARY KEY, id uuid NOT NULL);
CREATE TABLE pruebas.dato    (clave text PRIMARY KEY, valor uuid NOT NULL);
GRANT SELECT ON pruebas.usuario, pruebas.dato TO anon, authenticated, service_role;

INSERT INTO pruebas.usuario (apodo, id) VALUES
  ('dueno_a',     'a0000000-0000-0000-0000-000000000001'),
  ('admin_a',     'a0000000-0000-0000-0000-000000000002'),
  ('cajero_a',    'a0000000-0000-0000-0000-000000000003'),
  ('vendedor_a',  'a0000000-0000-0000-0000-000000000004'),
  ('proveedor',   'a0000000-0000-0000-0000-000000000005'),
  ('dueno_b',     'b0000000-0000-0000-0000-000000000001'),
  ('sin_empresa', 'c0000000-0000-0000-0000-000000000001');
INSERT INTO auth.users (id, email) SELECT id, apodo || '@prueba.hn' FROM pruebas.usuario;
-- 0.13.1: cada usuario de prueba tiene una sesión de Supabase Auth iniciada ayer (claim "session_id").
INSERT INTO auth.sessions (id, user_id, created_at)
SELECT md5('sesion:' || id::text)::uuid, id, now() - interval '1 day' FROM pruebas.usuario;

-- ---------------------------------------------------------------------
-- Ayudantes
-- ---------------------------------------------------------------------
CREATE FUNCTION pruebas.usuario(p_apodo text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT id FROM pruebas.usuario WHERE apodo = p_apodo $$;

CREATE FUNCTION pruebas.empresa(p_clave text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT valor FROM pruebas.dato WHERE clave = p_clave $$;

-- Cambia "quién soy" dentro de la transacción actual, igual que Supabase:
-- rol de base de datos + claims del JWT.
CREATE FUNCTION pruebas.como(p_quien text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_quien = 'superusuario' THEN
    PERFORM set_config('role', 'none', true);
    PERFORM set_config('request.jwt.claims', '', true);
  ELSIF p_quien IN ('anon', 'service_role') THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', p_quien)::text, true);
    PERFORM set_config('role', p_quien, true);
  ELSIF p_quien = 'sin_sesion' THEN       -- rol authenticated pero sin usuario
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated"}', true);
    PERFORM set_config('role', 'authenticated', true);
  ELSE
    IF pruebas.usuario(p_quien) IS NULL THEN
      RAISE EXCEPTION 'FALLA: usuario de prueba desconocido %', p_quien;
    END IF;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', pruebas.usuario(p_quien), 'role', 'authenticated',
                        'session_id', md5('sesion:' || pruebas.usuario(p_quien)::text)::uuid)::text, true);
    PERFORM set_config('role', 'authenticated', true);
  END IF;
END $$;

-- Falla la prueba si la condición no se cumple.
CREATE FUNCTION pruebas.afirmar(p_condicion boolean, p_que text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT coalesce(p_condicion, false) THEN
    RAISE EXCEPTION 'FALLA: %', p_que;
  END IF;
END $$;

-- Ejecuta p_sql y exige que falle con un error que contenga p_esperado
-- (texto del mensaje o código SQLSTATE, p. ej. 42501 = permiso denegado).
CREATE FUNCTION pruebas.debe_fallar(p_sql text, p_esperado text, p_que text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_paso boolean := false;
BEGIN
  BEGIN
    EXECUTE p_sql;
    v_paso := true;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_esperado OR SQLERRM ILIKE '%' || p_esperado || '%' THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'FALLA [%]: se esperaba "%" pero salió: % (%)', p_que, p_esperado, SQLERRM, SQLSTATE;
  END;
  IF v_paso THEN
    RAISE EXCEPTION 'FALLA [%]: se esperaba el error "%" pero la operación pasó.', p_que, p_esperado;
  END IF;
END $$;

-- Arma el texto SQL de una llamada a registrar_asiento (para debe_fallar).
CREATE FUNCTION pruebas.sql_registrar(p_empresa uuid, p_fecha date, p_lineas jsonb,
                                      p_id_op uuid DEFAULT gen_random_uuid(),
                                      p_desc text DEFAULT 'Asiento de prueba') RETURNS text
LANGUAGE sql AS $$
  SELECT format('SELECT public.registrar_asiento(%L::uuid, %L::date, %L, %L::jsonb, %L::uuid)',
                p_empresa, p_fecha, p_desc, p_lineas, p_id_op)
$$;

-- Asiento simple de dos líneas: monto al debe de una cuenta y al haber de otra.
CREATE FUNCTION pruebas.lineas(p_cta_debe text, p_cta_haber text, p_monto bigint) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('cuenta', p_cta_debe,  'debe',  p_monto),
    jsonb_build_object('cuenta', p_cta_haber, 'haber', p_monto))
$$;

-- Saldo (según naturaleza) de una cuenta, en centavos.
CREATE FUNCTION pruebas.saldo(p_empresa uuid, p_codigo text) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT saldo_centavos FROM public.v_saldo_cuenta WHERE empresa_id = p_empresa AND codigo = p_codigo
$$;

-- Guarda / lee un id de prueba (cualquier rol puede llamarlas).
CREATE FUNCTION pruebas.guardar(p_clave text, p_valor uuid) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  INSERT INTO pruebas.dato (clave, valor) VALUES (p_clave, p_valor)
  ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor RETURNING valor
$$;
CREATE FUNCTION pruebas.id(p_clave text) RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT valor FROM pruebas.dato WHERE clave = p_clave $$;

-- Etapa 2a: activa inventario y compras en la empresa A y crea (como
-- dueño): bodegas B1 y B2 (sucursal 001), productos P1 (tornillo, UND,
-- ISV15, enteros), P2 (arroz, LB, EXENTO, fracciones), P3 (pintura, ISV18)
-- y proveedores PROV1 (plazo 30) y PROV2 (plazo 0). Deja la sesión como dueno_a.
CREATE FUNCTION pruebas.preparar_inventario() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  e    uuid := pruebas.empresa('A');
  s001 uuid;
  lb   uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'inventario'), (e, 'compras')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  SELECT id INTO s001 FROM public.sucursal WHERE empresa_id = e AND codigo = '001';
  SELECT id INTO lb FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'LB';

  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.guardar('B1', (public.crear_bodega(e, s001, 'B1', 'Bodega principal')->>'bodega_id')::uuid);
  PERFORM pruebas.guardar('B2', (public.crear_bodega(e, s001, 'B2', 'Bodega trasera')->>'bodega_id')::uuid);
  PERFORM pruebas.guardar('P1', (public.crear_producto(e, jsonb_build_object('codigo', 'TOR-001',
    'codigo_barras', '7421000000011', 'nombre', 'Tornillo 1/2', 'precio_venta_centavos', 1500,
    'stock_minimo', 50), gen_random_uuid())->>'producto_id')::uuid);
  PERFORM pruebas.guardar('P2', (public.crear_producto(e, jsonb_build_object('codigo', 'ARR-001',
    'nombre', 'Arroz', 'unidad_id', lb, 'tipo_impuesto', 'EXENTO', 'permite_fracciones', true,
    'precio_venta_centavos', 2200), gen_random_uuid())->>'producto_id')::uuid);
  PERFORM pruebas.guardar('P3', (public.crear_producto(e, jsonb_build_object('codigo', 'PIN-001',
    'nombre', 'Pintura galón', 'tipo_impuesto', 'ISV18', 'precio_venta_centavos', 45000),
    gen_random_uuid())->>'producto_id')::uuid);
  PERFORM pruebas.guardar('PROV1', (public.crear_tercero(e, '{"nombre": "Distribuidora Lara", "es_proveedor": true,
    "plazo_dias": 30, "rtn": "08011999000111"}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM pruebas.guardar('PROV2', (public.crear_tercero(e, '{"nombre": "Ferremax", "es_proveedor": true}',
    gen_random_uuid())->>'tercero_id')::uuid);
END $$;

-- Arma una compra (jsonb) de una sola línea.
CREATE FUNCTION pruebas.compra(p_prov text, p_bodega text, p_factura text, p_fecha date, p_condicion text,
                               p_producto text, p_cantidad numeric, p_costo numeric,
                               p_forma text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'proveedor_id', pruebas.id(p_prov), 'bodega_id', pruebas.id(p_bodega), 'numero_documento', p_factura,
    'fecha', p_fecha, 'condicion', p_condicion, 'forma_pago', p_forma,
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id(p_producto),
                                                   'cantidad', p_cantidad, 'costo_unitario', p_costo))))
$$;

-- Saldo de inventario (cantidad, valor) de un producto en una bodega.
CREATE FUNCTION pruebas.existencia(p_bodega text, p_producto text) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT coalesce((SELECT cantidad FROM public.inventario_saldo
                       WHERE bodega_id = pruebas.id(p_bodega) AND producto_id = pruebas.id(p_producto)), 0) $$;
CREATE FUNCTION pruebas.valor(p_bodega text, p_producto text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT coalesce((SELECT valor_centavos FROM public.inventario_saldo
                       WHERE bodega_id = pruebas.id(p_bodega) AND producto_id = pruebas.id(p_producto)), 0) $$;
CREATE FUNCTION pruebas.promedio(p_bodega text, p_producto text) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT coalesce((SELECT costo_promedio FROM public.inventario_saldo
                       WHERE bodega_id = pruebas.id(p_bodega) AND producto_id = pruebas.id(p_producto)), 0) $$;
-- Saldo contable sin RLS (para comparar).
CREATE FUNCTION pruebas.saldo_libros(p_empresa uuid, p_codigo text) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER AS
  $$ SELECT saldo_centavos FROM public.v_saldo_cuenta WHERE empresa_id = p_empresa AND codigo = p_codigo $$;

-- Etapa 2b-1: activa el módulo "dinero" en la empresa A y crea (como dueño):
--   CAJA1   efectivo de la caja 001 (punto de emisión 001), saldo 0
--   FUERTE  caja fuerte (efectivo sin caja), saldo inicial L 3,000.00 (300000)
--   BANCO   BAC Credomatic cheques ****6789, saldo inicial L 10,000.00 (1000000)
--   CCHICA  caja chica con fondo fijo L 2,000.00 (200000), saldo 0
--   categorías de gasto CAT_LUZ (6.1.02.02), CAT_PAPEL (6.1.02.05), CAT_ALQ (6.1.02.01)
-- Saldos iniciales con fecha 02/01/2026. Deja la sesión como dueno_a.
CREATE FUNCTION pruebas.preparar_dinero() RETURNS void LANGUAGE plpgsql AS $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'dinero')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  PERFORM pruebas.guardar('CAJA001', (SELECT id FROM public.caja WHERE empresa_id = e AND punto_emision = '001'));
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.guardar('CAJA1', (public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja',
    'nombre', 'Caja 1', 'caja_id', pruebas.id('CAJA001')))->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('FUERTE', (public.crear_cuenta_dinero(e, '{"tipo": "efectivo_caja", "nombre": "Caja fuerte"}')->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('BANCO', (public.crear_cuenta_dinero(e, '{"tipo": "banco", "nombre": "BAC cheques",
    "banco": "BAC Credomatic", "numero_cuenta": "7301-2345-6789", "tipo_cuenta": "cheques"}')->>'cuenta_dinero_id')::uuid);
  PERFORM pruebas.guardar('CCHICA', (public.crear_cuenta_dinero(e, '{"tipo": "caja_chica", "nombre": "Caja chica",
    "fondo_fijo_centavos": 200000}')->>'cuenta_dinero_id')::uuid);
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'),
    'monto_centavos', 1000000, 'fecha', '2026-01-02', 'referencia', 'Estado de cuenta dic-2025'), gen_random_uuid());
  PERFORM public.registrar_saldo_inicial_dinero(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('FUERTE'),
    'monto_centavos', 300000, 'fecha', '2026-01-02'), gen_random_uuid());
  PERFORM pruebas.guardar('CAT_LUZ',   (public.crear_categoria_gasto(e, 'Energía eléctrica', '6.1.02.02')->>'categoria_id')::uuid);
  PERFORM pruebas.guardar('CAT_PAPEL', (public.crear_categoria_gasto(e, 'Papelería', '6.1.02.05')->>'categoria_id')::uuid);
  PERFORM pruebas.guardar('CAT_ALQ',   (public.crear_categoria_gasto(e, 'Alquiler', '6.1.02.01')->>'categoria_id')::uuid);
END $$;

-- Saldo de una cuenta de dinero (suma de su rastro) y de su subcuenta en los libros.
-- (plpgsql: así este archivo también carga en bases viejas sin estas tablas, ver prueba 57)
CREATE FUNCTION pruebas.dinero(p_clave text) RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER AS
  $$ BEGIN RETURN (SELECT coalesce(sum(monto_centavos), 0)::bigint FROM public.dinero_movimiento WHERE cuenta_dinero_id = pruebas.id(p_clave)); END $$;
CREATE FUNCTION pruebas.dinero_libros(p_clave text) RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER AS
  $$ BEGIN RETURN (SELECT pruebas.saldo_libros(d.empresa_id, c.codigo) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
                    WHERE d.id = pruebas.id(p_clave)); END $$;
-- Un comprobante de prueba (ruta en la carpeta de la empresa A).
CREATE FUNCTION pruebas.comprobante(p_nombre text) RETURNS jsonb LANGUAGE sql STABLE AS
  $$ SELECT jsonb_build_object('ruta', pruebas.empresa('A')::text || '/comprobantes/' || p_nombre, 'tipo', 'image/jpeg',
                               'sha256', encode(sha256(convert_to(p_nombre, 'UTF8')), 'hex')) $$;

-- Etapa 2b-2a: inventario + dinero + módulo "ventas" en la empresa A y (como dueño):
--   compras al crédito (PROV1, B1, 05/01/2026): P1 100 und a L 10.00, P2 50 lb a L 15.00,
--   P3 10 gal a L 300.00 (valor 475,000);
--   clientes CLI1 (límite L 5,000.00, plazo 30, RTN) y CLI2 (sin límite);
--   servicio S1 "Mano de obra" (hora, ISV15, L 230.00 con ISV, costo estimado L 80.00).
--   p_fiscal = true: activa el régimen fiscal_hn y registra un CAI de factura
--   para la caja 001 (001-001-01-00000001 a 001-001-01-00001000, vence en 180 días).
-- Deja la sesión como dueno_a. (plpgsql: carga también en bases viejas.)
CREATE FUNCTION pruebas.preparar_ventas(p_fiscal boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.preparar_inventario();
  PERFORM pruebas.preparar_dinero();
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'ventas')
  ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  IF p_fiscal THEN
    INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fiscal_hn')
    ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  END IF;
  PERFORM pruebas.como('dueno_a');
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV1'), 'bodega_id', pruebas.id('B1'),
    'numero_documento', 'F-INI-1', 'fecha', '2026-01-05', 'condicion', 'credito',
    'lineas', jsonb_build_array(
      jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000),
      jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 50, 'costo_unitario', 1500),
      jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 10, 'costo_unitario', 30000))), gen_random_uuid());
  PERFORM pruebas.guardar('CLI1', (public.crear_tercero(e, '{"nombre": "Constructora Ríos", "es_cliente": true,
    "rtn": "08011999000222", "limite_credito_centavos": 500000, "plazo_dias": 30}', gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM pruebas.guardar('CLI2', (public.crear_tercero(e, '{"nombre": "Juan Pérez", "es_cliente": true}',
    gen_random_uuid())->>'tercero_id')::uuid);
  PERFORM pruebas.guardar('S1', (public.crear_producto(e, jsonb_build_object('codigo', 'MO-HORA', 'nombre', 'Mano de obra',
    'tipo', 'servicio', 'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'HORA'),
    'precio_venta_centavos', 23000, 'costo_estimado_centavos', 8000, 'permite_fracciones', true), gen_random_uuid())->>'producto_id')::uuid);
  IF p_fiscal THEN
    PERFORM pruebas.guardar('CAI1', (public.registrar_cai(e, jsonb_build_object('caja_id', pruebas.id('CAJA001'),
      'tipo_documento', 'factura', 'cai', 'A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6',
      'rango_desde', '001-001-01-00000001', 'rango_hasta', '001-001-01-00001000',
      'fecha_limite_emision', to_char(public.hoy_local(e) + 180, 'YYYY-MM-DD')))->>'cai_rango_id')::uuid);
  END IF;
END $$;

-- Una venta (jsonb) de una línea con un solo pago por el total.
CREATE FUNCTION pruebas.venta(p_producto text, p_cantidad numeric, p_forma text DEFAULT 'efectivo',
                              p_cliente text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('cliente_id', pruebas.id(p_cliente),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id(p_producto), 'cantidad', p_cantidad)),
    'pagos', jsonb_build_array(jsonb_build_object('forma', p_forma))))
$$;

-- 0.9.1: fijar_porcentaje_comision ya no acepta "desde" en el pasado. Para pruebas con
-- ventas en fechas pasadas: un porcentaje que se fijó ANTES de esas ventas (como si el
-- dueño lo hubiera registrado ese día). (plpgsql: carga también en bases viejas.)
CREATE FUNCTION pruebas.porcentaje_comision_anterior(p_empresa uuid, p_user uuid, p_porcentaje numeric, p_desde date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.comision_porcentaje (empresa_id, user_id, porcentaje, desde, motivo, creado_por)
  VALUES (p_empresa, p_user, p_porcentaje, p_desde, 'Prueba: porcentaje fijado antes de las ventas', p_user);
END $$;

-- Etapa 3a: enero de 2026 con cifras conocidas (las hechas a mano están en prueba_120), como dueño y
-- sin turnos obligatorios, sobre preparar_ventas(false):
--   10/01 venta de contado (efectivo, CAJA1): 10 tornillos = 15,000 (13,043 + ISV 1,957; costo 10,000)
--   12/01 venta al crédito a CLI1 (V_ENE_2): 1 galón = 45,000 (38,136 + ISV 6,864; costo 30,000; vence 11/02)
--   15/01 venta de contado con tarjeta (POS): 2 h de servicio = 46,000 (40,000 + ISV 6,000)
--   20/01 cobro de CLI1 en efectivo a V_ENE_2: 20,000 (queda 25,000)
--   22/01 gasto de energía desde BANCO: 11,500
--   25/01 abono a la compra F-INI-1 desde BANCO: 100,000
--   28/01 depósito de FUERTE a BANCO: 50,000 (DEP_ENE, queda en tránsito)
-- (plpgsql: carga también en bases viejas.)
CREATE FUNCTION pruebas.preparar_enero() RETURNS void LANGUAGE plpgsql AS $$
DECLARE e uuid := pruebas.empresa('A');
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de cierre de mes');
  PERFORM public.registrar_venta(e, pruebas.venta('P1', 10, 'efectivo') || '{"fecha": "2026-01-10"}', gen_random_uuid());
  PERFORM pruebas.guardar('V_ENE_2', (public.registrar_venta(e, pruebas.venta('P3', 1, 'credito', 'CLI1') || '{"fecha": "2026-01-12"}',
    gen_random_uuid())->>'venta_id')::uuid);
  PERFORM public.registrar_venta(e, pruebas.venta('S1', 2, 'tarjeta') || '{"fecha": "2026-01-15"}', gen_random_uuid());
  PERFORM public.registrar_cobro(e, jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'fecha', '2026-01-20',
    'pagos', '[{"forma":"efectivo","monto_centavos":20000}]'::jsonb), gen_random_uuid());
  PERFORM public.registrar_gasto(e, jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'), 'categoria_id', pruebas.id('CAT_LUZ'),
    'monto_centavos', 11500, 'descripcion', 'Energía de enero', 'fecha', '2026-01-22'), gen_random_uuid());
  PERFORM public.pagar_proveedor(e, (SELECT id FROM public.compra WHERE empresa_id = e AND numero_documento = 'F-INI-1'), 100000,
    '2026-01-25', NULL, gen_random_uuid(), 'Abono', NULL, pruebas.id('BANCO'));
  PERFORM pruebas.guardar('DEP_ENE', (public.trasladar_dinero(e, jsonb_build_object('tipo', 'deposito', 'origen_id', pruebas.id('FUERTE'),
    'destino_id', pruebas.id('BANCO'), 'monto_centavos', 50000, 'fecha', '2026-01-28', 'referencia', 'Boleta 1'), gen_random_uuid())->>'operacion_id')::uuid);
END $$;

-- Usuario contador de la empresa A (lo crea el dueño). Deja la sesión como dueno_a.
CREATE FUNCTION pruebas.crear_contador() RETURNS void LANGUAGE plpgsql AS $$
DECLARE cont uuid;
BEGIN
  PERFORM pruebas.como('superusuario');
  INSERT INTO auth.users (email) VALUES ('contador@prueba.hn') RETURNING id INTO cont;
  INSERT INTO pruebas.usuario (apodo, id) VALUES ('contador', cont);
  PERFORM pruebas.como('dueno_a');
  PERFORM public.agregar_usuario_empresa(pruebas.empresa('A'), 'contador@prueba.hn', 'contador', 'Lic. Contador');
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pruebas TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Empresas (con la llave del proveedor: service_role)
-- ---------------------------------------------------------------------
SET ROLE service_role;
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false);
SELECT set_config('pruebas.emp_a', public.crear_empresa_inicial('{
  "nombre": "Ferretería El Martillo", "rtn": "08011999000001", "rubro": "Ferretería",
  "fecha_inicio": "2026-01-01",
  "dueno":     {"user_id": "a0000000-0000-0000-0000-000000000001", "nombre": "Dueño A"},
  "proveedor": {"user_id": "a0000000-0000-0000-0000-000000000005"}
}')::text, false);
SELECT set_config('pruebas.emp_b', public.crear_empresa_inicial('{
  "nombre": "Pulpería La Esquina", "rtn": "08011999000002", "fecha_inicio": "2026-01-01",
  "dueno": {"correo": "dueno_b@prueba.hn"}
}')::text, false);
-- Licencias vigentes por 30 días.
INSERT INTO public.licencia (empresa_id, vence_el)
VALUES (current_setting('pruebas.emp_a')::uuid, public.hoy_local() + 30),
       (current_setting('pruebas.emp_b')::uuid, public.hoy_local() + 30);
RESET ROLE;
SELECT set_config('request.jwt.claims', '', false);

INSERT INTO pruebas.dato (clave, valor) VALUES
  ('A', current_setting('pruebas.emp_a')::uuid),
  ('B', current_setting('pruebas.emp_b')::uuid);

-- Resto del personal de la empresa A.
INSERT INTO public.usuario_empresa (user_id, empresa_id, rol)
SELECT pruebas.usuario(x.apodo), pruebas.empresa('A'), x.rol
FROM (VALUES ('admin_a','admin'), ('cajero_a','cajero'), ('vendedor_a','vendedor')) AS x(apodo, rol);
