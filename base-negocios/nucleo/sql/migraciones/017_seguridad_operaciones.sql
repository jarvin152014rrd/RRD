-- =====================================================================
-- 017_seguridad_operaciones.sql  -  Núcleo 0.4.0
--
--   * Permiso nuevo terceros.ver (financiero): sin él no se leen clientes
--     ni proveedores (ni sus límites de crédito). El proveedor del sistema
--     ya no los ve salvo con acceso de soporte vigente.
--   * Rol "contador": solo lectura (contabilidad, reportes, bitácora,
--     clientes y proveedores, compras y CxP, existencias con costos).
--     Solo el dueño lo crea; nunca recibe permisos que muevan los libros.
--   * Políticas RLS más rápidas: empresas_con_permiso(permiso) se evalúa
--     UNA vez por consulta (subconsulta sin referencia a la fila), en vez
--     de llamar tiene_permiso() por cada fila. Índices nuevos.
--   * id_operacion por TIPO: un reintento solo se reconoce si es del mismo
--     tipo de operación; si el id ya se usó en otra cosa: ID_OPERACION_USADO.
--   * anular_asiento: la fecha no puede ser anterior al asiento original.
--   * ajustar_inventario y trasladar_inventario no devuelven costos a quien
--     no tiene inventario.costos.
-- Las RPC que se corrigen aquí se "envuelven": la de 005/013/015/016 pasa al
-- esquema interno (nombre *_base) y la pública revisa y luego la llama.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('ID_OPERACION_USADO', 'El código interno de esta operación ya se usó en otra operación distinta.',
   'Vuelva a intentar: la app debe generar un id_operacion nuevo para cada operación. Si se repite, avise a soporte.');

-- ---------------------------------------------------------------------
-- 1) Permiso terceros.ver y rol contador
-- ---------------------------------------------------------------------
INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('terceros.ver', 'Ver clientes y proveedores (datos de contacto y límites de crédito)', false, true);

INSERT INTO public.rol (codigo, nombre, descripcion) VALUES
  ('contador', 'Contador', 'Solo lectura: contabilidad, reportes, bitácora, clientes y proveedores, compras y valor del inventario.');

-- Criterio (decisión 0.4.0): el contador SÍ necesita costos y valor del
-- inventario (para el balance y el costo de ventas); no recibe nada que
-- mueva los libros ni administre el negocio.
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'terceros.ver'), ('admin', 'terceros.ver'), ('cajero', 'terceros.ver'), ('vendedor', 'terceros.ver'),
  ('contador', 'contabilidad.ver'), ('contador', 'bitacora.ver'), ('contador', 'terceros.ver'),
  ('contador', 'compras.ver'), ('contador', 'inventario.ver'), ('contador', 'inventario.costos');

-- Empresas ya instaladas: solo las filas nuevas (no se tocan permisos que
-- el dueño ya haya quitado o dado).
SELECT set_config('app.motivo', 'Núcleo 0.4.0: permiso terceros.ver y rol contador', true);
INSERT INTO public.rol_permiso (empresa_id, rol, permiso)
SELECT e.id, p.rol, p.permiso
  FROM public.empresa e
  JOIN interno.plantilla_rol_permiso p ON p.permiso = 'terceros.ver' OR p.rol = 'contador'
ON CONFLICT DO NOTHING;
SELECT set_config('app.motivo', '', true);

-- Reglas de la tabla rol x permiso (reemplaza la de 012):
--   proveedor: nada; permisos solo del dueño: solo el dueño;
--   contador: solo permisos de lectura (nunca de movimiento ni de administrar).
CREATE OR REPLACE FUNCTION interno.validar_rol_permiso() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_p public.permiso;
BEGIN
  IF NEW.rol = 'proveedor' THEN
    RAISE EXCEPTION 'PROHIBIDO: el rol proveedor no recibe permisos ("%"). Para soporte, el dueño da un acceso temporal.', NEW.permiso;
  END IF;
  IF NEW.permiso IN ('soporte.otorgar', 'permisos.editar', 'periodos.reabrir', 'empresa.configurar')
     AND NEW.rol <> 'dueno' THEN
    RAISE EXCEPTION 'PROHIBIDO: el permiso "%" es solo del dueño.', NEW.permiso;
  END IF;
  IF NEW.rol = 'contador' THEN
    SELECT * INTO v_p FROM public.permiso WHERE codigo = NEW.permiso;
    IF v_p.es_movimiento OR NOT (v_p.es_financiero OR v_p.codigo LIKE '%.ver') THEN
      RAISE EXCEPTION 'PROHIBIDO: el contador es de solo lectura; no recibe el permiso "%".', NEW.permiso;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- 2) Empresas donde el usuario conectado tiene un permiso.
--    Misma regla que tiene_permiso() (proveedor solo con soporte vigente
--    y solo lectura financiera). Sin usuario: service_role o el
--    administrador de la base ven todas; anon/authenticated sin usuario, ninguna.
--    En políticas y vistas se usa como
--      empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('...')))
--    El (SELECT ...) no depende de la fila: PostgreSQL lo calcula UNA vez
--    por consulta (InitPlan), no una vez por fila.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.empresas_con_permiso(p_permiso text) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT ue.empresa_id
    FROM public.usuario_empresa ue
    JOIN public.rol_permiso rp ON rp.empresa_id = ue.empresa_id AND rp.rol = ue.rol
   WHERE ue.user_id = auth.uid() AND ue.activo AND ue.rol <> 'proveedor' AND rp.permiso = p_permiso
  UNION
  SELECT ue.empresa_id
    FROM public.usuario_empresa ue
    JOIN public.permiso p        ON p.codigo = p_permiso
    JOIN public.acceso_soporte s ON s.empresa_id = ue.empresa_id
   WHERE ue.user_id = auth.uid() AND ue.activo AND ue.rol = 'proveedor'
     AND p.es_financiero AND NOT p.es_movimiento
     AND s.revocado_en IS NULL AND now() >= s.desde AND now() < s.vence_en
  UNION
  SELECT e.id FROM public.empresa e
   WHERE auth.uid() IS NULL AND coalesce(auth.role(), '') NOT IN ('anon', 'authenticated')
$$;
REVOKE EXECUTE ON FUNCTION public.empresas_con_permiso(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.empresas_con_permiso(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3) Políticas RLS (mismas reglas, evaluadas una vez por consulta)
-- ---------------------------------------------------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('asiento', 'contabilidad.ver'), ('asiento_linea', 'contabilidad.ver'), ('bitacora', 'bitacora.ver'),
      ('tercero', 'terceros.ver'),
      ('inventario_alerta', 'inventario.ver'), ('inventario_saldo', 'inventario.costos'),
      ('inventario_movimiento', 'inventario.costos'), ('inventario_documento', 'inventario.costos'),
      ('inventario_documento_linea', 'inventario.costos'),
      ('compra', 'compras.ver'), ('compra_linea', 'compras.ver'), ('pago_proveedor', 'compras.ver')) AS x(tabla, permiso)
  LOOP
    EXECUTE format('DROP POLICY leer ON public.%I', r.tabla);
    EXECUTE format('CREATE POLICY leer ON public.%I FOR SELECT TO authenticated
                    USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso(%L))))', r.tabla, r.permiso);
  END LOOP;
END $$;

-- v_existencia (misma forma que en 015): cantidades con inventario.ver,
-- costo y valor solo con inventario.costos; filtros evaluados una vez.
CREATE OR REPLACE VIEW public.v_existencia AS
  SELECT s.empresa_id, s.bodega_id, b.codigo AS bodega_codigo, b.nombre AS bodega_nombre, b.sucursal_id,
         s.producto_id, p.codigo, p.codigo_barras, p.nombre, u.codigo AS unidad,
         s.cantidad, p.stock_minimo, (s.cantidad < p.stock_minimo) AS bajo_minimo,
         CASE WHEN s.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) THEN s.costo_promedio END AS costo_promedio,
         CASE WHEN s.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.costos'))) THEN s.valor_centavos END AS valor_centavos,
         s.actualizado_en
  FROM public.inventario_saldo s
  JOIN public.bodega   b ON b.id = s.bodega_id
  JOIN public.producto p ON p.id = s.producto_id
  JOIN public.unidad   u ON u.id = p.unidad_id
  WHERE s.empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('inventario.ver')));

-- ---------------------------------------------------------------------
-- 4) Índices (fechas, producto/bodega y búsquedas por id_operacion)
-- ---------------------------------------------------------------------
CREATE INDEX inventario_mov_bodega_producto ON public.inventario_movimiento (bodega_id, producto_id, id);
CREATE INDEX inventario_mov_salidas_fecha   ON public.inventario_movimiento (bodega_id, producto_id, fecha_contable)
  WHERE cantidad < 0;
CREATE INDEX inventario_mov_empresa_fecha   ON public.inventario_movimiento (empresa_id, fecha_contable);
CREATE INDEX inventario_doc_empresa_fecha   ON public.inventario_documento (empresa_id, fecha_contable);
CREATE INDEX inventario_alerta_empresa      ON public.inventario_alerta (empresa_id, creado_en);
CREATE INDEX compra_empresa_fecha           ON public.compra (empresa_id, fecha_contable);
CREATE INDEX compra_anulacion_operacion     ON public.compra (empresa_id, anulacion_id_operacion)
  WHERE anulacion_id_operacion IS NOT NULL;
CREATE INDEX pago_proveedor_empresa_fecha   ON public.pago_proveedor (empresa_id, fecha_contable);
CREATE INDEX pago_proveedor_proveedor       ON public.pago_proveedor (empresa_id, proveedor_id);
CREATE INDEX asiento_empresa_origen         ON public.asiento (empresa_id, origen, fecha_contable);

-- ---------------------------------------------------------------------
-- 5) id_operacion por tipo de operación
-- ---------------------------------------------------------------------
-- ¿Para qué se usó ya este id_operacion en la empresa? NULL = no se usó.
-- (Se amplía en 018 y 019 cuando hay tablas nuevas.)
CREATE FUNCTION interno.tipo_operacion(p_empresa_id uuid, p_id uuid) RETURNS text
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

-- Error claro si el id_operacion ya se usó para OTRO tipo de operación.
CREATE FUNCTION interno.exigir_tipo_operacion(p_empresa_id uuid, p_id uuid, p_tipo text) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text := interno.tipo_operacion(p_empresa_id, p_id);
BEGIN
  IF v IS NOT NULL AND v <> p_tipo THEN
    RAISE EXCEPTION 'ID_OPERACION_USADO: el id_operacion % ya se usó en esta empresa para otra operación (%); esta es "%". Use un id_operacion nuevo.',
      p_id, v, p_tipo;
  END IF;
END $$;

-- Quita los montos de costo de una respuesta si el usuario no tiene
-- inventario.costos (los deja en null y marca "costos_ocultos").
CREATE FUNCTION interno.ocultar_costos(p_empresa_id uuid, p_respuesta jsonb, p_claves text[]) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text;
BEGIN
  IF p_respuesta IS NULL OR public.puede_leer(p_empresa_id, 'inventario.costos') THEN
    RETURN p_respuesta;
  END IF;
  FOREACH k IN ARRAY p_claves LOOP
    IF p_respuesta ? k THEN
      p_respuesta := jsonb_set(p_respuesta, ARRAY[k], 'null'::jsonb);
    END IF;
  END LOOP;
  RETURN p_respuesta || '{"costos_ocultos": true}'::jsonb;
END $$;

-- ---------------------------------------------------------------------
-- 6) Envolver RPC existentes (misma firma, misma respuesta)
-- ---------------------------------------------------------------------
ALTER FUNCTION public.registrar_asiento(uuid, date, text, jsonb, uuid, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.registrar_asiento(uuid, date, text, jsonb, uuid, uuid) RENAME TO registrar_asiento_base;
ALTER FUNCTION public.anular_asiento(uuid, text, uuid, date) SET SCHEMA interno;
ALTER FUNCTION interno.anular_asiento(uuid, text, uuid, date) RENAME TO anular_asiento_base;
ALTER FUNCTION public.registrar_compra(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.registrar_compra(uuid, jsonb, uuid) RENAME TO registrar_compra_base;
ALTER FUNCTION public.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid) RENAME TO ajustar_inventario_base;
ALTER FUNCTION public.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text) SET SCHEMA interno;
ALTER FUNCTION interno.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text) RENAME TO trasladar_inventario_base;
ALTER FUNCTION public.crear_tercero(uuid, jsonb, uuid) SET SCHEMA interno;
ALTER FUNCTION interno.crear_tercero(uuid, jsonb, uuid) RENAME TO crear_tercero_base;

CREATE FUNCTION public.registrar_asiento(p_empresa_id uuid, p_fecha date, p_descripcion text, p_lineas jsonb,
                                         p_id_operacion uuid, p_sucursal_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'asientos.registrar');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'asiento');
  RETURN interno.registrar_asiento_base(p_empresa_id, p_fecha, p_descripcion, p_lineas, p_id_operacion, p_sucursal_id);
END $$;

-- La anulación no puede tener fecha anterior al asiento original. Sin
-- fecha: hoy, o la del original si este quedó con fecha futura.
CREATE FUNCTION public.anular_asiento(p_asiento_id uuid, p_motivo text, p_id_operacion uuid DEFAULT NULL,
                                      p_fecha date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_orig  public.asiento;
  v_fecha date;
BEGIN
  SELECT * INTO v_orig FROM public.asiento WHERE id = p_asiento_id;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: el asiento no existe.';
  END IF;
  PERFORM interno.exigir_escritura(v_orig.empresa_id, 'asientos.anular');
  PERFORM interno.exigir_tipo_operacion(v_orig.empresa_id, p_id_operacion, 'anulacion_asiento');
  v_fecha := coalesce(p_fecha, greatest(public.hoy_local(v_orig.empresa_id), v_orig.fecha_contable));
  PERFORM interno.exigir_fecha_contable(v_orig.empresa_id, v_fecha);
  IF v_fecha < v_orig.fecha_contable THEN
    RAISE EXCEPTION 'FECHA_INVALIDA: la anulación (%) no puede tener fecha anterior al asiento #% (%).',
      to_char(v_fecha, 'DD/MM/YYYY'), v_orig.numero, to_char(v_orig.fecha_contable, 'DD/MM/YYYY');
  END IF;
  RETURN interno.anular_asiento_base(p_asiento_id, p_motivo, p_id_operacion, v_fecha);
END $$;

CREATE FUNCTION public.registrar_compra(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'compras.registrar', 'compras');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'compra');
  RETURN interno.registrar_compra_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

CREATE FUNCTION public.ajustar_inventario(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
                                          p_lineas jsonb, p_motivo text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.ajustar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_ajuste');
  RETURN interno.ocultar_costos(p_empresa_id,
    interno.ajustar_inventario_base(p_empresa_id, p_bodega_id, p_fecha, p_lineas, p_motivo, p_id_operacion),
    ARRAY['sobrante_centavos', 'faltante_centavos', 'total_centavos']);
END $$;

CREATE FUNCTION public.trasladar_inventario(p_empresa_id uuid, p_bodega_origen_id uuid, p_bodega_destino_id uuid,
                                            p_fecha date, p_lineas jsonb, p_id_operacion uuid,
                                            p_nota text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.trasladar', 'inventario');
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'inventario_traslado');
  RETURN interno.ocultar_costos(p_empresa_id,
    interno.trasladar_inventario_base(p_empresa_id, p_bodega_origen_id, p_bodega_destino_id, p_fecha,
                                      p_lineas, p_id_operacion, p_nota),
    ARRAY['sobrante_centavos', 'faltante_centavos', 'total_centavos']);
END $$;

CREATE FUNCTION public.crear_tercero(p_empresa_id uuid, p_datos jsonb, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'terceros.editar', NULL);
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'tercero');
  RETURN interno.crear_tercero_base(p_empresa_id, p_datos, p_id_operacion);
END $$;

-- ---------------------------------------------------------------------
-- 7) Permisos de ejecución
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.registrar_asiento_base(uuid, date, text, jsonb, uuid, uuid),
  interno.anular_asiento_base(uuid, text, uuid, date),
  interno.registrar_compra_base(uuid, jsonb, uuid),
  interno.ajustar_inventario_base(uuid, uuid, date, jsonb, text, uuid),
  interno.trasladar_inventario_base(uuid, uuid, uuid, date, jsonb, uuid, text),
  interno.crear_tercero_base(uuid, jsonb, uuid),
  interno.tipo_operacion(uuid, uuid),
  interno.exigir_tipo_operacion(uuid, uuid, text),
  interno.ocultar_costos(uuid, jsonb, text[])
FROM PUBLIC, anon, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION
  public.registrar_asiento(uuid, date, text, jsonb, uuid, uuid),
  public.anular_asiento(uuid, text, uuid, date),
  public.registrar_compra(uuid, jsonb, uuid),
  public.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid),
  public.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text),
  public.crear_tercero(uuid, jsonb, uuid)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.registrar_asiento(uuid, date, text, jsonb, uuid, uuid),
  public.anular_asiento(uuid, text, uuid, date),
  public.registrar_compra(uuid, jsonb, uuid),
  public.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid),
  public.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text),
  public.crear_tercero(uuid, jsonb, uuid)
TO authenticated;
