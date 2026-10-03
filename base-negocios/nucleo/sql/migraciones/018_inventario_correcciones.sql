-- =====================================================================
-- 018_inventario_correcciones.sql  -  Núcleo 0.4.0
--
--   * Cuenta nueva 3.3.01.03 "Saldos de apertura" (patrimonio): contra ella
--     va la carga inicial de inventario (antes 3.1.01.01) y, desde 019, los
--     saldos iniciales de proveedores. Si una empresa ya usaba ese código
--     en una subcuenta propia, se toma el siguiente libre (3.3.01.NN) y se
--     anota en interno.cuenta_sistema_empresa.
--   * Regla de fechas del costo promedio: el costo se calcula en el ORDEN DE
--     REGISTRO. Una entrada no puede tener fecha anterior a la última salida
--     de ese producto en esa bodega (ENTRADA_FECHA_ATRASADA), salvo con el
--     permiso inventario.fecha_atrasada (solo dueño). Si se permite, las
--     salidas ya hechas NO se recalculan.
--   * Existencia 0 = valor 0: si una bodega queda en 0 unidades con valor
--     sobrante (o faltante), el sistema agrega en el kardex una línea
--     "ajuste_costo" (0 unidades) y su asiento contra 5.1.01.02.
--   * permite_fracciones no se apaga si hay existencias con decimales.
--   * desactivar_sucursal rechaza si sus bodegas tienen existencias o valor.
--     reactivar_sucursal, reactivar_caja, reactivar_bodega,
--     reactivar_categoria, reactivar_campo_extra (con motivo, en bitácora).
--   * anular_documento_inventario: anula una carga inicial, un ajuste o un
--     traslado (motivo, mes abierto, una vez), solo si no hay movimientos
--     posteriores de esos productos en esas bodegas. Contra-movimientos en
--     el kardex y contra-asiento (la carga inicial vuelve contra la cuenta
--     de apertura que usó, nunca contra gasto).
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('ENTRADA_FECHA_ATRASADA', 'No se puede registrar una entrada con fecha anterior a una salida ya registrada de ese producto.',
   'Use la fecha de hoy (o una igual o posterior a la última salida). Si de verdad hace falta la fecha atrasada, pídaselo al dueño.'),
  ('MOVIMIENTOS_POSTERIORES', 'Después de este documento hubo otros movimientos de esos productos.',
   'No se puede anular. Corrija la diferencia con un ajuste de inventario nuevo.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('inventario.anular',          'Anular cargas iniciales, ajustes y traslados de inventario',          true, false),
  ('inventario.fecha_atrasada',  'Registrar entradas con fecha anterior a la última salida del producto', true, false);

INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'inventario.anular'), ('dueno', 'inventario.fecha_atrasada'),
  ('admin', 'inventario.anular');

SELECT interno.repartir_permisos(ARRAY['inventario.anular', 'inventario.fecha_atrasada'],
  'Núcleo 0.4.0: anular documentos de inventario y entradas con fecha atrasada');

-- ---------------------------------------------------------------------
-- 1) Cuenta "Saldos de apertura"
-- ---------------------------------------------------------------------
INSERT INTO interno.plantilla_cuenta (codigo, nombre, tipo, naturaleza, es_detalle)
VALUES ('3.3.01.03', 'Saldos de apertura', 'patrimonio', 'acreedora', true);

-- Código propio de una empresa para un uso (cuando el de la plantilla ya
-- estaba ocupado por una subcuenta del cliente). Solo para "apertura_*".
CREATE TABLE interno.cuenta_sistema_empresa (
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  uso         text NOT NULL REFERENCES interno.cuenta_sistema(uso),
  codigo      text NOT NULL,
  PRIMARY KEY (empresa_id, uso)
);

UPDATE interno.cuenta_sistema
   SET codigo = '3.3.01.03', descripcion = 'Saldos de apertura: contrapartida del inventario inicial (hasta 0.3.0 era 3.1.01.01)'
 WHERE uso = 'apertura_inventario';
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('apertura_cxp', '3.3.01.03', 'Saldos de apertura: contrapartida de las facturas de proveedores pendientes al iniciar', NULL);

-- Código de cuenta de un uso para UNA empresa.
CREATE FUNCTION interno.cuenta_de(p_empresa_id uuid, p_uso text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT x.codigo FROM interno.cuenta_sistema_empresa x
                    WHERE x.empresa_id = p_empresa_id AND x.uso = p_uso),
                  interno.cuenta_sistema(p_uso))
$$;

-- Empresas ya instaladas: crear la cuenta (o la siguiente libre).
DO $$
DECLARE
  e        record;
  v_madre  uuid;
  v_codigo text;
  n        integer;
BEGIN
  PERFORM set_config('app.motivo', 'Núcleo 0.4.0: cuenta Saldos de apertura', true);
  FOR e IN SELECT id FROM public.empresa LOOP
    SELECT c.id INTO v_madre FROM public.cuenta c WHERE c.empresa_id = e.id AND c.codigo = '3.3.01';
    v_codigo := '3.3.01.03';
    n := 3;
    WHILE EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = e.id AND c.codigo = v_codigo) LOOP
      n := n + 1;
      v_codigo := '3.3.01.' || lpad(n::text, 2, '0');
    END LOOP;
    INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, padre_id, es_detalle)
    VALUES (e.id, v_codigo, 'Saldos de apertura', 'patrimonio', 'acreedora', v_madre, true);
    IF v_codigo <> '3.3.01.03' THEN
      INSERT INTO interno.cuenta_sistema_empresa (empresa_id, uso, codigo) VALUES
        (e.id, 'apertura_inventario', v_codigo), (e.id, 'apertura_cxp', v_codigo);
    END IF;
  END LOOP;
  PERFORM set_config('app.motivo', '', true);
END $$;

-- asiento_sistema (reemplaza la de 015): resuelve "uso" por empresa.
CREATE OR REPLACE FUNCTION interno.asiento_sistema(p_empresa_id uuid, p_sucursal_id uuid, p_fecha date,
                                        p_descripcion text, p_origen text, p_id_operacion uuid,
                                        p_lineas jsonb, p_anula_id uuid DEFAULT NULL, p_motivo text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_debe  bigint;
  v_haber bigint;
  v_cab   record;
BEGIN
  SELECT coalesce(sum(coalesce((l->>'debe')::bigint, 0)), 0), coalesce(sum(coalesce((l->>'haber')::bigint, 0)), 0)
    INTO v_debe, v_haber FROM jsonb_array_elements(p_lineas) l;
  IF v_debe <> v_haber THEN
    RAISE EXCEPTION 'NO_CUADRA: el asiento automático no cuadra (debe %, haber %). Avise a soporte.', v_debe, v_haber;
  END IF;
  IF v_debe = 0 THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lineas) l
              WHERE coalesce((l->>'debe')::bigint, 0) + coalesce((l->>'haber')::bigint, 0) > 0
                AND NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = p_empresa_id
                                   AND c.codigo = coalesce(l->>'cuenta', interno.cuenta_de(p_empresa_id, l->>'uso')))) THEN
    RAISE EXCEPTION 'CUENTA_INVALIDA: falta una cuenta del sistema en el catálogo de la empresa. Avise a soporte.';
  END IF;

  SELECT * INTO v_cab FROM interno.crear_cabecera(p_empresa_id, p_sucursal_id, p_fecha, p_descripcion,
                                                  p_origen, p_id_operacion, v_debe, p_anula_id, p_motivo);
  IF v_cab.o_duplicado THEN
    RAISE EXCEPTION 'YA_EXISTE: el id_operacion % ya se usó en otro asiento. Use uno nuevo.', p_id_operacion;
  END IF;

  INSERT INTO public.asiento_linea (empresa_id, asiento_id, linea, cuenta_id, debe_centavos, haber_centavos, descripcion)
  SELECT p_empresa_id, v_cab.o_id, row_number() OVER (ORDER BY x.n), c.id,
         coalesce((x.l->>'debe')::bigint, 0), coalesce((x.l->>'haber')::bigint, 0), x.l->>'descripcion'
  FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS x(l, n)
  JOIN public.cuenta c ON c.empresa_id = p_empresa_id
                      AND c.codigo = coalesce(x.l->>'cuenta', interno.cuenta_de(p_empresa_id, x.l->>'uso'))
  WHERE coalesce((x.l->>'debe')::bigint, 0) + coalesce((x.l->>'haber')::bigint, 0) > 0;
  RETURN v_cab.o_id;
END $$;

-- ---------------------------------------------------------------------
-- 2) Kardex: línea "ajuste_costo" (0 unidades, solo valor)
-- ---------------------------------------------------------------------
ALTER TABLE public.inventario_movimiento
  DROP CONSTRAINT inventario_movimiento_tipo_check,
  DROP CONSTRAINT inventario_movimiento_cantidad_check,
  DROP CONSTRAINT inventario_movimiento_check,
  ADD CONSTRAINT inventario_movimiento_tipo_check
    CHECK (tipo IN ('entrada', 'salida', 'ajuste', 'traslado', 'ajuste_costo')),
  ADD CONSTRAINT inventario_movimiento_cantidad_check
    CHECK ((cantidad = 0) = (tipo = 'ajuste_costo')),
  ADD CONSTRAINT inventario_movimiento_signo_check
    CHECK ((cantidad > 0 AND valor_centavos >= 0) OR (cantidad < 0 AND valor_centavos <= 0) OR cantidad = 0);

-- ---------------------------------------------------------------------
-- 3) EL MOTOR (reemplaza el de 015). Igual que antes, más:
--    (a) entrada con fecha anterior a la última salida: no (salvo permiso);
--    (b) si queda 0 unidades con valor distinto de 0: línea ajuste_costo
--        + asiento contra 5.1.01.02, para que 0 unidades = L 0.00.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.mover_inventario(
  p_empresa_id uuid, p_bodega_id uuid, p_producto_id uuid, p_tipo text, p_origen text,
  p_fecha date, p_cantidad numeric, p_valor bigint,
  p_documento_tipo text, p_documento_id uuid, p_id_operacion uuid,
  p_nota text DEFAULT NULL, p_negativo boolean DEFAULT false)
RETURNS public.inventario_movimiento
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s        public.inventario_saldo;
  m        public.inventario_movimiento;
  a        public.inventario_movimiento;
  v_q      numeric;      -- cantidad nueva
  v_mov    bigint;       -- valor del movimiento (con signo)
  v_sale   bigint;       -- valor que sale (positivo)
  v_v      bigint;       -- valor nuevo
  v_prom   numeric;      -- costo promedio nuevo
  v_codigo text;
  v_ultima date;
  v_suc    uuid;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad = 0 THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: un movimiento de inventario necesita cantidad.';
  END IF;
  s   := interno.bloquear_saldo(p_empresa_id, p_bodega_id, p_producto_id);
  v_q := s.cantidad + p_cantidad;
  SELECT p.codigo INTO v_codigo FROM public.producto p WHERE p.id = p_producto_id;

  IF p_cantidad > 0 THEN
    IF p_valor IS NULL OR p_valor < 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una entrada de inventario necesita su valor (0 o más).';
    END IF;
    -- (a) Orden de registro: no entra nada "antes" de una salida ya hecha.
    SELECT max(x.fecha_contable) INTO v_ultima FROM public.inventario_movimiento x
     WHERE x.bodega_id = p_bodega_id AND x.producto_id = p_producto_id AND x.cantidad < 0;
    IF v_ultima > p_fecha AND NOT public.tiene_permiso('inventario.fecha_atrasada', p_empresa_id) THEN
      RAISE EXCEPTION 'ENTRADA_FECHA_ATRASADA: el producto % ya tiene una salida con fecha % en esta bodega; una entrada con fecha % cambiaría costos ya usados. Use la fecha % o posterior (o pida al dueño el permiso inventario.fecha_atrasada).',
        v_codigo, to_char(v_ultima, 'DD/MM/YYYY'), to_char(p_fecha, 'DD/MM/YYYY'), to_char(v_ultima, 'DD/MM/YYYY');
    END IF;
    v_mov := p_valor;
  ELSE
    -- Salida: no puede quedar en negativo salvo que se permita.
    IF v_q < 0 AND NOT p_negativo THEN
      RAISE EXCEPTION 'EXISTENCIA_INSUFICIENTE: el producto % solo tiene % en la bodega y se quieren sacar %.',
        v_codigo, s.cantidad, -p_cantidad;
    END IF;
    v_sale := coalesce(p_valor, round(-p_cantidad * s.costo_promedio)::bigint);
    IF v_q = 0 THEN
      v_sale := greatest(s.valor_centavos, 0);            -- se vacía: sale todo el valor
    ELSIF v_q > 0 THEN
      v_sale := least(v_sale, greatest(s.valor_centavos, 0));  -- no sale más valor del que hay
    END IF;
    v_mov := -v_sale;
  END IF;

  v_v := s.valor_centavos + v_mov;
  IF v_q > 0 THEN
    v_prom := round(v_v::numeric / v_q, 6);
  ELSIF p_cantidad > 0 THEN
    v_prom := round(p_valor::numeric / p_cantidad, 6);    -- entrada que no alcanza a salir de negativo
  ELSE
    v_prom := s.costo_promedio;
  END IF;

  INSERT INTO public.inventario_movimiento (empresa_id, bodega_id, producto_id, tipo, origen, fecha_contable,
    cantidad, valor_centavos, costo_unitario, saldo_cantidad, saldo_valor_centavos, saldo_costo_promedio,
    documento_tipo, documento_id, id_operacion, nota, creado_por)
  VALUES (p_empresa_id, p_bodega_id, p_producto_id, p_tipo, p_origen, p_fecha,
    p_cantidad, v_mov, round(abs(v_mov)::numeric / abs(p_cantidad), 6), v_q, v_v, v_prom,
    p_documento_tipo, p_documento_id, p_id_operacion, p_nota, auth.uid())
  RETURNING * INTO m;

  IF v_q < 0 AND p_cantidad < 0 THEN
    INSERT INTO public.inventario_alerta (empresa_id, tipo, bodega_id, producto_id, movimiento_id,
                                          cantidad_resultante, creado_por)
    VALUES (p_empresa_id, 'existencia_negativa', p_bodega_id, p_producto_id, m.id, v_q, auth.uid());
  END IF;

  -- (b) 0 unidades con valor: el valor pasa a ajuste de costo.
  IF v_q = 0 AND v_v <> 0 THEN
    INSERT INTO public.inventario_movimiento (empresa_id, bodega_id, producto_id, tipo, origen, fecha_contable,
      cantidad, valor_centavos, costo_unitario, saldo_cantidad, saldo_valor_centavos, saldo_costo_promedio,
      documento_tipo, documento_id, id_operacion, nota, creado_por)
    VALUES (p_empresa_id, p_bodega_id, p_producto_id, 'ajuste_costo', 'ajuste_costo', p_fecha,
      0, -v_v, 0, 0, 0, v_prom, p_documento_tipo, p_documento_id, p_id_operacion,
      'Existencia en 0: el valor que quedaba (' || v_v || ' centavos) pasa a ajuste de costo', auth.uid())
    RETURNING * INTO a;

    SELECT s2.id INTO v_suc FROM public.bodega b JOIN public.sucursal s2 ON s2.id = b.sucursal_id
     WHERE b.id = p_bodega_id AND s2.activa;
    PERFORM interno.asiento_sistema(p_empresa_id, v_suc, p_fecha,
      'Ajuste de costo de inventario: ' || v_codigo || ' quedó en 0 unidades con ' || v_v || ' centavos',
      'ajuste_costo_inventario', md5('ajuste_costo:' || a.id)::uuid,
      jsonb_build_array(
        jsonb_build_object('uso', 'perdida_inventario', 'debe',  greatest(v_v, 0),  'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'inventario',         'haber', greatest(v_v, 0),  'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'inventario',         'debe',  greatest(-v_v, 0), 'descripcion', 'Ajuste de costo'),
        jsonb_build_object('uso', 'perdida_inventario', 'haber', greatest(-v_v, 0), 'descripcion', 'Ajuste de costo')));
    v_v := 0;
  END IF;

  UPDATE public.inventario_saldo
     SET cantidad = v_q, valor_centavos = v_v, costo_promedio = v_prom,
         ultimo_movimiento_id = coalesce(a.id, m.id), actualizado_en = now()
   WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
  RETURN m;
END $$;

-- ---------------------------------------------------------------------
-- 4) permite_fracciones no se apaga con existencias con decimales
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.fracciones_con_existencia() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_q numeric;
BEGIN
  IF OLD.permite_fracciones AND NOT NEW.permite_fracciones THEN
    SELECT s.cantidad INTO v_q FROM public.inventario_saldo s
     WHERE s.producto_id = NEW.id AND s.cantidad <> trunc(s.cantidad) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'NO_PERMITIDO: el producto % tiene existencias con decimales (por ejemplo %); ajústelas a números enteros antes de quitar "se vende con decimales".',
        NEW.codigo, v_q;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fracciones_fijas BEFORE UPDATE OF permite_fracciones ON public.producto
  FOR EACH ROW EXECUTE FUNCTION interno.fracciones_con_existencia();

-- ---------------------------------------------------------------------
-- 5) Sucursales, cajas, bodegas, categorías y campos extra
-- ---------------------------------------------------------------------
-- desactivar_sucursal (reemplaza la de 010; misma firma). Nuevo: no se
-- desactiva si alguna de sus bodegas tiene existencias o valor.
CREATE OR REPLACE FUNCTION public.desactivar_sucursal(p_empresa_id uuid, p_sucursal_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_suc   public.sucursal;
  v_cajas integer;
  v_bod   text;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la sucursal (mínimo 5 letras).';
  END IF;
  -- Mismo candado que compras, ajustes y traslados: nadie mete mercadería mientras tanto.
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_suc FROM public.sucursal
   WHERE id = p_sucursal_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_suc.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la sucursal no existe en esta empresa.';
  END IF;
  IF NOT v_suc.activa THEN
    RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', false, 'ya_estaba', true);
  END IF;
  SELECT b.codigo INTO v_bod FROM public.bodega b JOIN public.inventario_saldo s ON s.bodega_id = b.id
   WHERE b.sucursal_id = p_sucursal_id AND (s.cantidad <> 0 OR s.valor_centavos <> 0)
   ORDER BY b.codigo LIMIT 1;
  IF v_bod IS NOT NULL THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la sucursal tiene existencias en la bodega %; trasládelas o ajústelas a cero antes de desactivarla.', v_bod;
  END IF;
  PERFORM 1 FROM public.sucursal WHERE empresa_id = p_empresa_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM public.sucursal
                  WHERE empresa_id = p_empresa_id AND activa AND id <> p_sucursal_id) THEN
    RAISE EXCEPTION 'ULTIMA_SUCURSAL: es la única sucursal activa; cree o active otra antes.';
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.sucursal SET activa = false WHERE id = p_sucursal_id;
  UPDATE public.caja SET activa = false WHERE sucursal_id = p_sucursal_id AND activa;
  GET DIAGNOSTICS v_cajas = ROW_COUNT;
  PERFORM set_config('app.motivo', '', true);

  RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', false, 'ya_estaba', false,
                            'cajas_desactivadas', v_cajas);
END $$;

-- Reactiva la sucursal (sus cajas se reactivan una por una con reactivar_caja).
CREATE FUNCTION public.reactivar_sucursal(p_empresa_id uuid, p_sucursal_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.sucursal;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva la sucursal (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.sucursal WHERE id = p_sucursal_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la sucursal no existe en esta empresa.';
  END IF;
  IF v.activa THEN
    RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', true, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.sucursal SET activa = true WHERE id = p_sucursal_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('sucursal_id', p_sucursal_id, 'activa', true, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_caja(p_empresa_id uuid, p_caja_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.caja;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'sucursales.administrar', NULL);
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva la caja (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.caja WHERE id = p_caja_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la caja no existe en esta empresa.';
  END IF;
  IF v.activa THEN
    RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', true, 'ya_estaba', true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v.sucursal_id AND s.activa) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal de esta caja está desactivada; reactívela primero.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.caja SET activa = true WHERE id = p_caja_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('caja_id', p_caja_id, 'activa', true, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_bodega(p_empresa_id uuid, p_bodega_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.bodega;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'bodegas.administrar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva la bodega (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.bodega WHERE id = p_bodega_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la bodega no existe en esta empresa.';
  END IF;
  IF v.activa THEN
    RETURN jsonb_build_object('bodega_id', p_bodega_id, 'activa', true, 'ya_estaba', true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sucursal s WHERE s.id = v.sucursal_id AND s.activa) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal de esta bodega está desactivada; reactívela primero.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.bodega SET activa = true WHERE id = p_bodega_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('bodega_id', p_bodega_id, 'activa', true, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_categoria(p_empresa_id uuid, p_categoria_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.categoria_producto;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.categoria_producto WHERE id = p_categoria_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la categoría no existe en esta empresa.';
  END IF;
  IF v.activa THEN
    RETURN jsonb_build_object('categoria_id', p_categoria_id, 'activa', true, 'ya_estaba', true);
  END IF;
  IF v.padre_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.categoria_producto c WHERE c.id = v.padre_id AND c.activa) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la categoría madre está desactivada; reactívela primero.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.categoria_producto SET activa = true WHERE id = p_categoria_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('categoria_id', p_categoria_id, 'activa', true, 'ya_estaba', false);
END $$;

CREATE FUNCTION public.reactivar_campo_extra(p_empresa_id uuid, p_campo_extra_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.campo_extra;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'productos.editar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se reactiva (mínimo 5 letras).';
  END IF;
  SELECT * INTO v FROM public.campo_extra WHERE id = p_campo_extra_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el campo extra no existe en esta empresa.';
  END IF;
  IF v.activo THEN
    RETURN jsonb_build_object('campo_extra_id', p_campo_extra_id, 'activo', true, 'ya_estaba', true);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.campo_extra SET activo = true WHERE id = p_campo_extra_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('campo_extra_id', p_campo_extra_id, 'activo', true, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- 6) Anulación de documentos de inventario
--    El documento original no se toca: la anulación es una fila aparte
--    (una por documento) con su motivo, fecha, asiento e id_operacion.
-- ---------------------------------------------------------------------
CREATE TABLE public.inventario_documento_anulacion (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id                uuid NOT NULL REFERENCES public.empresa(id),
  documento_id              uuid NOT NULL UNIQUE,                 -- se anula una sola vez
  fecha_contable            date NOT NULL,
  motivo                    text NOT NULL CHECK (length(trim(motivo)) >= 5),
  asiento_id                uuid,                                 -- NULL en traslados
  valor_revertido_centavos  bigint NOT NULL DEFAULT 0,            -- cuánto cambió el inventario (con signo)
  ajuste_costo_centavos     bigint NOT NULL DEFAULT 0,            -- diferencia a 5.1.01.02 (normalmente 0)
  id_operacion              uuid NOT NULL,
  anulado_por               uuid,
  registrado_en             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id_operacion),
  FOREIGN KEY (empresa_id, documento_id) REFERENCES public.inventario_documento(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)   REFERENCES public.asiento(empresa_id, id)
);
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.inventario_documento_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Una anulación no se edita ni se borra.');
CREATE TRIGGER auditar AFTER INSERT ON public.inventario_documento_anulacion
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.inventario_documento_anulacion
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
ALTER TABLE public.inventario_documento_anulacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.inventario_documento_anulacion FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))));
GRANT SELECT ON public.inventario_documento_anulacion TO authenticated, service_role;

CREATE FUNCTION interno.anulacion_inventario_respuesta(x public.inventario_documento_anulacion, p_duplicado boolean)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('documento_id', x.documento_id, 'anulacion_id', x.id, 'asiento_id', x.asiento_id,
                            'valor_revertido_centavos', x.valor_revertido_centavos,
                            'ajuste_costo_centavos', x.ajuste_costo_centavos, 'duplicado', p_duplicado)
$$;

-- RPC: anular_documento_inventario(documento, motivo, id_operacion, fecha?)
-- Permisos: inventario.anular + el del tipo (ajustar / trasladar / carga_inicial).
CREATE FUNCTION public.anular_documento_inventario(p_documento_id uuid, p_motivo text, p_id_operacion uuid,
                                                   p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d        public.inventario_documento;
  v_an     public.inventario_documento_anulacion;
  v_fecha  date;
  v_perm   text;
  v_prod   text;
  v_bod    text;
  r        record;
  m        public.inventario_movimiento;
  v_sale   bigint := 0;   -- valor que salió al revertir entradas
  v_entra  bigint := 0;   -- valor que entró al revertir salidas
  v_dif    bigint := 0;
  v_neto   bigint := 0;
  v_cta    text;
  v_asto   uuid;
  v_suc    uuid;
BEGIN
  SELECT * INTO d FROM public.inventario_documento WHERE id = p_documento_id;
  IF d.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el documento de inventario no existe.';
  END IF;
  PERFORM interno.exigir_escritura(d.empresa_id, 'inventario.anular', 'inventario');
  v_perm := CASE d.tipo WHEN 'ajuste' THEN 'inventario.ajustar' WHEN 'traslado' THEN 'inventario.trasladar'
                        ELSE 'inventario.carga_inicial' END;
  IF NOT public.tiene_permiso(v_perm, d.empresa_id) THEN
    RAISE EXCEPTION 'SIN_PERMISO: su rol no tiene el permiso "%".', v_perm;
  END IF;
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(d.empresa_id, p_id_operacion, 'anulacion_inventario');
  SELECT * INTO v_an FROM public.inventario_documento_anulacion WHERE documento_id = d.id;
  IF v_an.id_operacion = p_id_operacion THEN
    RETURN interno.ocultar_costos(d.empresa_id, interno.anulacion_inventario_respuesta(v_an, true),
                                  ARRAY['valor_revertido_centavos', 'ajuste_costo_centavos']);
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo de la anulación (mínimo 5 letras).';
  END IF;
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(d.empresa_id), d.fecha_contable));
  PERFORM interno.exigir_fecha_contable(d.empresa_id, v_fecha);
  IF v_fecha < d.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación no puede tener fecha anterior al documento (%).',
      to_char(d.fecha_contable, 'DD/MM/YYYY');
  END IF;

  PERFORM interno.bloquear_libros(d.empresa_id);
  SELECT * INTO v_an FROM public.inventario_documento_anulacion WHERE documento_id = d.id;
  IF v_an.id_operacion = p_id_operacion THEN
    RETURN interno.ocultar_costos(d.empresa_id, interno.anulacion_inventario_respuesta(v_an, true),
                                  ARRAY['valor_revertido_centavos', 'ajuste_costo_centavos']);
  END IF;
  IF v_an.id IS NOT NULL THEN
    RAISE EXCEPTION 'YA_ANULADO: el documento de inventario (% #%) ya fue anulado.', d.tipo, d.numero;
  END IF;
  PERFORM interno.exigir_periodo_abierto(d.empresa_id, v_fecha);

  -- Nada posterior de esos productos en esas bodegas.
  SELECT p.codigo, b.codigo INTO v_prod, v_bod
    FROM (SELECT x.bodega_id, x.producto_id, max(x.id) AS ultimo FROM public.inventario_movimiento x
           WHERE x.documento_id = d.id AND x.documento_tipo = 'inventario_documento'
           GROUP BY x.bodega_id, x.producto_id) k
    JOIN public.inventario_movimiento y ON y.bodega_id = k.bodega_id AND y.producto_id = k.producto_id AND y.id > k.ultimo
    JOIN public.producto p ON p.id = k.producto_id
    JOIN public.bodega b ON b.id = k.bodega_id
   LIMIT 1;
  IF v_prod IS NOT NULL THEN
    RAISE EXCEPTION 'MOVIMIENTOS_POSTERIORES: el producto % tiene movimientos en la bodega % registrados después de este documento; no se puede anular. Corrija con un ajuste nuevo.',
      v_prod, v_bod;
  END IF;

  IF d.tipo = 'traslado' THEN
    -- Vuelve del destino al origen con el mismo valor.
    FOR r IN SELECT * FROM public.inventario_documento_linea WHERE documento_id = d.id ORDER BY linea LOOP
      m := interno.mover_inventario(d.empresa_id, d.bodega_destino_id, r.producto_id, 'traslado', 'anulacion_traslado',
             v_fecha, -r.cantidad, r.valor_centavos, 'inventario_documento', d.id, p_id_operacion,
             'Anulación traslado #' || d.numero || ': ' || trim(p_motivo), true);
      PERFORM interno.mover_inventario(d.empresa_id, d.bodega_id, r.producto_id, 'traslado', 'anulacion_traslado',
             v_fecha, r.cantidad, -m.valor_centavos, 'inventario_documento', d.id, p_id_operacion,
             'Anulación traslado #' || d.numero || ': ' || trim(p_motivo));
    END LOOP;
  ELSE
    -- Carga inicial y ajuste: cada movimiento al revés y por el mismo valor.
    FOR r IN SELECT * FROM public.inventario_movimiento x
              WHERE x.documento_id = d.id AND x.documento_tipo = 'inventario_documento' AND x.tipo <> 'ajuste_costo'
                AND x.id_operacion = d.id_operacion
              ORDER BY x.id DESC LOOP
      IF r.cantidad > 0 THEN
        m := interno.mover_inventario(d.empresa_id, r.bodega_id, r.producto_id,
               CASE d.tipo WHEN 'carga_inicial' THEN 'salida' ELSE 'ajuste' END, 'anulacion_' || d.tipo,
               v_fecha, -r.cantidad, r.valor_centavos, 'inventario_documento', d.id, p_id_operacion,
               'Anulación ' || d.tipo || ' #' || d.numero || ': ' || trim(p_motivo), true);
        v_sale := v_sale - m.valor_centavos;
      ELSE
        m := interno.mover_inventario(d.empresa_id, r.bodega_id, r.producto_id, 'ajuste', 'anulacion_' || d.tipo,
               v_fecha, -r.cantidad, -r.valor_centavos, 'inventario_documento', d.id, p_id_operacion,
               'Anulación ' || d.tipo || ' #' || d.numero || ': ' || trim(p_motivo));
        v_entra := v_entra + m.valor_centavos;
      END IF;
    END LOOP;
    v_neto := v_entra - v_sale;

    SELECT s.id INTO v_suc FROM public.bodega b JOIN public.sucursal s ON s.id = b.sucursal_id
     WHERE b.id = d.bodega_id AND s.activa;
    IF d.tipo = 'carga_inicial' THEN
      -- Contra la MISMA cuenta de apertura que usó la carga (3.1.01.01 en
      -- cargas hechas con 0.3.0, Saldos de apertura desde 0.4.0).
      SELECT c.codigo INTO v_cta FROM public.asiento_linea l JOIN public.cuenta c ON c.id = l.cuenta_id
       WHERE l.asiento_id = d.asiento_id AND l.haber_centavos > 0 ORDER BY l.linea LIMIT 1;
      v_dif := d.total_centavos - v_sale;
      IF v_cta IS NULL AND d.total_centavos > 0 THEN
        v_cta := interno.cuenta_de(d.empresa_id, 'apertura_inventario');
      END IF;
      v_asto := interno.asiento_sistema(d.empresa_id, v_suc, v_fecha,
        'ANULACIÓN carga inicial #' || d.numero || ': ' || trim(p_motivo),
        'anulacion_carga_inicial_inventario', p_id_operacion,
        jsonb_build_array(
          jsonb_build_object('cuenta', coalesce(v_cta, '0'), 'debe', d.total_centavos, 'descripcion', 'Reversión de apertura'),
          jsonb_build_object('uso', 'inventario', 'haber', v_sale),
          jsonb_build_object('uso', 'perdida_inventario', 'haber', greatest(v_dif, 0), 'descripcion', 'Ajuste de costo'),
          jsonb_build_object('uso', 'perdida_inventario', 'debe', greatest(-v_dif, 0), 'descripcion', 'Ajuste de costo')),
        d.asiento_id, trim(p_motivo));
    ELSE
      v_dif := d.sobrante_centavos - v_sale;
      v_asto := interno.asiento_sistema(d.empresa_id, v_suc, v_fecha,
        'ANULACIÓN ajuste de inventario #' || d.numero || ': ' || trim(p_motivo),
        'anulacion_ajuste_inventario', p_id_operacion,
        jsonb_build_array(
          jsonb_build_object('uso', 'ganancia_inventario', 'debe', d.sobrante_centavos, 'descripcion', 'Reversión de sobrantes'),
          jsonb_build_object('uso', 'inventario', 'haber', v_sale, 'descripcion', 'Reversión de sobrantes'),
          jsonb_build_object('uso', 'inventario', 'debe', v_entra, 'descripcion', 'Reversión de faltantes'),
          jsonb_build_object('uso', 'perdida_inventario', 'haber', v_entra, 'descripcion', 'Reversión de faltantes'),
          jsonb_build_object('uso', 'perdida_inventario', 'haber', greatest(v_dif, 0), 'descripcion', 'Ajuste de costo'),
          jsonb_build_object('uso', 'perdida_inventario', 'debe', greatest(-v_dif, 0), 'descripcion', 'Ajuste de costo')),
        d.asiento_id, trim(p_motivo));
    END IF;
  END IF;

  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.inventario_documento_anulacion (empresa_id, documento_id, fecha_contable, motivo, asiento_id,
    valor_revertido_centavos, ajuste_costo_centavos, id_operacion, anulado_por)
  VALUES (d.empresa_id, d.id, v_fecha, trim(p_motivo), v_asto, v_neto, v_dif, p_id_operacion, auth.uid())
  RETURNING * INTO v_an;
  PERFORM set_config('app.motivo', '', true);

  RETURN interno.ocultar_costos(d.empresa_id, interno.anulacion_inventario_respuesta(v_an, false),
                                ARRAY['valor_revertido_centavos', 'ajuste_costo_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 7) cargar_saldo_inicial (reemplaza la de 015; misma firma). Cambios:
--    contra "Saldos de apertura"; una carga ANULADA no cuenta como ya
--    cargada; id_operacion por tipo; total oculto sin inventario.costos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cargar_saldo_inicial(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
                                            p_lineas jsonb, p_id_operacion uuid, p_motivo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev   jsonb;
  v_b      public.bodega;
  v_doc    uuid := gen_random_uuid();
  v_num    bigint;
  l        jsonb;
  i        integer := 0;
  p        public.producto;
  v_q      numeric;
  v_costo  numeric;
  m        public.inventario_movimiento;
  v_total  bigint := 0;
  v_asto   uuid;
  v_vistos uuid[] := '{}';
  v_lin    jsonb := '[]';
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.carga_inicial', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_carga_inicial');
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN interno.ocultar_costos(p_empresa_id, v_prev, ARRAY['total_centavos', 'sobrante_centavos', 'faltante_centavos']);
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);
  v_b := interno.bodega_activa(p_empresa_id, p_bodega_id);
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'costo_unitario']);

  PERFORM interno.bloquear_libros(p_empresa_id);
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN interno.ocultar_costos(p_empresa_id, v_prev, ARRAY['total_centavos', 'sobrante_centavos', 'faltante_centavos']);
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, p_fecha);

  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, true);
    IF p.id = ANY (v_vistos) THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: el producto % está repetido (línea %).', p.codigo, i;
    END IF;
    v_vistos := v_vistos || p.id;
    v_q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, v_q, i);
    v_costo := interno.json_numero(l->'costo_unitario', 'costo_unitario', i);
    PERFORM interno.validar_costo(v_costo, i);

    IF EXISTS (SELECT 1 FROM public.inventario_movimiento x
                WHERE x.bodega_id = p_bodega_id AND x.producto_id = p.id AND x.origen = 'carga_inicial'
                  AND NOT EXISTS (SELECT 1 FROM public.inventario_documento_anulacion an
                                   WHERE an.documento_id = x.documento_id)) THEN
      IF NOT public.tiene_permiso('inventario.carga_inicial_repetir', p_empresa_id) THEN
        RAISE EXCEPTION 'SALDO_INICIAL_YA_CARGADO: el producto % ya tiene saldo inicial en la bodega %.', p.codigo, v_b.codigo;
      END IF;
      IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
        RAISE EXCEPTION 'FALTA_MOTIVO: repetir la carga inicial de % necesita motivo (mínimo 5 letras).', p.codigo;
      END IF;
    END IF;

    m := interno.mover_inventario(p_empresa_id, p_bodega_id, p.id, 'entrada', 'carga_inicial', p_fecha, v_q,
                                  round(v_q * v_costo)::bigint, 'inventario_documento', v_doc, p_id_operacion,
                                  nullif(trim(p_motivo), ''));
    v_total := v_total + m.valor_centavos;
    v_lin := v_lin || jsonb_build_object('producto_id', p.id, 'cantidad', v_q, 'costo', v_costo, 'valor', m.valor_centavos);
  END LOOP;

  v_asto := interno.asiento_sistema(p_empresa_id, v_b.sucursal_id, p_fecha,
    'Saldo inicial de inventario, bodega ' || v_b.codigo, 'carga_inicial_inventario', p_id_operacion,
    jsonb_build_array(jsonb_build_object('uso', 'inventario',          'debe',  v_total),
                      jsonb_build_object('uso', 'apertura_inventario', 'haber', v_total)));

  v_num := interno.siguiente_numero(p_empresa_id, 'inventario_carga_inicial');
  PERFORM set_config('app.motivo', coalesce(trim(p_motivo), ''), true);
  INSERT INTO public.inventario_documento (id, empresa_id, tipo, numero, bodega_id, fecha_contable, motivo,
    asiento_id, total_centavos, id_operacion, creado_por)
  VALUES (v_doc, p_empresa_id, 'carga_inicial', v_num, p_bodega_id, p_fecha, nullif(trim(p_motivo), ''),
    v_asto, v_total, p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  INSERT INTO public.inventario_documento_linea (empresa_id, documento_id, linea, producto_id,
    cantidad, costo_unitario, valor_centavos)
  SELECT p_empresa_id, v_doc, x.n, (x.l->>'producto_id')::uuid, (x.l->>'cantidad')::numeric,
         (x.l->>'costo')::numeric, (x.l->>'valor')::bigint
  FROM jsonb_array_elements(v_lin) WITH ORDINALITY AS x(l, n);

  RETURN interno.ocultar_costos(p_empresa_id,
    jsonb_build_object('documento_id', v_doc, 'tipo', 'carga_inicial', 'numero', v_num,
                       'asiento_id', v_asto, 'total_centavos', v_total, 'duplicado', false),
    ARRAY['total_centavos']);
END $$;

-- ---------------------------------------------------------------------
-- 8) id_operacion por tipo: suma las anulaciones de inventario
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.tipo_operacion(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  IF p_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'compra';
  END IF;
  IF EXISTS (SELECT 1 FROM public.compra x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_compra';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pago_proveedor x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'pago_proveedor';
  END IF;
  SELECT 'inventario_' || d.tipo INTO v FROM public.inventario_documento d
   WHERE d.empresa_id = p_empresa_id AND d.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_documento_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'anulacion_inventario';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tercero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'tercero';
  END IF;
  IF EXISTS (SELECT 1 FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'producto';
  END IF;
  SELECT a.origen INTO v FROM public.asiento a WHERE a.empresa_id = p_empresa_id AND a.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN CASE v WHEN 'manual' THEN 'asiento' WHEN 'anulacion' THEN 'anulacion_asiento' ELSE 'asiento_' || v END;
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 9) Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.cuenta_de(uuid, text),
  interno.fracciones_con_existencia(),
  interno.anulacion_inventario_respuesta(public.inventario_documento_anulacion, boolean)
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.reactivar_sucursal(uuid, uuid, text),
  public.reactivar_caja(uuid, uuid, text),
  public.reactivar_bodega(uuid, uuid, text),
  public.reactivar_categoria(uuid, uuid, text),
  public.reactivar_campo_extra(uuid, uuid, text),
  public.anular_documento_inventario(uuid, text, uuid, date)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.reactivar_sucursal(uuid, uuid, text),
  public.reactivar_caja(uuid, uuid, text),
  public.reactivar_bodega(uuid, uuid, text),
  public.reactivar_categoria(uuid, uuid, text),
  public.reactivar_campo_extra(uuid, uuid, text),
  public.anular_documento_inventario(uuid, text, uuid, date)
TO authenticated;
