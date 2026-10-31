-- =====================================================================
-- 015_inventario.sql  -  Bodegas y kardex con costo promedio ponderado
--
--   bodega                    bodegas de cada sucursal
--   inventario_movimiento     kardex: SOLO AGREGAR (entrada, salida, ajuste,
--                             traslado). Cada fila guarda el saldo que dejó.
--   inventario_saldo          existencia, valor y costo promedio por
--                             producto y bodega. Se actualiza en la MISMA
--                             transacción que el movimiento, con la fila
--                             bloqueada (FOR UPDATE).
--   inventario_alerta         avisos (existencia negativa permitida)
--   inventario_documento(+_linea)  ajustes por conteo físico, traslados y
--                             cargas iniciales
--
-- Costo promedio ponderado (todo en centavos; costo unitario con 6 decimales):
--   ENTRADA  q a valor v:  cantidad += q;  valor += v;  promedio = valor / cantidad
--   SALIDA   q:            sale round(q x promedio) (si se vacía, sale TODO
--                          el valor, para no dejar centavos sueltos);
--                          el promedio no cambia.
-- Valor del kardex = saldo contable de "Inventario de mercadería": cada
-- movimiento que cambia el valor lleva su asiento en la misma transacción.
-- Los asientos de este módulo NO se anulan con anular_asiento (ver abajo).
--
-- RPC:
--   crear_bodega / desactivar_bodega                 bodegas.administrar
--   ajustar_inventario   (conteo físico + asiento)   inventario.ajustar
--   trasladar_inventario (entre bodegas, sin asiento) inventario.trasladar
--   cargar_saldo_inicial (apertura + asiento)        inventario.carga_inicial
--   buscar_producto_por_codigo (escáner / cámara)    miembro de la empresa
-- Vistas: v_existencia (sin costos para quien no tiene inventario.costos)
--         v_kardex (con saldo acumulado)
-- =====================================================================

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('BODEGA_INVALIDA',          'La bodega no existe o está desactivada.', 'Elija una bodega activa de la empresa.'),
  ('CANTIDAD_INVALIDA',        'La cantidad no es válida.', 'Use una cantidad mayor que cero (sin decimales si el producto se maneja por unidades enteras).'),
  ('EXISTENCIA_INSUFICIENTE',  'No hay suficiente existencia en la bodega.', 'Revise la existencia; registre primero la compra o el traslado que falta.'),
  ('SALDO_INICIAL_YA_CARGADO', 'Ese producto ya tiene saldo inicial en esa bodega.', 'Para corregir use un ajuste de inventario. Repetir la carga inicial necesita un permiso especial del dueño.'),
  ('CUENTA_CONTROLADA',        'Esa cuenta la mueve un módulo (inventario o compras).', 'Registre la operación desde su módulo (compra, ajuste, pago) y no con un asiento manual.');

INSERT INTO public.permiso (codigo, descripcion, es_movimiento, es_financiero) VALUES
  ('bodegas.administrar',            'Crear y desactivar bodegas',                                      false, false),
  ('inventario.ver',                 'Ver existencias (cantidades) por bodega',                         false, false),
  ('inventario.costos',              'Ver costos, valor del inventario y kardex',                       false, true),
  ('inventario.ajustar',             'Ajustar inventario por conteo físico (genera asiento)',           true,  false),
  ('inventario.trasladar',           'Trasladar mercadería entre bodegas',                              true,  false),
  ('inventario.carga_inicial',       'Cargar saldos iniciales de inventario (genera asiento)',          true,  false),
  ('inventario.carga_inicial_repetir','Repetir la carga inicial de un producto en una bodega',          true,  false),
  ('inventario.negativo',            'Sacar mercadería aunque la existencia quede en negativo',         true,  false);

-- Criterio: vendedor y cajero ven cantidades, nunca costos; no ajustan ni
-- trasladan. Repetir carga inicial y dejar en negativo: solo el dueño.
INSERT INTO interno.plantilla_rol_permiso (rol, permiso) VALUES
  ('dueno', 'bodegas.administrar'), ('dueno', 'inventario.ver'), ('dueno', 'inventario.costos'),
  ('dueno', 'inventario.ajustar'), ('dueno', 'inventario.trasladar'), ('dueno', 'inventario.carga_inicial'),
  ('dueno', 'inventario.carga_inicial_repetir'), ('dueno', 'inventario.negativo'),
  ('admin', 'bodegas.administrar'), ('admin', 'inventario.ver'), ('admin', 'inventario.costos'),
  ('admin', 'inventario.ajustar'), ('admin', 'inventario.trasladar'), ('admin', 'inventario.carga_inicial'),
  ('cajero', 'inventario.ver'),
  ('vendedor', 'inventario.ver');

SELECT interno.repartir_permisos(ARRAY['bodegas.administrar', 'inventario.ver', 'inventario.costos',
  'inventario.ajustar', 'inventario.trasladar', 'inventario.carga_inicial',
  'inventario.carga_inicial_repetir', 'inventario.negativo'],
  'Núcleo 0.3.0: permisos nuevos de inventario');

-- ---------------------------------------------------------------------
-- Cuentas que usan los módulos (un solo lugar). modulo_controla: si ese
-- módulo está activo, la cuenta NO acepta asientos manuales.
-- ---------------------------------------------------------------------
CREATE TABLE interno.cuenta_sistema (
  uso              text PRIMARY KEY,
  codigo           text NOT NULL,
  descripcion      text NOT NULL,
  modulo_controla  text REFERENCES public.modulo(codigo)
);
INSERT INTO interno.cuenta_sistema (uso, codigo, descripcion, modulo_controla) VALUES
  ('inventario',          '1.1.03.01', 'Inventario de mercadería (valor del kardex)',      'inventario'),
  ('isv_credito',         '1.1.04.01', 'ISV crédito fiscal de compras',                    NULL),
  ('cxp',                 '2.1.01.01', 'Proveedores (cuentas por pagar)',                  'compras'),
  ('caja',                '1.1.01.01', 'Caja general (pagos de contado)',                  NULL),
  ('banco',               '1.1.01.03', 'Bancos (pagos de contado)',                        NULL),
  ('perdida_inventario',  '5.1.01.02', 'Faltantes y ajustes de costo de inventario',       NULL),
  ('ganancia_inventario', '4.2.01.02', 'Sobrantes de inventario (otros ingresos)',         NULL),
  ('apertura_inventario', '3.1.01.01', 'Patrimonio: contrapartida del inventario inicial', NULL);

CREATE FUNCTION interno.cuenta_sistema(p_uso text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT c.codigo FROM interno.cuenta_sistema c WHERE c.uso = p_uso
$$;

-- Asiento hecho por un módulo. p_lineas: [{"uso":"inventario","debe":100}, ...]
-- (o "cuenta":"1.1.01.01"). Las líneas en cero se saltan. Si todo es cero
-- no hay asiento (devuelve NULL).
CREATE FUNCTION interno.asiento_sistema(p_empresa_id uuid, p_sucursal_id uuid, p_fecha date,
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
              WHERE NOT EXISTS (SELECT 1 FROM public.cuenta c WHERE c.empresa_id = p_empresa_id
                                   AND c.codigo = coalesce(l->>'cuenta', interno.cuenta_sistema(l->>'uso')))) THEN
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
                      AND c.codigo = coalesce(x.l->>'cuenta', interno.cuenta_sistema(x.l->>'uso'))
  WHERE coalesce((x.l->>'debe')::bigint, 0) + coalesce((x.l->>'haber')::bigint, 0) > 0;
  RETURN v_cab.o_id;
END $$;

-- Defensa: cuentas controladas por un módulo activo no aceptan asientos
-- manuales (así el kardex y las CxP siempre cuadran con la contabilidad).
CREATE FUNCTION interno.revisar_cuenta_controlada() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_origen text;
  v_cs     interno.cuenta_sistema;
BEGIN
  SELECT a.origen INTO v_origen FROM public.asiento a WHERE a.id = NEW.asiento_id;
  IF v_origen IS DISTINCT FROM 'manual' THEN
    RETURN NEW;
  END IF;
  SELECT cs.* INTO v_cs FROM interno.cuenta_sistema cs
    JOIN public.cuenta c ON c.codigo = cs.codigo AND c.empresa_id = NEW.empresa_id
   WHERE c.id = NEW.cuenta_id AND cs.modulo_controla IS NOT NULL
     AND public.modulo_esta_activo(NEW.empresa_id, cs.modulo_controla)
   LIMIT 1;
  IF v_cs.uso IS NOT NULL THEN
    RAISE EXCEPTION 'CUENTA_CONTROLADA: la cuenta % la mueve el módulo "%"; use ese módulo en vez de un asiento manual.',
      v_cs.codigo, v_cs.modulo_controla;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER cuenta_controlada BEFORE INSERT ON public.asiento_linea
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_cuenta_controlada();

-- Defensa: anular_asiento solo anula asientos manuales. Los de un módulo
-- se anulan desde su documento (ej. anular_compra), que también revierte
-- el kardex o la cuenta por pagar.
CREATE FUNCTION interno.revisar_anulacion_de_modulo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_origen text;
BEGIN
  IF NEW.anula_asiento_id IS NOT NULL AND NEW.origen = 'anulacion' THEN
    SELECT a.origen INTO v_origen FROM public.asiento a WHERE a.id = NEW.anula_asiento_id;
    IF v_origen IS DISTINCT FROM 'manual' THEN
      RAISE EXCEPTION 'PROHIBIDO: este asiento es de un módulo (%); anúlelo desde su documento.', v_origen;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER anulacion_de_modulo BEFORE INSERT ON public.asiento
  FOR EACH ROW EXECUTE FUNCTION interno.revisar_anulacion_de_modulo();

-- ---------------------------------------------------------------------
-- Bodegas
-- ---------------------------------------------------------------------
CREATE TABLE public.bodega (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id   uuid NOT NULL REFERENCES public.empresa(id),
  sucursal_id  uuid NOT NULL,
  codigo       text NOT NULL CHECK (codigo ~ '^[A-Z0-9-]{1,10}$'),
  nombre       text NOT NULL CHECK (length(trim(nombre)) > 0),
  activa       boolean NOT NULL DEFAULT true,
  creado_en    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, codigo),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, sucursal_id) REFERENCES public.sucursal(empresa_id, id)
);
CREATE TRIGGER proteger BEFORE UPDATE ON public.bodega FOR EACH ROW EXECUTE FUNCTION interno.proteger_catalogo();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.bodega FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.bodega
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la bodega en vez de borrarla.');

-- ---------------------------------------------------------------------
-- Saldos, movimientos y alertas
-- ---------------------------------------------------------------------
CREATE TABLE public.inventario_saldo (
  empresa_id            uuid NOT NULL,
  bodega_id             uuid NOT NULL,
  producto_id           uuid NOT NULL,
  cantidad              numeric(18,4) NOT NULL DEFAULT 0,
  valor_centavos        bigint        NOT NULL DEFAULT 0,
  costo_promedio        numeric(18,6) NOT NULL DEFAULT 0,   -- centavos por unidad
  ultimo_movimiento_id  bigint,
  actualizado_en        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bodega_id, producto_id),
  FOREIGN KEY (empresa_id, bodega_id)   REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id)
);
CREATE INDEX inventario_saldo_producto ON public.inventario_saldo (empresa_id, producto_id);

CREATE TABLE public.inventario_movimiento (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- orden del kardex
  empresa_id            uuid NOT NULL REFERENCES public.empresa(id),
  bodega_id             uuid NOT NULL,
  producto_id           uuid NOT NULL,
  tipo                  text NOT NULL CHECK (tipo IN ('entrada', 'salida', 'ajuste', 'traslado')),
  origen                text NOT NULL,      -- compra, anulacion_compra, ajuste, traslado, carga_inicial, venta...
  fecha_contable        date NOT NULL,
  cantidad              numeric(18,4) NOT NULL CHECK (cantidad <> 0),   -- + entra, - sale
  valor_centavos        bigint NOT NULL,                                -- con el mismo signo
  costo_unitario        numeric(18,6) NOT NULL CHECK (costo_unitario >= 0),
  saldo_cantidad        numeric(18,4) NOT NULL,     -- lo que quedó en la bodega
  saldo_valor_centavos  bigint NOT NULL,
  saldo_costo_promedio  numeric(18,6) NOT NULL,
  documento_tipo        text NOT NULL,              -- compra, inventario_documento...
  documento_id          uuid NOT NULL,
  id_operacion          uuid NOT NULL,
  nota                  text,
  creado_por            uuid,
  registrado_en         timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (empresa_id, bodega_id)   REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id) REFERENCES public.producto(empresa_id, id),
  CHECK ((cantidad > 0 AND valor_centavos >= 0) OR (cantidad < 0 AND valor_centavos <= 0))
);
CREATE INDEX inventario_mov_producto ON public.inventario_movimiento (empresa_id, producto_id, id);
CREATE INDEX inventario_mov_documento ON public.inventario_movimiento (documento_id);

CREATE TABLE public.inventario_alerta (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id           uuid NOT NULL REFERENCES public.empresa(id),
  tipo                 text NOT NULL CHECK (tipo IN ('existencia_negativa')),
  bodega_id            uuid NOT NULL,
  producto_id          uuid NOT NULL,
  movimiento_id        bigint NOT NULL REFERENCES public.inventario_movimiento(id),
  cantidad_resultante  numeric(18,4) NOT NULL,
  creado_por           uuid,
  creado_en            timestamptz NOT NULL DEFAULT now()
);

-- Documentos de inventario: ajuste (conteo físico), traslado, carga inicial.
CREATE TABLE public.inventario_documento (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id         uuid NOT NULL REFERENCES public.empresa(id),
  tipo               text NOT NULL CHECK (tipo IN ('ajuste', 'traslado', 'carga_inicial')),
  numero             bigint NOT NULL,                 -- correlativo por empresa y tipo
  bodega_id          uuid NOT NULL,                   -- en traslado: la de origen
  bodega_destino_id  uuid,
  fecha_contable     date NOT NULL,
  motivo             text,
  asiento_id         uuid,
  sobrante_centavos  bigint NOT NULL DEFAULT 0,
  faltante_centavos  bigint NOT NULL DEFAULT 0,
  total_centavos     bigint NOT NULL DEFAULT 0,
  id_operacion       uuid NOT NULL,
  creado_por         uuid,
  registrado_en      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, id),
  UNIQUE (empresa_id, id_operacion),
  UNIQUE (empresa_id, tipo, numero),
  FOREIGN KEY (empresa_id, bodega_id)         REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, bodega_destino_id) REFERENCES public.bodega(empresa_id, id),
  FOREIGN KEY (empresa_id, asiento_id)        REFERENCES public.asiento(empresa_id, id),
  CHECK ((tipo = 'traslado') = (bodega_destino_id IS NOT NULL))
);

CREATE TABLE public.inventario_documento_linea (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empresa_id          uuid NOT NULL,
  documento_id        uuid NOT NULL,
  linea               smallint NOT NULL CHECK (linea > 0),
  producto_id         uuid NOT NULL,
  existencia_sistema  numeric(18,4),           -- ajuste: lo que decía el sistema
  cantidad_contada    numeric(18,4),           -- ajuste: lo que se contó
  cantidad            numeric(18,4) NOT NULL,  -- movimiento (con signo en ajuste)
  costo_unitario      numeric(18,6) NOT NULL DEFAULT 0,
  valor_centavos      bigint NOT NULL DEFAULT 0,
  UNIQUE (documento_id, linea),
  FOREIGN KEY (empresa_id, documento_id) REFERENCES public.inventario_documento(empresa_id, id),
  FOREIGN KEY (empresa_id, producto_id)  REFERENCES public.producto(empresa_id, id)
);

-- Solo agregar.
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.inventario_movimiento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('El kardex es de solo agregar; corrija con un ajuste.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.inventario_alerta
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Las alertas son de solo agregar.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.inventario_documento
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los documentos de inventario no se editan ni se borran.');
CREATE TRIGGER inmutable BEFORE UPDATE OR DELETE ON public.inventario_documento_linea
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los documentos de inventario no se editan ni se borran.');
CREATE TRIGGER no_borrar BEFORE DELETE ON public.inventario_saldo
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Los saldos de inventario no se borran.');

CREATE TRIGGER auditar AFTER INSERT ON public.inventario_movimiento FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.inventario_alerta     FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER auditar AFTER INSERT ON public.inventario_documento  FOR EACH ROW EXECUTE FUNCTION interno.auditar();

-- Con kardex, la unidad del producto ya no cambia (cambiaría lo que
-- significan las cantidades guardadas).
CREATE FUNCTION interno.unidad_fija_con_kardex() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.unidad_id IS DISTINCT FROM OLD.unidad_id
     AND EXISTS (SELECT 1 FROM public.inventario_movimiento m WHERE m.producto_id = NEW.id) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: el producto ya tiene movimientos de inventario; su unidad de medida no se puede cambiar.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER unidad_fija BEFORE UPDATE OF unidad_id ON public.producto
  FOR EACH ROW EXECUTE FUNCTION interno.unidad_fija_con_kardex();

-- ---------------------------------------------------------------------
-- Ayudantes
-- ---------------------------------------------------------------------
-- Valida una cantidad para un producto (mayor que 0, o 0 si p_cero).
CREATE FUNCTION interno.validar_cantidad(p_producto public.producto, p_cantidad numeric,
                                         p_linea integer, p_cero boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_cantidad IS NULL OR p_cantidad < 0 OR (p_cantidad = 0 AND NOT p_cero) THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: la cantidad de la línea % debe ser mayor que cero.', p_linea;
  END IF;
  IF p_cantidad >= 100000000000000 OR p_cantidad <> round(p_cantidad, 4) THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: la cantidad de la línea % es demasiado grande o tiene más de 4 decimales.', p_linea;
  END IF;
  IF NOT p_producto.permite_fracciones AND p_cantidad <> trunc(p_cantidad) THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: el producto % se maneja por unidades enteras (línea %).', p_producto.codigo, p_linea;
  END IF;
END $$;

-- Número desde jsonb (cantidad o costo); error con la clave indicada.
CREATE FUNCTION interno.json_numero(p_valor jsonb, p_campo text, p_linea integer) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_valor IS NULL OR jsonb_typeof(p_valor) <> 'number' THEN
    RAISE EXCEPTION 'LINEA_INVALIDA: en la línea % falta "%" o no es un número.', p_linea, p_campo;
  END IF;
  RETURN (p_valor #>> '{}')::numeric;
END $$;

-- Costo unitario (centavos por unidad, hasta 6 decimales, 0 o más).
CREATE FUNCTION interno.validar_costo(p_costo numeric, p_linea integer) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_costo IS NULL OR p_costo < 0 OR p_costo >= 1000000000000 OR p_costo <> round(p_costo, 6) THEN
    RAISE EXCEPTION 'LINEA_INVALIDA: el costo unitario de la línea % debe ser 0 o más, en centavos, con hasta 6 decimales.', p_linea;
  END IF;
END $$;

-- Producto de la empresa (activo si se pide).
CREATE FUNCTION interno.producto_de(p_empresa_id uuid, p_valor jsonb, p_linea integer, p_activo boolean)
RETURNS public.producto
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE p public.producto;
BEGIN
  SELECT * INTO p FROM public.producto x
   WHERE x.empresa_id = p_empresa_id AND x.id = interno.json_uuid(p_valor, 'producto_id');
  IF p.id IS NULL THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto de la línea % no existe en esta empresa.', p_linea;
  END IF;
  IF p_activo AND NOT p.activo THEN
    RAISE EXCEPTION 'PRODUCTO_INVALIDO: el producto % (línea %) está desactivado.', p.codigo, p_linea;
  END IF;
  RETURN p;
END $$;

-- Bodega activa de la empresa (con sucursal activa).
CREATE FUNCTION interno.bodega_activa(p_empresa_id uuid, p_bodega_id uuid) RETURNS public.bodega
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE b public.bodega;
BEGIN
  SELECT x.* INTO b FROM public.bodega x JOIN public.sucursal s ON s.id = x.sucursal_id
   WHERE x.id = p_bodega_id AND x.empresa_id = p_empresa_id AND x.activa AND s.activa;
  IF b.id IS NULL THEN
    RAISE EXCEPTION 'BODEGA_INVALIDA: la bodega no existe en esta empresa o está desactivada.';
  END IF;
  RETURN b;
END $$;

-- Lista de líneas: arreglo no vacío de objetos, sin productos repetidos.
CREATE FUNCTION interno.exigir_lineas(p_lineas jsonb, p_claves text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  l jsonb;
  i integer := 0;
BEGIN
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lineas) = 0 THEN
    RAISE EXCEPTION 'LINEA_INVALIDA: indique al menos una línea.';
  END IF;
  IF jsonb_array_length(p_lineas) > 500 THEN
    RAISE EXCEPTION 'LINEA_INVALIDA: máximo 500 líneas por documento.';
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    IF jsonb_typeof(l) <> 'object' THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % no tiene el formato correcto.', i;
    END IF;
    BEGIN
      PERFORM interno.exigir_claves(l, p_claves);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: la línea % trae un campo que no se reconoce.', i;
    END;
  END LOOP;
END $$;

-- ¿Se puede dejar existencia negativa? (configuración de la empresa o permiso)
CREATE FUNCTION interno.permite_negativo(p_empresa_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce((SELECT e.permite_existencia_negativa FROM public.empresa e WHERE e.id = p_empresa_id), false)
      OR public.tiene_permiso('inventario.negativo', p_empresa_id)
$$;

-- Saldo de un producto en una bodega, BLOQUEADO hasta el fin de la transacción.
CREATE FUNCTION interno.bloquear_saldo(p_empresa_id uuid, p_bodega_id uuid, p_producto_id uuid)
RETURNS public.inventario_saldo
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE s public.inventario_saldo;
BEGIN
  INSERT INTO public.inventario_saldo (empresa_id, bodega_id, producto_id)
  VALUES (p_empresa_id, p_bodega_id, p_producto_id) ON CONFLICT DO NOTHING;
  SELECT * INTO s FROM public.inventario_saldo
   WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id FOR UPDATE;
  RETURN s;
END $$;

-- ---------------------------------------------------------------------
-- EL MOTOR: registra un movimiento y actualiza el saldo (costo promedio).
--   p_cantidad > 0 entra, < 0 sale.
--   p_valor: en entradas, el valor que entra (centavos, obligatorio).
--            en salidas, NULL = a costo promedio; o un valor fijo
--            (anulación de compra: sale a lo que costó).
--   p_negativo: si se permite quedar en negativo (deja alerta).
-- Devuelve el movimiento guardado. Quien llama ya validó producto,
-- bodega, cantidad y permisos, y tiene tomado bloquear_libros.
-- ---------------------------------------------------------------------
CREATE FUNCTION interno.mover_inventario(
  p_empresa_id uuid, p_bodega_id uuid, p_producto_id uuid, p_tipo text, p_origen text,
  p_fecha date, p_cantidad numeric, p_valor bigint,
  p_documento_tipo text, p_documento_id uuid, p_id_operacion uuid,
  p_nota text DEFAULT NULL, p_negativo boolean DEFAULT false)
RETURNS public.inventario_movimiento
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s        public.inventario_saldo;
  m        public.inventario_movimiento;
  v_q      numeric;      -- cantidad nueva
  v_mov    bigint;       -- valor del movimiento (con signo)
  v_sale   bigint;       -- valor que sale (positivo)
  v_v      bigint;       -- valor nuevo
  v_prom   numeric;      -- costo promedio nuevo
  v_codigo text;
BEGIN
  IF p_cantidad IS NULL OR p_cantidad = 0 THEN
    RAISE EXCEPTION 'CANTIDAD_INVALIDA: un movimiento de inventario necesita cantidad.';
  END IF;
  s   := interno.bloquear_saldo(p_empresa_id, p_bodega_id, p_producto_id);
  v_q := s.cantidad + p_cantidad;

  IF p_cantidad > 0 THEN
    IF p_valor IS NULL OR p_valor < 0 THEN
      RAISE EXCEPTION 'DATO_INVALIDO: una entrada de inventario necesita su valor (0 o más).';
    END IF;
    v_mov := p_valor;
  ELSE
    -- Salida: no puede quedar en negativo salvo que se permita.
    IF v_q < 0 AND NOT p_negativo THEN
      SELECT p.codigo INTO v_codigo FROM public.producto p WHERE p.id = p_producto_id;
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

  UPDATE public.inventario_saldo
     SET cantidad = v_q, valor_centavos = v_v, costo_promedio = v_prom,
         ultimo_movimiento_id = m.id, actualizado_en = now()
   WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;

  IF v_q < 0 AND p_cantidad < 0 THEN
    INSERT INTO public.inventario_alerta (empresa_id, tipo, bodega_id, producto_id, movimiento_id,
                                          cantidad_resultante, creado_por)
    VALUES (p_empresa_id, 'existencia_negativa', p_bodega_id, p_producto_id, m.id, v_q, auth.uid());
  END IF;
  RETURN m;
END $$;

-- Busca un documento de inventario ya hecho con ese id_operacion.
CREATE FUNCTION interno.documento_inventario_previo(p_empresa_id uuid, p_id_operacion uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('documento_id', d.id, 'tipo', d.tipo, 'numero', d.numero, 'asiento_id', d.asiento_id,
                            'sobrante_centavos', d.sobrante_centavos, 'faltante_centavos', d.faltante_centavos,
                            'total_centavos', d.total_centavos, 'duplicado', true)
    FROM public.inventario_documento d
   WHERE d.empresa_id = p_empresa_id AND d.id_operacion = p_id_operacion
$$;

-- ---------------------------------------------------------------------
-- RPC: bodegas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.crear_bodega(p_empresa_id uuid, p_sucursal_id uuid, p_codigo text, p_nombre text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id     uuid;
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'bodegas.administrar', 'inventario');
  IF NOT EXISTS (SELECT 1 FROM public.sucursal WHERE id = p_sucursal_id AND empresa_id = p_empresa_id AND activa) THEN
    RAISE EXCEPTION 'SUCURSAL_INVALIDA: la sucursal no existe en esta empresa o está desactivada.';
  END IF;
  IF v_codigo !~ '^[A-Z0-9-]{1,10}$' THEN
    RAISE EXCEPTION 'DATO_INVALIDO: el código de bodega lleva de 1 a 10 letras o números, ej. B01.';
  END IF;
  IF length(trim(coalesce(p_nombre, ''))) = 0 THEN
    RAISE EXCEPTION 'DATO_INVALIDO: escriba el nombre de la bodega.';
  END IF;
  BEGIN
    INSERT INTO public.bodega (empresa_id, sucursal_id, codigo, nombre)
    VALUES (p_empresa_id, p_sucursal_id, v_codigo, trim(p_nombre)) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'YA_EXISTE: ya hay una bodega con el código %.', v_codigo;
  END;
  RETURN jsonb_build_object('bodega_id', v_id, 'codigo', v_codigo);
END $$;

-- Solo se desactiva vacía (sin existencias), para no "esconder" mercadería.
CREATE FUNCTION public.desactivar_bodega(p_empresa_id uuid, p_bodega_id uuid, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_b public.bodega;
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'bodegas.administrar', 'inventario');
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba por qué se desactiva la bodega (mínimo 5 letras).';
  END IF;
  PERFORM interno.bloquear_libros(p_empresa_id);
  SELECT * INTO v_b FROM public.bodega WHERE id = p_bodega_id AND empresa_id = p_empresa_id FOR UPDATE;
  IF v_b.id IS NULL THEN
    RAISE EXCEPTION 'NO_EXISTE: la bodega no existe en esta empresa.';
  END IF;
  IF NOT v_b.activa THEN
    RETURN jsonb_build_object('bodega_id', p_bodega_id, 'activa', false, 'ya_estaba', true);
  END IF;
  IF EXISTS (SELECT 1 FROM public.inventario_saldo s
              WHERE s.bodega_id = p_bodega_id AND (s.cantidad <> 0 OR s.valor_centavos <> 0)) THEN
    RAISE EXCEPTION 'NO_PERMITIDO: la bodega todavía tiene existencias; trasládelas o ajústelas antes de desactivarla.';
  END IF;
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  UPDATE public.bodega SET activa = false WHERE id = p_bodega_id;
  PERFORM set_config('app.motivo', '', true);
  RETURN jsonb_build_object('bodega_id', p_bodega_id, 'activa', false, 'ya_estaba', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: ajustar_inventario (conteo físico)
-- p_lineas = [{"producto_id":"...","cantidad_contada":8,"costo_unitario":1250.5}, ...]
--   costo_unitario (opcional) solo se usa si sobra mercadería; si no se
--   da, el sobrante entra al costo promedio actual.
-- Faltante: sale a costo promedio  -> Dr Faltantes (5.1.01.02) / Cr Inventario
-- Sobrante: entra                  -> Dr Inventario / Cr Sobrantes (4.2.01.02)
-- Un solo asiento por documento (si hay diferencia con valor).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.ajustar_inventario(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
                                          p_lineas jsonb, p_motivo text, p_id_operacion uuid)
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
  s        public.inventario_saldo;
  m        public.inventario_movimiento;
  v_cont   numeric;
  v_dif    numeric;
  v_costo  numeric;
  v_sob    bigint := 0;
  v_fal    bigint := 0;
  v_asto   uuid;
  v_vistos uuid[] := '{}';
  v_lin    jsonb := '[]';
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.ajustar', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
  END IF;
  IF length(trim(coalesce(p_motivo, ''))) < 5 THEN
    RAISE EXCEPTION 'FALTA_MOTIVO: escriba el motivo del ajuste (mínimo 5 letras), ej. conteo físico de fin de mes.';
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);
  v_b := interno.bodega_activa(p_empresa_id, p_bodega_id);
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad_contada', 'costo_unitario']);

  PERFORM interno.bloquear_libros(p_empresa_id);
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, p_fecha);

  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, false);
    IF p.id = ANY (v_vistos) THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: el producto % está repetido (línea %).', p.codigo, i;
    END IF;
    v_vistos := v_vistos || p.id;
    v_cont := interno.json_numero(l->'cantidad_contada', 'cantidad_contada', i);
    PERFORM interno.validar_cantidad(p, v_cont, i, true);

    s := interno.bloquear_saldo(p_empresa_id, p_bodega_id, p.id);
    v_dif := v_cont - s.cantidad;
    v_costo := s.costo_promedio;
    m := NULL;
    IF v_dif > 0 THEN
      IF l ? 'costo_unitario' THEN
        v_costo := interno.json_numero(l->'costo_unitario', 'costo_unitario', i);
        PERFORM interno.validar_costo(v_costo, i);
      END IF;
      m := interno.mover_inventario(p_empresa_id, p_bodega_id, p.id, 'ajuste', 'ajuste', p_fecha, v_dif,
                                    round(v_dif * v_costo)::bigint, 'inventario_documento', v_doc, p_id_operacion,
                                    trim(p_motivo));
      v_sob := v_sob + m.valor_centavos;
    ELSIF v_dif < 0 THEN
      m := interno.mover_inventario(p_empresa_id, p_bodega_id, p.id, 'ajuste', 'ajuste', p_fecha, v_dif,
                                    NULL, 'inventario_documento', v_doc, p_id_operacion, trim(p_motivo), true);
      v_fal := v_fal - m.valor_centavos;
    END IF;
    v_lin := v_lin || jsonb_build_object('producto_id', p.id, 'existencia', s.cantidad, 'contada', v_cont,
               'cantidad', v_dif, 'costo', coalesce(m.costo_unitario, v_costo), 'valor', coalesce(m.valor_centavos, 0));
  END LOOP;

  v_asto := interno.asiento_sistema(p_empresa_id, v_b.sucursal_id, p_fecha,
    'Ajuste de inventario (conteo físico) bodega ' || v_b.codigo || ': ' || trim(p_motivo),
    'ajuste_inventario', p_id_operacion, jsonb_build_array(
      jsonb_build_object('uso', 'inventario',          'debe',  v_sob, 'descripcion', 'Sobrantes'),
      jsonb_build_object('uso', 'ganancia_inventario', 'haber', v_sob, 'descripcion', 'Sobrantes'),
      jsonb_build_object('uso', 'perdida_inventario',  'debe',  v_fal, 'descripcion', 'Faltantes'),
      jsonb_build_object('uso', 'inventario',          'haber', v_fal, 'descripcion', 'Faltantes')));

  v_num := interno.siguiente_numero(p_empresa_id, 'inventario_ajuste');
  PERFORM set_config('app.motivo', trim(p_motivo), true);
  INSERT INTO public.inventario_documento (id, empresa_id, tipo, numero, bodega_id, fecha_contable, motivo,
    asiento_id, sobrante_centavos, faltante_centavos, total_centavos, id_operacion, creado_por)
  VALUES (v_doc, p_empresa_id, 'ajuste', v_num, p_bodega_id, p_fecha, trim(p_motivo),
    v_asto, v_sob, v_fal, v_sob + v_fal, p_id_operacion, auth.uid());
  PERFORM set_config('app.motivo', '', true);
  INSERT INTO public.inventario_documento_linea (empresa_id, documento_id, linea, producto_id,
    existencia_sistema, cantidad_contada, cantidad, costo_unitario, valor_centavos)
  SELECT p_empresa_id, v_doc, x.n, (x.l->>'producto_id')::uuid, (x.l->>'existencia')::numeric,
         (x.l->>'contada')::numeric, (x.l->>'cantidad')::numeric, (x.l->>'costo')::numeric, (x.l->>'valor')::bigint
  FROM jsonb_array_elements(v_lin) WITH ORDINALITY AS x(l, n);

  RETURN jsonb_build_object('documento_id', v_doc, 'tipo', 'ajuste', 'numero', v_num, 'asiento_id', v_asto,
                            'sobrante_centavos', v_sob, 'faltante_centavos', v_fal,
                            'total_centavos', v_sob + v_fal, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: trasladar_inventario. Sale de una bodega a costo promedio y entra
-- a la otra con ese mismo valor. Sin asiento (misma cuenta de inventario).
-- p_lineas = [{"producto_id":"...","cantidad":5}, ...]
-- ---------------------------------------------------------------------
CREATE FUNCTION public.trasladar_inventario(p_empresa_id uuid, p_bodega_origen_id uuid, p_bodega_destino_id uuid,
                                            p_fecha date, p_lineas jsonb, p_id_operacion uuid,
                                            p_nota text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_prev   jsonb;
  v_o      public.bodega;
  v_d      public.bodega;
  v_doc    uuid := gen_random_uuid();
  v_num    bigint;
  l        jsonb;
  i        integer := 0;
  p        public.producto;
  v_q      numeric;
  m        public.inventario_movimiento;
  v_neg    boolean;
  v_total  bigint := 0;
  v_vistos uuid[] := '{}';
  v_lin    jsonb := '[]';
BEGIN
  PERFORM interno.exigir_escritura(p_empresa_id, 'inventario.trasladar', 'inventario');
  IF p_id_operacion IS NULL THEN
    RAISE EXCEPTION 'FALTA_ID_OPERACION: cada operación necesita un id_operacion (uuid) único.';
  END IF;
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);
  v_o := interno.bodega_activa(p_empresa_id, p_bodega_origen_id);
  v_d := interno.bodega_activa(p_empresa_id, p_bodega_destino_id);
  IF v_o.id = v_d.id THEN
    RAISE EXCEPTION 'BODEGA_INVALIDA: la bodega de origen y la de destino deben ser distintas.';
  END IF;
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad']);
  v_neg := interno.permite_negativo(p_empresa_id);

  PERFORM interno.bloquear_libros(p_empresa_id);
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
  END IF;
  PERFORM interno.exigir_periodo_abierto(p_empresa_id, p_fecha);

  FOR l IN SELECT * FROM jsonb_array_elements(p_lineas) LOOP
    i := i + 1;
    p := interno.producto_de(p_empresa_id, l->'producto_id', i, false);
    IF p.id = ANY (v_vistos) THEN
      RAISE EXCEPTION 'LINEA_INVALIDA: el producto % está repetido (línea %).', p.codigo, i;
    END IF;
    v_vistos := v_vistos || p.id;
    v_q := interno.json_numero(l->'cantidad', 'cantidad', i);
    PERFORM interno.validar_cantidad(p, v_q, i);

    m := interno.mover_inventario(p_empresa_id, v_o.id, p.id, 'traslado', 'traslado', p_fecha, -v_q, NULL,
                                  'inventario_documento', v_doc, p_id_operacion, 'Traslado a ' || v_d.codigo, v_neg);
    PERFORM interno.mover_inventario(p_empresa_id, v_d.id, p.id, 'traslado', 'traslado', p_fecha, v_q,
                                     -m.valor_centavos, 'inventario_documento', v_doc, p_id_operacion,
                                     'Traslado desde ' || v_o.codigo);
    v_total := v_total - m.valor_centavos;
    v_lin := v_lin || jsonb_build_object('producto_id', p.id, 'cantidad', v_q,
                                         'costo', m.costo_unitario, 'valor', -m.valor_centavos);
  END LOOP;

  v_num := interno.siguiente_numero(p_empresa_id, 'inventario_traslado');
  INSERT INTO public.inventario_documento (id, empresa_id, tipo, numero, bodega_id, bodega_destino_id,
    fecha_contable, motivo, total_centavos, id_operacion, creado_por)
  VALUES (v_doc, p_empresa_id, 'traslado', v_num, v_o.id, v_d.id, p_fecha, nullif(trim(p_nota), ''),
    v_total, p_id_operacion, auth.uid());
  INSERT INTO public.inventario_documento_linea (empresa_id, documento_id, linea, producto_id,
    cantidad, costo_unitario, valor_centavos)
  SELECT p_empresa_id, v_doc, x.n, (x.l->>'producto_id')::uuid, (x.l->>'cantidad')::numeric,
         (x.l->>'costo')::numeric, (x.l->>'valor')::bigint
  FROM jsonb_array_elements(v_lin) WITH ORDINALITY AS x(l, n);

  RETURN jsonb_build_object('documento_id', v_doc, 'tipo', 'traslado', 'numero', v_num, 'asiento_id', NULL,
                            'total_centavos', v_total, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- RPC: cargar_saldo_inicial (apertura del inventario)
-- p_lineas = [{"producto_id":"...","cantidad":100,"costo_unitario":1250}, ...]
-- Asiento: Dr Inventario / Cr Patrimonio (3.1.01.01).
-- Una sola vez por producto y bodega; repetir pide el permiso
-- inventario.carga_inicial_repetir (solo dueño por defecto) y motivo.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cargar_saldo_inicial(p_empresa_id uuid, p_bodega_id uuid, p_fecha date,
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
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
  END IF;
  PERFORM interno.exigir_fecha_contable(p_empresa_id, p_fecha);
  v_b := interno.bodega_activa(p_empresa_id, p_bodega_id);
  PERFORM interno.exigir_lineas(p_lineas, ARRAY['producto_id', 'cantidad', 'costo_unitario']);

  PERFORM interno.bloquear_libros(p_empresa_id);
  v_prev := interno.documento_inventario_previo(p_empresa_id, p_id_operacion);
  IF v_prev IS NOT NULL THEN
    RETURN v_prev;
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
                WHERE x.bodega_id = p_bodega_id AND x.producto_id = p.id AND x.origen = 'carga_inicial') THEN
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

  RETURN jsonb_build_object('documento_id', v_doc, 'tipo', 'carga_inicial', 'numero', v_num,
                            'asiento_id', v_asto, 'total_centavos', v_total, 'duplicado', false);
END $$;

-- ---------------------------------------------------------------------
-- Lectura
-- ---------------------------------------------------------------------
-- ¿Puede leer? Con usuario: debe tener el permiso en esa empresa.
-- Sin usuario: solo service_role o el administrador de la base.
CREATE FUNCTION public.puede_leer(p_empresa_id uuid, p_permiso text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN auth.uid() IS NULL
              THEN coalesce(auth.role(), '') NOT IN ('anon', 'authenticated')
              ELSE public.tiene_permiso(p_permiso, p_empresa_id) END
$$;

-- RPC: buscar un producto por código de barras (o código interno), para
-- el escáner o la cámara. Nunca da error si no lo encuentra:
-- {"encontrado": false}. Existencias si tiene inventario.ver; costos solo
-- con inventario.costos.
CREATE FUNCTION public.buscar_producto_por_codigo(p_empresa_id uuid, p_codigo text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cod   text := trim(coalesce(p_codigo, ''));
  p       public.producto;
  v_por   text;
  v_exist jsonb;
  v_costos boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'SIN_SESION: debe iniciar sesión.';
  END IF;
  IF p_empresa_id IS NULL OR public.mi_rol(p_empresa_id) IS NULL THEN
    RAISE EXCEPTION 'NO_PERTENECE: el usuario no pertenece a esta empresa.';
  END IF;
  IF v_cod = '' THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;

  SELECT * INTO p FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo_barras = v_cod;
  v_por := 'codigo_barras';
  IF p.id IS NULL THEN
    SELECT * INTO p FROM public.producto x WHERE x.empresa_id = p_empresa_id AND x.codigo = upper(v_cod);
    v_por := 'codigo';
  END IF;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('encontrado', false, 'codigo', v_cod);
  END IF;

  v_costos := public.tiene_permiso('inventario.costos', p_empresa_id);
  IF public.tiene_permiso('inventario.ver', p_empresa_id) THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'bodega_id', b.id, 'bodega', b.codigo, 'cantidad', s.cantidad,
             'costo_promedio', CASE WHEN v_costos THEN s.costo_promedio END)
             ORDER BY b.codigo), '[]')
      INTO v_exist
      FROM public.inventario_saldo s JOIN public.bodega b ON b.id = s.bodega_id
     WHERE s.producto_id = p.id AND b.activa;
  END IF;

  RETURN jsonb_build_object(
    'encontrado', true, 'por', v_por,
    'producto', jsonb_build_object(
      'id', p.id, 'codigo', p.codigo, 'codigo_barras', p.codigo_barras, 'nombre', p.nombre,
      'unidad', (SELECT u.codigo FROM public.unidad u WHERE u.id = p.unidad_id),
      'tipo_impuesto', p.tipo_impuesto, 'precio_venta_centavos', p.precio_venta_centavos,
      'permite_fracciones', p.permite_fracciones, 'activo', p.activo, 'campos_extra', p.campos_extra),
    'existencias', v_exist);
END $$;

-- Existencias por bodega. Vista "del sistema" (no security_invoker) para
-- poder ocultar los costos por fila: cantidades con inventario.ver;
-- costo y valor solo con inventario.costos (si no, vienen vacíos).
CREATE VIEW public.v_existencia AS
  SELECT s.empresa_id, s.bodega_id, b.codigo AS bodega_codigo, b.nombre AS bodega_nombre, b.sucursal_id,
         s.producto_id, p.codigo, p.codigo_barras, p.nombre, u.codigo AS unidad,
         s.cantidad, p.stock_minimo, (s.cantidad < p.stock_minimo) AS bajo_minimo,
         CASE WHEN public.puede_leer(s.empresa_id, 'inventario.costos') THEN s.costo_promedio END AS costo_promedio,
         CASE WHEN public.puede_leer(s.empresa_id, 'inventario.costos') THEN s.valor_centavos END AS valor_centavos,
         s.actualizado_en
  FROM public.inventario_saldo s
  JOIN public.bodega   b ON b.id = s.bodega_id
  JOIN public.producto p ON p.id = s.producto_id
  JOIN public.unidad   u ON u.id = p.unidad_id
  WHERE public.puede_leer(s.empresa_id, 'inventario.ver');

-- Kardex con saldo acumulado: por bodega (lo que dejó cada movimiento) y
-- del producto en todas las bodegas. Pide inventario.costos (RLS).
CREATE VIEW public.v_kardex WITH (security_invoker = true) AS
  SELECT m.id, m.empresa_id, m.producto_id, p.codigo, p.nombre, m.bodega_id, b.codigo AS bodega_codigo,
         m.fecha_contable, m.registrado_en, m.tipo, m.origen, m.documento_tipo, m.documento_id,
         m.cantidad, m.costo_unitario, m.valor_centavos,
         m.saldo_cantidad AS saldo_bodega_cantidad, m.saldo_valor_centavos AS saldo_bodega_valor_centavos,
         m.saldo_costo_promedio AS costo_promedio_bodega,
         sum(m.cantidad)       OVER w AS saldo_producto_cantidad,
         (sum(m.valor_centavos) OVER w)::bigint AS saldo_producto_valor_centavos,
         m.nota, m.creado_por
  FROM public.inventario_movimiento m
  JOIN public.producto p ON p.id = m.producto_id
  JOIN public.bodega   b ON b.id = m.bodega_id
  WINDOW w AS (PARTITION BY m.empresa_id, m.producto_id ORDER BY m.id);

-- ---------------------------------------------------------------------
-- Seguridad
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bodega', 'inventario_saldo', 'inventario_movimiento', 'inventario_alerta',
                           'inventario_documento', 'inventario_documento_linea'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios(%L)', t, 'No se permite vaciar tablas.');
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role', t);
  END LOOP;
END $$;
GRANT SELECT ON public.v_existencia, public.v_kardex TO authenticated, service_role;

CREATE POLICY leer ON public.bodega FOR SELECT TO authenticated USING (empresa_id IN (SELECT public.mis_empresas()));
CREATE POLICY leer ON public.inventario_alerta FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('inventario.ver', empresa_id));
-- Con valores: piden inventario.costos.
CREATE POLICY leer ON public.inventario_saldo FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('inventario.costos', empresa_id));
CREATE POLICY leer ON public.inventario_movimiento FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('inventario.costos', empresa_id));
CREATE POLICY leer ON public.inventario_documento FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('inventario.costos', empresa_id));
CREATE POLICY leer ON public.inventario_documento_linea FOR SELECT TO authenticated
  USING (empresa_id IN (SELECT public.mis_empresas()) AND public.tiene_permiso('inventario.costos', empresa_id));

REVOKE EXECUTE ON FUNCTION
  public.crear_bodega(uuid, uuid, text, text),
  public.desactivar_bodega(uuid, uuid, text),
  public.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid),
  public.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text),
  public.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text),
  public.buscar_producto_por_codigo(uuid, text),
  public.puede_leer(uuid, text)
FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.crear_bodega(uuid, uuid, text, text),
  public.desactivar_bodega(uuid, uuid, text),
  public.ajustar_inventario(uuid, uuid, date, jsonb, text, uuid),
  public.trasladar_inventario(uuid, uuid, uuid, date, jsonb, uuid, text),
  public.cargar_saldo_inicial(uuid, uuid, date, jsonb, uuid, text),
  public.buscar_producto_por_codigo(uuid, text)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.puede_leer(uuid, text) TO authenticated, service_role;
