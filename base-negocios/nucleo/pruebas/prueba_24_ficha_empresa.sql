-- PRUEBA: crear_empresa_inicial recibe la ficha en jsonb, la valida campo por campo y crea la empresa completa
DO $$
DECLARE
  v_emp uuid;
  emp   public.empresa;
  base  jsonb := '{"nombre": "Farmacia Central", "fecha_inicio": "2026-03-01", "dueno": {"correo": "sin_empresa@prueba.hn"}}';
BEGIN
  -- Solo service_role (el proveedor) crea empresas.
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L::jsonb)', base), '42501', 'usuario crea empresa');

  PERFORM pruebas.como('service_role');
  -- Fichas malas: cada una con su mensaje.
  PERFORM pruebas.debe_fallar('SELECT public.crear_empresa_inicial(''[]'')', 'FICHA_INVALIDA', 'no es objeto');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base - 'nombre'), 'falta "nombre"', 'sin nombre');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"nombre": "   "}'), 'falta "nombre"', 'nombre vacío');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"rtn": "0801-1999-00000"}'), '"rtn"', 'rtn con guiones');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"moneda": "hnl"}'), '"moneda"', 'moneda minúscula');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"pais": "Honduras"}'), '"pais"', 'país largo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"zona_horaria": "Marte/Base"}'), '"zona_horaria"', 'zona inventada');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base - 'fecha_inicio'), '"fecha_inicio"', 'sin fecha de inicio');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"fecha_inicio": "01/03/2026"}'), '"fecha_inicio"', 'fecha no ISO');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"fecha_inicio": "2026-02-30"}'), '"fecha_inicio"', '30 de febrero');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"dias_futuro_max": 40}'), '"dias_futuro_max"', 'muchos días');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"dias_futuro_max": 2.5}'), '"dias_futuro_max"', 'días con decimales');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"modulos": "contabilidad"}'), '"modulos"', 'módulos no es lista');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"modulos": ["nomina"]}'), '"nomina"', 'módulo inexistente');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"nombre_comercial": "X"}'), '"nombre_comercial"', 'campo desconocido');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base - 'dueno'), '"dueno"', 'sin dueño');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"dueno": {}}'), '"dueno"', 'dueño vacío');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"dueno": {"user_id": "abc"}}'), 'uuid', 'user_id malo');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"dueno": {"correo": "nadie@x.hn"}}'), 'USUARIO_NO_EXISTE', 'dueño no registrado');
  PERFORM pruebas.debe_fallar(format('SELECT public.crear_empresa_inicial(%L)', base || '{"proveedor": {"correo": "sin_empresa@prueba.hn"}}'), 'mismo usuario', 'dueño = proveedor');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.empresa WHERE nombre = 'Farmacia Central'), 'ninguna ficha mala creó nada');

  -- Ficha completa.
  v_emp := public.crear_empresa_inicial(base || '{
    "rtn": "08019999000123", "rubro": "Farmacia", "moneda": "USD", "pais": "SV",
    "zona_horaria": "America/El_Salvador", "dias_futuro_max": 5,
    "modulos": ["contabilidad", "ventas", "ventas"],
    "dueno": {"correo": "SIN_EMPRESA@prueba.hn", "nombre": "  Ana López "},
    "proveedor": {"user_id": "a0000000-0000-0000-0000-000000000005"},
    "tema": {"color_principal": "#00aa00"}, "$schema": "./ficha.schema.json"}');

  PERFORM pruebas.como('superusuario');
  SELECT * INTO emp FROM public.empresa WHERE id = v_emp;
  PERFORM pruebas.afirmar(emp.nombre = 'Farmacia Central' AND emp.rtn = '08019999000123' AND emp.rubro = 'Farmacia', 'nombre, rtn, rubro');
  PERFORM pruebas.afirmar(emp.moneda = 'USD' AND emp.pais = 'SV' AND emp.zona_horaria = 'America/El_Salvador', 'moneda, país, zona');
  PERFORM pruebas.afirmar(emp.fecha_inicio = '2026-03-01' AND emp.dias_futuro_max = 5, 'fecha de inicio y días');
  PERFORM pruebas.afirmar((SELECT array_agg(modulo ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = v_emp) = ARRAY['contabilidad','ventas'], 'módulos');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.sucursal WHERE empresa_id = v_emp AND codigo = '001' AND activa) = 1, 'sucursal 001');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.caja WHERE empresa_id = v_emp AND punto_emision = '001') = 1, 'caja 001');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.cuenta WHERE empresa_id = v_emp) = (SELECT count(*) FROM interno.plantilla_cuenta), 'catálogo completo');
  PERFORM pruebas.afirmar((SELECT nombre FROM public.usuario_empresa WHERE empresa_id = v_emp AND rol = 'dueno') = 'Ana López', 'nombre del dueño (sin espacios)');
  PERFORM pruebas.afirmar((SELECT user_id FROM public.usuario_empresa WHERE empresa_id = v_emp AND rol = 'dueno') = pruebas.usuario('sin_empresa'), 'dueño por correo (sin importar mayúsculas)');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.usuario_empresa WHERE empresa_id = v_emp AND rol = 'proveedor') = 1, 'proveedor agregado');
  PERFORM pruebas.afirmar(NOT EXISTS (SELECT 1 FROM public.licencia WHERE empresa_id = v_emp), 'sin licencia: solo lectura hasta activarla');

  -- Mínima: defectos.
  PERFORM pruebas.como('service_role');
  v_emp := public.crear_empresa_inicial('{"nombre": "Pulpería Mínima", "fecha_inicio": "2026-01-01", "dueno": {"user_id": "c0000000-0000-0000-0000-000000000001"}}');
  PERFORM pruebas.como('superusuario');
  SELECT * INTO emp FROM public.empresa WHERE id = v_emp;
  PERFORM pruebas.afirmar(emp.moneda = 'HNL' AND emp.pais = 'HN' AND emp.zona_horaria = 'America/Tegucigalpa' AND emp.dias_futuro_max = 3 AND emp.rtn IS NULL, 'defectos');
  PERFORM pruebas.afirmar((SELECT array_agg(modulo) FROM public.modulo_activo WHERE empresa_id = v_emp) = ARRAY['contabilidad'], 'contabilidad siempre');
END $$;
