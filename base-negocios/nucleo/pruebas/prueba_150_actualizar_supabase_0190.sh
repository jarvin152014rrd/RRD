#!/usr/bin/env bash
# PRUEBA: (0.19.0) actualizar en "Supabase" una base 0.18.0 instalada con las partes del SQL Editor (mini Supabase con Storage, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.19.0.sql: dice ACTUALIZADO A 0.19.0 (fotos LISTO), verificar_instalacion dice TODO BIEN, el dueño y el admin ven lo mismo que antes, pegarlo otra vez no cambia nada, sin núcleo o sin la 054 se rechaza sin tocar nada (y lo dice claro: "054 (núcleo 0.18.0)"), un error a mitad no deja nada a medias, la bitácora queda íntegra, lo nuevo funciona (devolución con ajuste mayorista de una venta hecha ANTES de actualizar, cambio exacto encendido, estado de cuenta del socio que cuadra) y migrar.sh la reconoce
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
VIEJA="${BASE}_018"
OTRA="${BASE}_sin054"
TMP="$(mktemp -d)"
limpiar() { for b in "$VIEJA" "$OTRA"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }

# 1) Paquete 0.18.0 (migraciones 001-054) y el paquete actual (con la actualización a 0.19.0).
mkdir -p "$TMP/v018/herramientas" "$TMP/v018/nucleo/sql/migraciones" "$TMP/dist018" "$TMP/dist"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v018/herramientas/"
cp "$RAIZ/CHANGELOG.md" "$TMP/v018/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[0-4]_*.sql; do cp "$f" "$TMP/v018/nucleo/sql/migraciones/"; done
echo "0.18.0" > "$TMP/v018/VERSION_NUCLEO"
bash "$TMP/v018/herramientas/armar_instalacion.sh" "$TMP/dist018" >/dev/null || falla "no se armó el paquete 0.18.0"
bash "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete actual"
ACT="$TMP/dist/actualizar_supabase_${VERSION}.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
[ "$(stat -c %s "$ACT")" -lt $((200 * 1024)) ] || falla "la actualización pasa de 200 KB"
grep -q "Migración 055_" "$ACT" && ! grep -q "Migración 054_" "$ACT" || falla "la actualización debe traer solo la 055"

# 2) Base 0.18.0 como en Supabase (partes del SQL Editor) con datos de enero y una venta mayorista de 12 tornillos.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist018/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.18.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.18.0/54" ] || falla "no quedó en 0.18.0"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "datos"
BEGIN;
SELECT pruebas.preparar_enero();
SELECT public.editar_producto(pruebas.empresa('A'), pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12}', 'Mayoreo');
SELECT pruebas.guardar('V_MAY', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 12, 'efectivo', 'CLI2'), gen_random_uuid())->>'venta_id')::uuid);
COMMIT;
SQL

# Lo que ve cada uno (sin las claves nuevas de 0.18.0 ni horas).
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object(
  'productos', (SELECT jsonb_agg(to_jsonb(x) - 'precio_mayorista_centavos' - 'cantidad_mayorista' - 'precio_mayorista_con_isv_centavos'
                                 - 'dias_garantia' ORDER BY x.codigo) FROM public.v_producto x),
  'perfil', public.mi_perfil(pruebas.empresa('A')) - 'hora_servidor' - 'permisos',
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor' - 'cheques_por_depositar',
  'proyeccion', public.proyeccion_flujo(pruebas.empresa('A')) - 'generado_en' - 'semanas' - 'cheques_por_depositar_centavos' - 'nota',
  'semanas', (SELECT jsonb_agg(s - 'cheques_centavos') FROM jsonb_array_elements(public.proyeccion_flujo(pruebas.empresa('A'))->'semanas') s),
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en')::text;
ROLLBACK;
SQL
}
ANTES_DUENO="$(foto dueno_a)"
ANTES_ADMIN="$(foto admin_a)"
[ -n "$ANTES_DUENO" ] && [ -n "$ANTES_ADMIN" ] || falla "no se tomó la foto de antes"

# 3) Rechazos sin tocar nada: base sin núcleo y base sin la 054.
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó en una base sin núcleo"; fi
grep -q "FALTA_NUCLEO" "$TMP/sal.txt" || falla "sin núcleo debía decir FALTA_NUCLEO: $(cat "$TMP/sal.txt")"
for p in "$TMP"/dist018/instalar_supabase_parte*.sql; do
  grep -q "Migración 054_" "$p" && continue
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
ANTES_OTRA="$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")"
[ "$ANTES_OTRA" -lt 54 ] || falla "la otra base debía quedar antes de la 054"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 054"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" || falla "sin la 054 debía decir FALTA_VERSION_ANTERIOR: $(cat "$TMP/sal.txt")"
grep -q "054 (núcleo 0.18.0)" "$TMP/sal.txt" || falla "el aviso debía decir 054 (núcleo 0.18.0): $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "$ANTES_OTRA" ] || falla "la base sin la 054 quedó tocada"

# 3b) Un error a mitad (división por cero justo antes del final): no queda nada a medias.
sed 's/^NOTIFY pgrst, .reload schema.;$/SELECT 1 \/ 0 AS falla_a_proposito;\n&/' "$ACT" > "$TMP/act_roto.sql"
grep -q "falla_a_proposito" "$TMP/act_roto.sql" || falla "no se pudo armar la copia con error"
if una "$VIEJA" "$TMP/act_roto.sql" >"$TMP/sal.txt" 2>&1; then falla "la copia con error se aplicó"; fi
[ "$(q "$VIEJA" "SELECT max(numero) || '/' || (to_regprocedure('public.estado_cuenta_socio(uuid,uuid,date,date)') IS NULL)
      || '/' || (to_regprocedure('interno.montos_devolucion(public.venta,jsonb)') IS NULL)
      || '/' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'empresa' AND column_name = 'cambio_exacto')
      FROM interno._migraciones")" = "54/true/true/0" ] || falla "el error a mitad dejó algo a medias"
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || falla "el error a mitad cambió lo que ve el dueño"

# 4) Actualizar: una sola petición, todo o nada.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 55 | 55 | LISTO" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION ... LISTO: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 55 | 55 | LISTO" || falla "verificar_instalacion no dice TODO BIEN"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT checksum FROM interno._migraciones WHERE numero = 55")" \
  = "$(sha256sum "$RAIZ"/nucleo/sql/migraciones/055_*.sql | cut -d' ' -f1)" ] || falla "huella de la 055"
[ "$(q "$VIEJA" "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora no quedó íntegra"

# 5) El dueño y el admin ven lo mismo que antes.
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || { echo "antes:   $ANTES_DUENO"; echo "despues: $(foto dueno_a)"; falla "el dueño ve otra cosa después de actualizar"; }
[ "$(foto admin_a)" = "$ANTES_ADMIN" ] || falla "el admin ve otra cosa después de actualizar"

# 6) Otra vez: no cambia nada y sigue diciendo ACTUALIZADO.
antes="$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")"
una "$VIEJA" "$ACT" | grep -q "^ACTUALIZADO A $VERSION |" || falla "al repetir no dijo ACTUALIZADO"
[ "$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")" = "$antes" ] || falla "repetir cambió las migraciones"

# 7) Lo nuevo funciona en la base actualizada (y se deshace: ROLLBACK).
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "lo nuevo no funciona en la base actualizada"
BEGIN;
DO $$
DECLARE e uuid := pruebas.empresa('A'); r jsonb; s uuid;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT cambio_exacto FROM public.empresa WHERE id = e), 'cambio exacto encendido');
  -- Venta de ANTES de actualizar (la línea no guardó por qué fue mayorista): se usa el cliente y el producto de hoy.
  r := public.registrar_devolucion(pruebas.id('V_MAY'), jsonb_build_object('lineas', '[{"linea":1,"cantidad":6}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('FUERTE')), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 5400 AND (r->>'ajuste_mayorista_centavos')::bigint = 1800, 'ajuste mayorista: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_devolucion(%L, %L, gen_random_uuid())', pruebas.id('V_ENE_2'),
    jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Prefiere tornillos', 'destino', 'cambio',
      'cambio', jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2))))),
    'CAMBIO_NO_EXACTO', 'cambio que no da exacto');
  PERFORM pruebas.como('superusuario');
  INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (e, 'fondos');
  PERFORM pruebas.como('dueno_a');
  s := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 100), 'Socio único')->>'socio_id')::uuid;
  PERFORM public.registrar_aporte_socio(e, jsonb_build_object('socio_id', s, 'monto_centavos', 50000, 'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  r := public.estado_cuenta_socio(e, s);
  PERFORM pruebas.afirmar((r->>'total_invertido_centavos')::bigint = 50000 AND (r->'cuadre'->>'cuadra')::boolean, 'estado de cuenta del socio: ' || r::text);
END $$;
ROLLBACK;
SQL
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh"
# migrar.sh reconoce lo instalado (misma huella): solo quedan pendientes las migraciones posteriores a la 054.
{ echo "$PEND" | grep -q "No hay migraciones pendientes" || echo "$PEND" | grep -q "^  - 055_"; } \
  && ! echo "$PEND" | grep -E "^  - 0([0-4][0-9]|5[0-4])_" >/dev/null || falla "migrar.sh no reconoce la base actualizada: $PEND"
echo "ok"
