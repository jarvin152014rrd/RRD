-- =====================================================================
-- 032_limites_ficha_proveedor.sql  -  Núcleo 0.8.0: límites del contrato
-- y ficha del proveedor.
--
--   limite_contrato   usuarios, cajas, sucursales y bodegas por empresa
--       (null = sin límite). La escribe SOLO el proveedor (service_role,
--       aplicar_ficha.sh, nuevo_cliente.sh); nunca el dueño ni el admin.
--       Crear o reactivar uno más allá del límite: LIMITE_CONTRATO ("Llegaste
--       al máximo de tu plan. Solicita una ampliación a tu proveedor.").
--       Los desactivados no cuentan; el usuario del proveedor tampoco.
--       Nunca bloquea operar ni borra nada: si el límite baja por debajo de
--       lo que ya existe, nada se desactiva; solo impide agregar más.
--       Lo revisa un trigger en cada tabla (vale para toda RPC de crear o
--       reactivar, hoy y mañana); el proveedor con su llave no tiene tope.
--   solicitud_proveedor   "Solicitar ampliación" / "Solicitar módulo":
--       solicitar_al_proveedor (dueño y admin, aun con licencia vencida);
--       el proveedor las lee con su llave (lista_clientes.sh) y responde con
--       responder_solicitud_proveedor.
--   mi_perfil()->'limites': límite y uso actual de cada cosa.
--   vista_previa_ficha / aplicar_ficha: lo que usa herramientas/aplicar_ficha.sh
--       (solo la llave del proveedor): módulos (en el orden que piden las
--       dependencias), perfil, licencia y límites en una transacción, con
--       bitácora. Nunca borra datos.
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('LIMITE_CONTRATO', 'Llegaste al máximo de tu plan. Solicita una ampliación a tu proveedor.',
   'Use "Solicitar ampliación" o desactive uno que ya no use. Nada de lo que ya tiene se pierde ni se bloquea.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('proveedor.solicitar', 'Pedir al proveedor una ampliación del plan, un módulo u otra cosa', false, false);
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES ('dueno', 'proveedor.solicitar'), ('admin', 'proveedor.solicitar');
SELECT interno.repartir_permisos(ARRAY['proveedor.solicitar'], 'Núcleo 0.8.0: dueño y admin piden ampliaciones al proveedor');

-- ---------------------------------------------------------------------
-- 1) Límites del contrato
-- ---------------------------------------------------------------------
CREATE TABLE public.limite_contrato (
  empresa_id      uuid PRIMARY KEY REFERENCES public.empresa(id),
  usuarios        integer CHECK (usuarios BETWEEN 0 AND 100000),
  cajas           integer CHECK (cajas BETWEEN 0 AND 100000),
  sucursales      integer CHECK (sucursales BETWEEN 0 AND 100000),
  bodegas         integer CHECK (bodegas BETWEEN 0 AND 100000),
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.limite_contrato ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.limite_contrato FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
GRANT SELECT ON public.limite_contrato TO authenticated, service_role;
GRANT INSERT, UPDATE ON public.limite_contrato TO service_role;   -- sin DELETE
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.limite_contrato FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.limite_contrato
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los límites se cambian, no se borran (null = sin límite).');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.limite_contrato
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');

-- Uso actual (solo lo activo; el usuario del proveedor no cuenta).
CREATE FUNCTION interno.uso_limite(p_empresa_id uuid, p_cosa text) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN CASE p_cosa
    WHEN 'usuarios'   THEN (SELECT count(*) FROM public.usuario_empresa x WHERE x.empresa_id = p_empresa_id AND x.activo AND x.rol <> 'proveedor')
    WHEN 'cajas'      THEN (SELECT count(*) FROM public.caja x WHERE x.empresa_id = p_empresa_id AND x.activa)
    WHEN 'sucursales' THEN (SELECT count(*) FROM public.sucursal x WHERE x.empresa_id = p_empresa_id AND x.activa)
    WHEN 'bodegas'    THEN (SELECT count(*) FROM public.bodega x WHERE x.empresa_id = p_empresa_id AND x.activa)
  END;
END $$;

-- {"usuarios": {"limite": 5, "uso": 3}, ...}  (limite null = sin límite)
CREATE FUNCTION interno.limites_y_uso(p_empresa_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_object_agg(c.cosa, jsonb_build_object('limite', c.limite, 'uso', interno.uso_limite(p_empresa_id, c.cosa)))
    FROM (SELECT 'usuarios' AS cosa, l.usuarios AS limite FROM (SELECT 1) u LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id
          UNION ALL SELECT 'cajas', l.cajas FROM (SELECT 1) u LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id
          UNION ALL SELECT 'sucursales', l.sucursales FROM (SELECT 1) u LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id
          UNION ALL SELECT 'bodegas', l.bodegas FROM (SELECT 1) u LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id) c
$$;

-- Trigger de usuario_empresa, caja, sucursal y bodega: algo que QUEDA activo
-- (nuevo o reactivado) no puede pasar el límite. Solo usuarios de la app
-- (auth.uid()); el proveedor con su llave instala sin tope.
CREATE FUNCTION interno.revisar_limite_contrato() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cosa   text;
  v_activo boolean;
  v_antes  boolean := false;
  v_lim    integer;
  v_uso    integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  v_cosa := CASE TG_TABLE_NAME WHEN 'usuario_empresa' THEN 'usuarios' WHEN 'caja' THEN 'cajas'
                               WHEN 'sucursal' THEN 'sucursales' WHEN 'bodega' THEN 'bodegas' END;
  IF TG_TABLE_NAME = 'usuario_empresa' THEN
    v_activo := NEW.activo AND NEW.rol <> 'proveedor';
    IF TG_OP = 'UPDATE' THEN v_antes := OLD.activo AND OLD.rol <> 'proveedor'; END IF;
  ELSE
    v_activo := NEW.activa;
    IF TG_OP = 'UPDATE' THEN v_antes := OLD.activa; END IF;
  END IF;
  IF NOT v_activo OR v_antes THEN
    RETURN NEW;
  END IF;
  -- El candado de la fila de límites ordena a dos que agregan a la vez.
  EXECUTE format('SELECT %I FROM public.limite_contrato WHERE empresa_id = $1 FOR UPDATE', v_cosa) INTO v_lim USING NEW.empresa_id;
  IF v_lim IS NULL THEN
    RETURN NEW;
  END IF;
  v_uso := interno.uso_limite(NEW.empresa_id, v_cosa);
  IF v_uso + 1 > v_lim THEN
    RAISE EXCEPTION 'LIMITE_CONTRATO: Llegaste al máximo de tu plan. Solicita una ampliación a tu proveedor. (%: % de %)', v_cosa, v_uso, v_lim;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER revisar_limite BEFORE INSERT OR UPDATE OF activo, rol ON public.usuario_empresa
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_limite_contrato();
CREATE TRIGGER revisar_limite BEFORE INSERT OR UPDATE OF activa ON public.caja
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_limite_contrato();
CREATE TRIGGER revisar_limite BEFORE INSERT OR UPDATE OF activa ON public.sucursal
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_limite_contrato();
CREATE TRIGGER revisar_limite BEFORE INSERT OR UPDATE OF activa ON public.bodega
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_limite_contrato();

-- ---------------------------------------------------------------------
-- 2) Solicitudes al proveedor
-- ---------------------------------------------------------------------
CREATE TABLE public.solicitud_proveedor (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id      uuid NOT NULL REFERENCES public.empresa(id),
  numero          bigint NOT NULL,
  tipo            text NOT NULL CHECK (tipo IN ('ampliacion', 'modulo', 'otro')),
  detalle         text NOT NULL CHECK (length(trim(detalle)) BETWEEN 5 AND 1000),
  solicitado_por  uuid NOT NULL,
  solicitado_en   timestamptz NOT NULL DEFAULT now(),
  estado          text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'atendida', 'rechazada')),
  respuesta       text,
  respondido_en   timestamptz,
  id_operacion    uuid NOT NULL,
  UNIQUE (empresa_id, numero),
  UNIQUE (empresa_id, id_operacion),
  CHECK ((estado = 'pendiente') = (respondido_en IS NULL))
);
CREATE FUNCTION interno.proteger_solicitud_proveedor() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.empresa_id, NEW.numero, NEW.tipo, NEW.detalle, NEW.solicitado_por, NEW.solicitado_en, NEW.id_operacion)
     IS DISTINCT FROM (OLD.id, OLD.empresa_id, OLD.numero, OLD.tipo, OLD.detalle, OLD.solicitado_por, OLD.solicitado_en, OLD.id_operacion)
     OR OLD.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'PROHIBIDO: una solicitud solo se responde una vez y su texto no cambia.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proteger BEFORE UPDATE ON public.solicitud_proveedor FOR EACH ROW EXECUTE FUNCTION interno.proteger_solicitud_proveedor();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.solicitud_proveedor FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.solicitud_proveedor
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las solicitudes no se borran.');
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.solicitud_proveedor
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
ALTER TABLE public.solicitud_proveedor ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.solicitud_proveedor FOR SELECT TO authenticated
  USING (empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('proveedor.solicitar'))));
GRANT SELECT ON public.solicitud_proveedor TO authenticated, service_role;

-- RPC: solicitar_al_proveedor(empresa, tipo, detalle, id_operacion)   proveedor.solicitar (dueño, admin)
-- Funciona aun con la licencia vencida (para pedir la renovación).
CREATE FUNCTION public.solicitar_al_proveedor(p_empresa_id uuid, p_tipo text, p_detalle text, p_id_operacion uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.solicitud_proveedor;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'proveedor.solicitar', NULL, false);
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  PERFORM interno.exigir_tipo_operacion(p_empresa_id, p_id_operacion, 'solicitud_proveedor');
  IF coalesce(p_tipo, '') NOT IN ('ampliacion', 'modulo', 'otro') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el tipo es "ampliacion", "modulo" u "otro".';
  END IF;
  IF length(trim(coalesce(p_detalle, ''))) NOT BETWEEN 5 AND 1000 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba qué necesita (de 5 a 1000 letras).';
  END IF;
  PERFORM interno.reservar_operacion(p_empresa_id, p_id_operacion, 'solicitud_proveedor');
  SELECT * INTO s FROM public.solicitud_proveedor x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id_operacion;
  IF s.id IS NULL THEN
    INSERT INTO public.solicitud_proveedor (empresa_id, numero, tipo, detalle, solicitado_por, id_operacion)
    VALUES (p_empresa_id, interno.siguiente_numero(p_empresa_id, 'solicitud_proveedor'), p_tipo, trim(p_detalle), auth.uid(), p_id_operacion)
    RETURNING * INTO s;
  END IF;
  RETURN jsonb_build_object('solicitud_id', s.id, 'numero', s.numero, 'tipo', s.tipo, 'estado', s.estado,
                            'mensaje', 'Su solicitud quedó registrada; su proveedor la atenderá.');
END $$;

-- RPC: responder_solicitud_proveedor(solicitud, estado, respuesta)   solo la llave del proveedor
CREATE FUNCTION public.responder_solicitud_proveedor(p_solicitud_id uuid, p_estado text, p_respuesta text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.solicitud_proveedor;
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  IF coalesce(p_estado, '') NOT IN ('atendida', 'rechazada') THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el estado es "atendida" o "rechazada".';
  END IF;
  IF length(trim(coalesce(p_respuesta, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba la respuesta (mínimo 5 letras).';
  END IF;
  UPDATE public.solicitud_proveedor SET estado = p_estado, respuesta = trim(p_respuesta), respondido_en = now()
   WHERE id = p_solicitud_id RETURNING * INTO s;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la solicitud no existe.';
  END IF;
  RETURN jsonb_build_object('solicitud_id', s.id, 'estado', s.estado);
END $$;

-- ---------------------------------------------------------------------
-- 3) Ficha del proveedor: vista previa y aplicar (solo service_role)
--    p_cambios = {"modulos": {"ventas": true, "compras": false, ...},
--                 "perfil": "pequeno" | null, "licencia": {"vence_el": "2026-12-31", "dias_gracia": 5},
--                 "limites": {"usuarios": 5, "cajas": 1, "sucursales": 1, "bodegas": null}}   (null = sin límite)
--    Lo que no viene, no cambia.
-- ---------------------------------------------------------------------
-- Profundidad de un módulo en el árbol de dependencias (contabilidad = 0).
CREATE FUNCTION interno.nivel_modulo(p_modulo text) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH RECURSIVE r(m, n) AS (
    SELECT p_modulo, 0
    UNION ALL
    SELECT d.requiere, r.n + 1 FROM public.modulo_dependencia d JOIN r ON d.modulo = r.m WHERE r.n < 20)
  SELECT max(n) FROM r
$$;

CREATE FUNCTION interno.exigir_proveedor_llave() RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NOT NULL OR coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'SIN_PERMISO: esto lo hace solo el proveedor con su conexión de instalación (herramientas/aplicar_ficha.sh).';
  END IF;
END $$;

CREATE FUNCTION interno.cambios_ficha(p_empresa_id uuid, p_cambios jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  e         public.empresa;
  l         public.licencia;
  k         text;
  v_final   text[];
  v_act     jsonb := '[]';
  v_des     jsonb := '[]';
  v_err     jsonb := '[]';
  v_otros   jsonb := '[]';
  v_lic     jsonb;
  v_perfil  jsonb;
  v_vence   date;
  v_gracia  integer;
  v_limact  jsonb := interno.limites_y_uso(p_empresa_id);
  v_lims    jsonb;
  v_limn    jsonb := '{}';
  r         record;
BEGIN
  SELECT * INTO e FROM public.empresa x WHERE x.id = p_empresa_id;
  IF e.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la empresa no existe en esta base.';
  END IF;
  IF jsonb_typeof(p_cambios) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: los cambios deben ser un objeto JSON.';
  END IF;
  PERFORM interno.exigir_claves(p_cambios, ARRAY['modulos', 'perfil', 'licencia', 'limites']);

  -- Módulos: estado final = lo de hoy + lo que dice la ficha.
  SELECT coalesce(array_agg(m.modulo), '{}') INTO v_final FROM public.modulo_activo m WHERE m.empresa_id = p_empresa_id AND m.activo;
  IF coalesce(p_cambios->'modulos', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'modulos') <> 'object' THEN
      RAISE EXCEPTION 'DATO_INVALIDO: "modulos" es un objeto {"ventas": true, ...}.';
    END IF;
    FOR k IN SELECT jsonb_object_keys(p_cambios->'modulos') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.modulo x WHERE x.codigo = k) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" no existe.', k;
      END IF;
      IF jsonb_typeof(p_cambios->'modulos'->k) <> 'boolean' THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el módulo "%" va con true o false.', k;
      END IF;
      IF (p_cambios->'modulos'->>k)::boolean AND NOT k = ANY (v_final) THEN
        v_final := v_final || k;
      ELSIF NOT (p_cambios->'modulos'->>k)::boolean AND k = ANY (v_final) THEN
        v_final := array_remove(v_final, k);
      END IF;
    END LOOP;
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo), m.codigo), '[]') INTO v_act
      FROM public.modulo m
     WHERE m.codigo = ANY (v_final) AND NOT public.modulo_esta_activo(p_empresa_id, m.codigo);
    SELECT coalesce(jsonb_agg(m.codigo ORDER BY interno.nivel_modulo(m.codigo) DESC, m.codigo), '[]') INTO v_des
      FROM public.modulo m
     WHERE NOT m.codigo = ANY (v_final) AND public.modulo_esta_activo(p_empresa_id, m.codigo);
    FOR r IN SELECT d.modulo, d.requiere FROM public.modulo_dependencia d
              WHERE d.modulo = ANY (v_final) AND NOT d.requiere = ANY (v_final) ORDER BY 1, 2 LOOP
      v_err := v_err || to_jsonb(format('El módulo "%s" necesita "%s": actívelo también o apague "%s".', r.modulo, r.requiere, r.modulo));
    END LOOP;
    IF (SELECT count(*) FROM unnest(v_final) x WHERE x LIKE 'fiscal\_%') > 1 THEN
      v_err := v_err || to_jsonb('Solo un régimen fiscal activo a la vez.'::text);
    END IF;
  END IF;

  -- Perfil.
  IF coalesce(p_cambios->'perfil', 'null'::jsonb) <> 'null'::jsonb THEN
    IF jsonb_typeof(p_cambios->'perfil') <> 'string' THEN
      RAISE EXCEPTION 'PERFIL_INVALIDO: el perfil es pequeno, mediano o grande.';
    END IF;
    PERFORM interno.perfil_de(p_cambios->>'perfil');
    IF e.perfil IS DISTINCT FROM p_cambios->>'perfil' THEN
      v_perfil := jsonb_build_object('actual', e.perfil, 'nuevo', p_cambios->>'perfil',
        'detalle', interno.cambios_perfil(p_empresa_id, p_cambios->>'perfil'));
    END IF;
  END IF;

  -- Licencia.
  IF coalesce(p_cambios->'licencia', 'null'::jsonb) <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_cambios->'licencia', ARRAY['vence_el', 'dias_gracia']);
    v_vence := interno.json_fecha(p_cambios->'licencia'->'vence_el', 'vence_el');
    IF v_vence IS NULL THEN
      RAISE EXCEPTION 'DATO_INVALIDO: la licencia necesita "vence_el" (AAAA-MM-DD).';
    END IF;
    IF coalesce(p_cambios->'licencia'->'dias_gracia', 'null'::jsonb) <> 'null'::jsonb THEN
      IF jsonb_typeof(p_cambios->'licencia'->'dias_gracia') <> 'number'
         OR (p_cambios->'licencia'->>'dias_gracia') !~ '^[0-9]{1,2}$' OR (p_cambios->'licencia'->>'dias_gracia')::integer > 60 THEN
        RAISE EXCEPTION 'DATO_INVALIDO: "dias_gracia" es un número entero de 0 a 60.';
      END IF;
      v_gracia := (p_cambios->'licencia'->>'dias_gracia')::integer;
    END IF;
    SELECT * INTO l FROM public.licencia x WHERE x.empresa_id = p_empresa_id;
    v_gracia := coalesce(v_gracia, l.dias_gracia, 5);
    IF (l.vence_el, l.dias_gracia) IS DISTINCT FROM (v_vence, v_gracia) THEN
      v_lic := jsonb_build_object('actual', CASE WHEN l.empresa_id IS NOT NULL THEN jsonb_build_object('vence_el', to_char(l.vence_el, 'YYYY-MM-DD'), 'dias_gracia', l.dias_gracia) END,
                                  'nuevo', jsonb_build_object('vence_el', to_char(v_vence, 'YYYY-MM-DD'), 'dias_gracia', v_gracia));
    END IF;
  END IF;

  -- Límites del contrato (lo que no viene no cambia; null = sin límite).
  IF coalesce(p_cambios->'limites', 'null'::jsonb) <> 'null'::jsonb THEN
    PERFORM interno.exigir_claves(p_cambios->'limites', ARRAY['usuarios', 'cajas', 'sucursales', 'bodegas']);
    FOR k IN SELECT jsonb_object_keys(p_cambios->'limites') LOOP
      IF p_cambios->'limites'->k <> 'null'::jsonb AND (jsonb_typeof(p_cambios->'limites'->k) <> 'number'
           OR (p_cambios->'limites'->>k) !~ '^[0-9]{1,6}$' OR (p_cambios->'limites'->>k)::integer > 100000) THEN
        RAISE EXCEPTION 'DATO_INVALIDO: el límite de "%" es un entero de 0 a 100000, o null (sin límite).', k;
      END IF;
      IF (v_limact->k->'limite') IS DISTINCT FROM (p_cambios->'limites'->k) THEN
        v_limn := v_limn || jsonb_build_object(k, jsonb_build_object('actual', v_limact->k->'limite', 'nuevo', p_cambios->'limites'->k,
          'uso', v_limact->k->'uso',
          'aviso', CASE WHEN p_cambios->'limites'->k <> 'null'::jsonb AND (v_limact->k->>'uso')::integer > (p_cambios->'limites'->>k)::integer
                        THEN 'Ya hay más que el límite nuevo: nada se desactiva; solo no se podrán agregar más.' END));
      END IF;
    END LOOP;
    IF v_limn <> '{}'::jsonb THEN
      v_lims := v_limn;
    END IF;
  END IF;

  RETURN jsonb_build_object('empresa_id', e.id, 'empresa', e.nombre,
    'modulos', jsonb_build_object('activar', v_act, 'desactivar', v_des,
                                  'quedan_activos', (SELECT coalesce(jsonb_agg(x ORDER BY x), '[]') FROM unnest(v_final) x)),
    'perfil', v_perfil, 'licencia', v_lic, 'limites', v_lims, 'limites_hoy', v_limact, 'errores', v_err,
    'hay_cambios', jsonb_array_length(v_act) > 0 OR jsonb_array_length(v_des) > 0 OR v_perfil IS NOT NULL OR v_lic IS NOT NULL
                   OR v_lims IS NOT NULL);
END $$;

-- RPC: vista_previa_ficha(empresa, cambios)   solo la llave del proveedor
CREATE FUNCTION public.vista_previa_ficha(p_empresa_id uuid, p_cambios jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  RETURN interno.cambios_ficha(p_empresa_id, p_cambios);
END $$;

-- RPC: aplicar_ficha(empresa, cambios, motivo)   solo la llave del proveedor
-- Todo o nada: apaga (los que dependen primero), activa (los necesarios
-- primero), perfil, licencia y límites. Nunca borra datos. Bitácora con el motivo.
CREATE FUNCTION public.aplicar_ficha(p_empresa_id uuid, p_cambios jsonb, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v  jsonb;
  m  text;
BEGIN
  PERFORM interno.exigir_proveedor_llave();
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del cambio (mínimo 5 letras).';
  END IF;
  PERFORM 1 FROM public.empresa e WHERE e.id = p_empresa_id FOR UPDATE;
  v := interno.cambios_ficha(p_empresa_id, p_cambios);
  IF jsonb_array_length(v->'errores') > 0 THEN
    RAISE EXCEPTION 'MODULO_DEPENDENCIA: %', (SELECT string_agg(x, ' ') FROM jsonb_array_elements_text(v->'errores') x);
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'desactivar') LOOP
    UPDATE public.modulo_activo SET activo = false WHERE empresa_id = p_empresa_id AND modulo = m;
  END LOOP;
  FOR m IN SELECT jsonb_array_elements_text(v->'modulos'->'activar') LOOP
    INSERT INTO public.modulo_activo (empresa_id, modulo, activo) VALUES (p_empresa_id, m, true)
    ON CONFLICT (empresa_id, modulo) DO UPDATE SET activo = true;
  END LOOP;
  IF v->'perfil' <> 'null'::jsonb THEN
    PERFORM interno.guardar_perfil(p_empresa_id, v->'perfil'->>'nuevo');
  END IF;
  IF v->'licencia' <> 'null'::jsonb THEN
    INSERT INTO public.licencia (empresa_id, vence_el, dias_gracia)
    VALUES (p_empresa_id, (v->'licencia'->'nuevo'->>'vence_el')::date, (v->'licencia'->'nuevo'->>'dias_gracia')::integer)
    ON CONFLICT (empresa_id) DO UPDATE SET vence_el = excluded.vence_el, dias_gracia = excluded.dias_gracia, actualizado_en = now();
  END IF;
  IF v->'limites' <> 'null'::jsonb THEN
    INSERT INTO public.limite_contrato (empresa_id, usuarios, cajas, sucursales, bodegas)
    SELECT p_empresa_id,
      CASE WHEN v->'limites' ? 'usuarios'   THEN (v->'limites'->'usuarios'->>'nuevo')::integer   ELSE l.usuarios END,
      CASE WHEN v->'limites' ? 'cajas'      THEN (v->'limites'->'cajas'->>'nuevo')::integer      ELSE l.cajas END,
      CASE WHEN v->'limites' ? 'sucursales' THEN (v->'limites'->'sucursales'->>'nuevo')::integer ELSE l.sucursales END,
      CASE WHEN v->'limites' ? 'bodegas'    THEN (v->'limites'->'bodegas'->>'nuevo')::integer    ELSE l.bodegas END
      FROM (SELECT 1) x LEFT JOIN public.limite_contrato l ON l.empresa_id = p_empresa_id
    ON CONFLICT (empresa_id) DO UPDATE SET usuarios = excluded.usuarios, cajas = excluded.cajas,
       sucursales = excluded.sucursales, bodegas = excluded.bodegas, actualizado_en = now();
  END IF;
  PERFORM set_config('app.motivo', '', true);
  RETURN v || jsonb_build_object('aplicado', true);
END $$;

-- ---------------------------------------------------------------------
-- 4) mi_perfil (reemplaza la de 025; misma firma). Nuevo: "limites" (límite
--    y uso de usuarios, cajas, sucursales y bodegas) y empresa.vendedor_cobra.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mi_perfil(p_empresa_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_emp      public.empresa;
  v_ue       public.usuario_empresa;
  v_empresas jsonb;
  v_soporte  timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'rol', ue.rol)
                            ORDER BY e.nombre), '[]')
    INTO v_empresas
    FROM public.usuario_empresa ue JOIN public.empresa e ON e.id = ue.empresa_id
   WHERE ue.user_id = v_uid AND ue.activo;

  IF p_empresa_id IS NOT NULL AND public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  SELECT * INTO v_emp FROM public.empresa WHERE id = coalesce(p_empresa_id, public.empresa_actual());

  IF v_emp.id IS NULL THEN
    RETURN jsonb_build_object(
      'usuario',  jsonb_build_object('id', v_uid, 'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid)),
      'empresas', v_empresas,
      'empresa',  NULL);
  END IF;

  SELECT * INTO v_ue FROM public.usuario_empresa
   WHERE user_id = v_uid AND empresa_id = v_emp.id AND activo;

  SELECT max(s.vence_en) INTO v_soporte FROM public.acceso_soporte s
   WHERE s.empresa_id = v_emp.id AND s.revocado_en IS NULL AND now() BETWEEN s.desde AND s.vence_en;

  RETURN jsonb_build_object(
    'usuario', jsonb_build_object(
        'id', v_uid,
        'correo', (SELECT u.email FROM auth.users u WHERE u.id = v_uid),
        'nombre', v_ue.nombre),
    'empresas', v_empresas,
    'empresa', jsonb_build_object(
        'id', v_emp.id, 'nombre', v_emp.nombre, 'rtn', v_emp.rtn, 'rubro', v_emp.rubro,
        'moneda', v_emp.moneda, 'pais', v_emp.pais, 'zona_horaria', v_emp.zona_horaria,
        'fecha_inicio', to_char(v_emp.fecha_inicio, 'YYYY-MM-DD'),
        'dias_futuro_max', v_emp.dias_futuro_max,
        'hoy', to_char(public.hoy_local(v_emp.id), 'YYYY-MM-DD'),
        'perfil', v_emp.perfil,
        'turnos_obligatorios', v_emp.turnos_obligatorios,
        'contabilidad_visible', v_emp.contabilidad_visible,
        'doble_aprobacion', v_emp.doble_aprobacion,
        'vendedor_cobra', v_emp.vendedor_cobra),
    'rol', jsonb_build_object('codigo', v_ue.rol,
                              'nombre', (SELECT r.nombre FROM public.rol r WHERE r.codigo = v_ue.rol)),
    'permisos', (SELECT coalesce(jsonb_agg(p.codigo ORDER BY p.codigo), '[]')
                   FROM public.permiso p WHERE public.tiene_permiso(p.codigo, v_emp.id)),
    'modulos',  (SELECT coalesce(jsonb_agg(m.modulo ORDER BY m.modulo), '[]')
                   FROM public.modulo_activo m WHERE m.empresa_id = v_emp.id AND m.activo),
    'licencia', interno.estado_licencia(v_emp.id),
    'limites', interno.limites_y_uso(v_emp.id),
    'soporte_vigente_hasta', public.iso(v_soporte),
    'hora_servidor', public.iso(now()));
END $$;

-- ---------------------------------------------------------------------
-- 5) id_operacion por tipo (reemplaza la de 029): solicitudes al proveedor
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.tipo_operacion_2b(p_empresa_id uuid, p_id uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v text;
BEGIN
  SELECT 'dinero_' || x.tipo INTO v FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id;
  IF v IS NOT NULL THEN
    RETURN v;
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_deposito';
  END IF;
  IF EXISTS (SELECT 1 FROM public.operacion_dinero x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_operacion_dinero';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.apertura_id_operacion = p_id) THEN
    RETURN 'abrir_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.cierre_id_operacion = p_id) THEN
    RETURN 'cerrar_turno';
  END IF;
  IF EXISTS (SELECT 1 FROM public.turno_caja x WHERE x.empresa_id = p_empresa_id AND x.resolucion_id_operacion = p_id) THEN
    RETURN 'resolver_diferencia';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.gasto x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_gasto';
  END IF;
  IF EXISTS (SELECT 1 FROM public.aprobacion x WHERE x.empresa_id = p_empresa_id
               AND ((x.resolucion_id_operacion = p_id AND x.estado IN ('aprobada', 'rechazada')) OR x.primera_id_operacion = p_id)) THEN
    RETURN 'resolver_aprobacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta x WHERE x.empresa_id = p_empresa_id AND x.cancelacion_id_operacion = p_id) THEN
    RETURN 'cancelacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_anulacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'solicitar_anulacion_venta';
  END IF;
  IF EXISTS (SELECT 1 FROM public.venta_pago x WHERE x.empresa_id = p_empresa_id AND x.confirmacion_id_operacion = p_id) THEN
    RETURN 'confirmacion_transferencia';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'cotizacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cotizacion x WHERE x.empresa_id = p_empresa_id AND x.anulacion_id_operacion = p_id) THEN
    RETURN 'anulacion_cotizacion';
  END IF;
  IF EXISTS (SELECT 1 FROM public.solicitud_proveedor x WHERE x.empresa_id = p_empresa_id AND x.id_operacion = p_id) THEN
    RETURN 'solicitud_proveedor';
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- 6) Seguridad
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  interno.uso_limite(uuid, text),
  interno.limites_y_uso(uuid),
  interno.revisar_limite_contrato(),
  interno.proteger_solicitud_proveedor(),
  interno.nivel_modulo(text),
  interno.exigir_proveedor_llave(),
  interno.cambios_ficha(uuid, jsonb)
FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.solicitar_al_proveedor(uuid, text, text, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.solicitar_al_proveedor(uuid, text, text, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION
  public.vista_previa_ficha(uuid, jsonb),
  public.aplicar_ficha(uuid, jsonb, text),
  public.responder_solicitud_proveedor(uuid, text, text)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.vista_previa_ficha(uuid, jsonb),
  public.aplicar_ficha(uuid, jsonb, text),
  public.responder_solicitud_proveedor(uuid, text, text)
TO service_role;
