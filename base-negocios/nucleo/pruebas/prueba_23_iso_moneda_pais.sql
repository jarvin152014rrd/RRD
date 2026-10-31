-- PRUEBA: moneda ISO 4217 y país ISO 3166 (3 y 2 letras mayúsculas) y fechas exportadas en ISO 8601 aunque la sesión use otro formato
DO $$
DECLARE
  e uuid := pruebas.empresa('A');
  p jsonb;
  r jsonb;
BEGIN
  PERFORM pruebas.como('superusuario');
  PERFORM pruebas.afirmar((SELECT moneda = 'HNL' AND pais = 'HN' FROM public.empresa WHERE id = e), 'defectos HNL y HN');

  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre, fecha_inicio, moneda) VALUES (''X'', ''2026-01-01'', ''hnl'')', '23514', 'moneda en minúsculas');
  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre, fecha_inicio, moneda) VALUES (''X'', ''2026-01-01'', ''LEMPIRA'')', '23514', 'moneda larga');
  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre, fecha_inicio, moneda) VALUES (''X'', ''2026-01-01'', ''L'')', '23514', 'moneda corta');
  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre, fecha_inicio, pais) VALUES (''X'', ''2026-01-01'', ''HND'')', '23514', 'país de 3 letras');
  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre, fecha_inicio, pais) VALUES (''X'', ''2026-01-01'', ''hn'')', '23514', 'país en minúsculas');
  PERFORM pruebas.debe_fallar('INSERT INTO public.empresa (nombre) VALUES (''Sin fecha de inicio'')', '23502', 'fecha de inicio obligatoria');
  INSERT INTO public.empresa (nombre, fecha_inicio, moneda, pais, zona_horaria)
  VALUES ('Tienda en Guatemala', '2026-01-01', 'GTQ', 'GT', 'America/Guatemala');

  -- Sesión con formato de fecha "raro" (día/mes) y otra zona: lo exportado sigue en ISO.
  PERFORM set_config('datestyle', 'SQL, DMY', true);
  PERFORM set_config('timezone', 'Asia/Tokyo', true);
  PERFORM pruebas.como('dueno_a');
  r := public.registrar_asiento(e, '2026-01-10', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
  p := public.mi_perfil(e);
  PERFORM pruebas.afirmar(p->'empresa'->>'fecha_inicio' = '2026-01-01', 'fecha_inicio ISO: ' || (p->'empresa'->>'fecha_inicio'));
  PERFORM pruebas.afirmar(p->'empresa'->>'hoy' ~ '^\d{4}-\d{2}-\d{2}$', 'hoy ISO');
  PERFORM pruebas.afirmar(p->'licencia'->>'vence_el' ~ '^\d{4}-\d{2}-\d{2}$', 'vence_el ISO: ' || (p->'licencia'->>'vence_el'));
  PERFORM pruebas.afirmar(p->>'hora_servidor' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', 'hora_servidor ISO UTC: ' || (p->>'hora_servidor'));
  PERFORM pruebas.afirmar(public.iso('2026-03-01 00:30:00-06'::timestamptz) = '2026-03-01T06:30:00Z', 'iso() pasa a UTC');
  -- Lo que la app lee por la API (JSON) también sale en ISO.
  PERFORM pruebas.afirmar((SELECT to_jsonb(a)->>'fecha_contable' FROM public.asiento a WHERE a.id = (r->>'asiento_id')::uuid) = '2026-01-10', 'JSON de asiento en ISO');
  PERFORM pruebas.afirmar((SELECT to_jsonb(a)->>'registrado_en' FROM public.asiento a WHERE a.id = (r->>'asiento_id')::uuid) ~ '^\d{4}-\d{2}-\d{2}T', 'JSON de hora en ISO');
END $$;
