-- =====================================================================
-- 003_catalogo_cuentas.sql  -  Catálogo de cuentas NIIF para PYMES
-- Jerárquico (1 > 1.1 > 1.1.01 > 1.1.01.01). Solo las cuentas "de
-- detalle" (las hojas del árbol) reciben movimientos.
-- =====================================================================

-- Plantilla común. Cada empresa nueva recibe una copia (ver 007).
CREATE TABLE interno.plantilla_cuenta (
  codigo      text PRIMARY KEY CHECK (codigo ~ '^[0-9]+(\.[0-9]+)*$'),
  nombre      text NOT NULL,
  tipo        text,      -- se calcula abajo por el primer dígito
  naturaleza  text,      -- se calcula abajo; se escribe solo en cuentas "contra"
  es_detalle  boolean    -- se calcula abajo: true si no tiene hijas
);

INSERT INTO interno.plantilla_cuenta (codigo, nombre, naturaleza) VALUES
  -- 1 ACTIVO ---------------------------------------------------------
  ('1',          'ACTIVO', NULL),
  ('1.1',        'Activo corriente', NULL),
  ('1.1.01',     'Efectivo y equivalentes de efectivo', NULL),
  ('1.1.01.01',  'Caja general', NULL),
  ('1.1.01.02',  'Caja chica', NULL),
  ('1.1.01.03',  'Bancos', NULL),
  ('1.1.02',     'Cuentas por cobrar', NULL),
  ('1.1.02.01',  'Clientes', NULL),
  ('1.1.02.02',  'Otras cuentas por cobrar', NULL),
  ('1.1.02.03',  'Estimación para cuentas incobrables', 'acreedora'),
  ('1.1.03',     'Inventarios', NULL),
  ('1.1.03.01',  'Inventario de mercadería', NULL),
  ('1.1.04',     'Impuestos por recuperar', NULL),
  ('1.1.04.01',  'ISV crédito fiscal', NULL),
  ('1.1.04.02',  'Pagos a cuenta y retenciones de ISR', NULL),
  ('1.1.05',     'Pagos anticipados', NULL),
  ('1.1.05.01',  'Anticipos a proveedores', NULL),
  ('1.1.05.02',  'Seguros pagados por anticipado', NULL),
  ('1.2',        'Activo no corriente', NULL),
  ('1.2.01',     'Propiedades, planta y equipo', NULL),
  ('1.2.01.01',  'Terrenos', NULL),
  ('1.2.01.02',  'Edificios', NULL),
  ('1.2.01.03',  'Mobiliario y equipo', NULL),
  ('1.2.01.04',  'Equipo de cómputo', NULL),
  ('1.2.01.05',  'Vehículos', NULL),
  ('1.2.01.06',  'Depreciación acumulada', 'acreedora'),
  ('1.2.02',     'Otros activos no corrientes', NULL),
  ('1.2.02.01',  'Depósitos en garantía', NULL),
  -- 2 PASIVO ---------------------------------------------------------
  ('2',          'PASIVO', NULL),
  ('2.1',        'Pasivo corriente', NULL),
  ('2.1.01',     'Cuentas por pagar', NULL),
  ('2.1.01.01',  'Proveedores', NULL),
  ('2.1.01.02',  'Acreedores varios', NULL),
  ('2.1.02',     'Impuestos por pagar', NULL),
  ('2.1.02.01',  'ISV por pagar', NULL),
  ('2.1.02.02',  'ISR por pagar', NULL),
  ('2.1.02.03',  'Retenciones por pagar', NULL),
  ('2.1.03',     'Obligaciones laborales', NULL),
  ('2.1.03.01',  'Sueldos por pagar', NULL),
  ('2.1.03.02',  'IHSS por pagar', NULL),
  ('2.1.03.03',  'Prestaciones y décimos por pagar', NULL),
  ('2.1.04',     'Anticipos de clientes', NULL),
  ('2.1.04.01',  'Anticipos de clientes', NULL),
  ('2.1.05',     'Préstamos a corto plazo', NULL),
  ('2.1.05.01',  'Préstamos bancarios a corto plazo', NULL),
  ('2.2',        'Pasivo no corriente', NULL),
  ('2.2.01',     'Préstamos a largo plazo', NULL),
  ('2.2.01.01',  'Préstamos bancarios a largo plazo', NULL),
  -- 3 PATRIMONIO -----------------------------------------------------
  ('3',          'PATRIMONIO', NULL),
  ('3.1',        'Capital', NULL),
  ('3.1.01',     'Capital social', NULL),
  ('3.1.01.01',  'Capital social pagado', NULL),
  ('3.1.01.02',  'Aportes del dueño', NULL),
  ('3.1.01.03',  'Retiros del dueño', 'deudora'),
  ('3.2',        'Reservas', NULL),
  ('3.2.01',     'Reserva legal', NULL),
  ('3.2.01.01',  'Reserva legal', NULL),
  ('3.3',        'Resultados', NULL),
  ('3.3.01',     'Resultados acumulados', NULL),
  ('3.3.01.01',  'Utilidades (pérdidas) acumuladas', NULL),
  ('3.3.01.02',  'Resultado del ejercicio', NULL),
  -- 4 INGRESOS -------------------------------------------------------
  ('4',          'INGRESOS', NULL),
  ('4.1',        'Ingresos de actividades ordinarias', NULL),
  ('4.1.01',     'Ventas', NULL),
  ('4.1.01.01',  'Ventas de mercadería', NULL),
  ('4.1.01.02',  'Ventas de servicios', NULL),
  ('4.1.01.03',  'Devoluciones y descuentos sobre ventas', 'deudora'),
  ('4.2',        'Otros ingresos', NULL),
  ('4.2.01',     'Otros ingresos', NULL),
  ('4.2.01.01',  'Ingresos financieros', NULL),
  ('4.2.01.02',  'Otros ingresos varios', NULL),
  -- 5 COSTOS ---------------------------------------------------------
  ('5',          'COSTOS', NULL),
  ('5.1',        'Costo de ventas', NULL),
  ('5.1.01',     'Costo de ventas', NULL),
  ('5.1.01.01',  'Costo de mercadería vendida', NULL),
  ('5.1.01.02',  'Mermas y ajustes de inventario', NULL),
  -- 6 GASTOS ---------------------------------------------------------
  ('6',          'GASTOS', NULL),
  ('6.1',        'Gastos de operación', NULL),
  ('6.1.01',     'Gastos de personal', NULL),
  ('6.1.01.01',  'Sueldos y salarios', NULL),
  ('6.1.01.02',  'Aporte patronal IHSS', NULL),
  ('6.1.01.03',  'Prestaciones y décimos', NULL),
  ('6.1.02',     'Gastos generales', NULL),
  ('6.1.02.01',  'Alquileres', NULL),
  ('6.1.02.02',  'Energía eléctrica', NULL),
  ('6.1.02.03',  'Agua', NULL),
  ('6.1.02.04',  'Teléfono e internet', NULL),
  ('6.1.02.05',  'Papelería y útiles', NULL),
  ('6.1.02.06',  'Mantenimiento y reparaciones', NULL),
  ('6.1.02.07',  'Combustible y transporte', NULL),
  ('6.1.02.08',  'Publicidad', NULL),
  ('6.1.02.09',  'Depreciación', NULL),
  ('6.1.02.10',  'Gastos varios', NULL),
  ('6.2',        'Gastos financieros', NULL),
  ('6.2.01',     'Gastos financieros', NULL),
  ('6.2.01.01',  'Intereses', NULL),
  ('6.2.01.02',  'Comisiones bancarias', NULL);

-- Completar tipo, naturaleza y es_detalle de forma automática.
UPDATE interno.plantilla_cuenta SET tipo = CASE split_part(codigo, '.', 1)
  WHEN '1' THEN 'activo'  WHEN '2' THEN 'pasivo' WHEN '3' THEN 'patrimonio'
  WHEN '4' THEN 'ingreso' WHEN '5' THEN 'costo'  WHEN '6' THEN 'gasto' END;
UPDATE interno.plantilla_cuenta SET naturaleza = CASE
  WHEN tipo IN ('activo','costo','gasto') THEN 'deudora' ELSE 'acreedora' END
  WHERE naturaleza IS NULL;
UPDATE interno.plantilla_cuenta p SET es_detalle = NOT EXISTS (
  SELECT 1 FROM interno.plantilla_cuenta h WHERE h.codigo LIKE p.codigo || '.%');
ALTER TABLE interno.plantilla_cuenta
  ALTER COLUMN tipo SET NOT NULL, ALTER COLUMN naturaleza SET NOT NULL,
  ALTER COLUMN es_detalle SET NOT NULL;

-- ---------------------------------------------------------------------
-- Catálogo de cada empresa
-- ---------------------------------------------------------------------
CREATE TABLE public.cuenta (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id  uuid NOT NULL REFERENCES public.empresa(id),
  codigo      text NOT NULL CHECK (codigo ~ '^[0-9]+(\.[0-9]+)*$'),
  nombre      text NOT NULL CHECK (length(trim(nombre)) > 0),
  tipo        text NOT NULL CHECK (tipo IN ('activo','pasivo','patrimonio','ingreso','costo','gasto')),
  naturaleza  text NOT NULL CHECK (naturaleza IN ('deudora','acreedora')),
  padre_id    uuid,
  es_detalle  boolean NOT NULL,
  activa      boolean NOT NULL DEFAULT true,
  creado_en   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (empresa_id, codigo),
  UNIQUE (empresa_id, id),
  FOREIGN KEY (empresa_id, padre_id) REFERENCES public.cuenta(empresa_id, id)
);

-- Reglas del árbol: la madre debe existir, ser del mismo tipo y NO ser
-- de detalle. En un cambio, solo se puede tocar nombre y activa.
CREATE FUNCTION interno.validar_cuenta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_padre public.cuenta;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.empresa_id, NEW.codigo, NEW.tipo, NEW.naturaleza, NEW.padre_id, NEW.es_detalle)
       IS DISTINCT FROM
       (OLD.empresa_id, OLD.codigo, OLD.tipo, OLD.naturaleza, OLD.padre_id, OLD.es_detalle) THEN
      RAISE EXCEPTION 'PROHIBIDO: de una cuenta solo se puede cambiar el nombre o desactivarla.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.padre_id IS NOT NULL THEN
    SELECT * INTO v_padre FROM public.cuenta WHERE id = NEW.padre_id;
    IF v_padre.es_detalle THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta madre % es de detalle y no puede tener hijas.', v_padre.codigo;
    END IF;
    IF v_padre.tipo <> NEW.tipo THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: la cuenta % debe ser del mismo tipo que su madre %.', NEW.codigo, v_padre.codigo;
    END IF;
    IF NEW.codigo NOT LIKE v_padre.codigo || '.%' THEN
      RAISE EXCEPTION 'CUENTA_INVALIDA: el código % debe empezar con el de su madre %.', NEW.codigo, v_padre.codigo;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER validar BEFORE INSERT OR UPDATE ON public.cuenta
  FOR EACH ROW EXECUTE FUNCTION interno.validar_cuenta();
CREATE TRIGGER auditar AFTER INSERT OR UPDATE OR DELETE ON public.cuenta
  FOR EACH ROW EXECUTE FUNCTION interno.auditar();
CREATE TRIGGER no_borrar BEFORE DELETE ON public.cuenta
  FOR EACH ROW EXECUTE FUNCTION interno.prohibir_cambios('Desactive la cuenta en vez de borrarla.');

-- Copia la plantilla a una empresa (madres primero).
CREATE FUNCTION interno.copiar_catalogo(p_empresa_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r  record;
  n  integer := 0;
BEGIN
  FOR r IN
    SELECT * FROM interno.plantilla_cuenta
    ORDER BY array_length(string_to_array(codigo, '.'), 1), codigo
  LOOP
    INSERT INTO public.cuenta (empresa_id, codigo, nombre, tipo, naturaleza, es_detalle, padre_id)
    VALUES (p_empresa_id, r.codigo, r.nombre, r.tipo, r.naturaleza, r.es_detalle,
            (SELECT c.id FROM public.cuenta c
              WHERE c.empresa_id = p_empresa_id
                AND c.codigo = regexp_replace(r.codigo, '\.[0-9]+$', '')
                AND c.codigo <> r.codigo));
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
