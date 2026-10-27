#!/usr/bin/env bash
# PRUEBA: (0.20.0) actualizar en "Supabase" una base 0.19.0 instalada con las partes del SQL Editor (mini Supabase con Storage, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.20.0.sql: dice ACTUALIZADO A 0.20.0 (fotos LISTO), verificar_instalacion dice TODO BIEN, el dueño y el admin ven lo mismo que antes, pegarlo otra vez no cambia nada, sin núcleo o sin la 055 se rechaza sin tocar nada (y lo dice claro: "055 (núcleo 0.19.0)"), un error a mitad no deja nada a medias, la bitácora queda íntegra, lo nuevo funciona (equipo, bloque, foto, una venta sin internet subida y la numeración en línea después del bloque; una venta de ANTES de actualizar sigue igual) y sin equipos registrados nada cambia para la app vieja y migrar.sh la reconoce
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VERSION="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
VIEJA="${BASE}_019"
OTRA="${BASE}_sin055"
TMP="$(mktemp -d)"
limpiar() { for b in "$VIEJA" "$OTRA"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }

# 1) Paquete 0.19.0 (migraciones 001-055) y el paquete actual (con la actualización a 0.20.0).
mkdir -p "$TMP/v019/herramientas" "$TMP/v019/nucleo/sql/migraciones" "$TMP/dist019" "$TMP/dist"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v019/herramientas/"
cp "$RAIZ/CHANGELOG.md" "$TMP/v019/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[0-5]_*.sql; do cp "$f" "$TMP/v019/nucleo/sql/migraciones/"; done
echo "0.19.0" > "$TMP/v019/VERSION_NUCLEO"
bash "$TMP/v019/herramientas/armar_instalacion.sh" "$TMP/dist019" >/dev/null || falla "no se armó el paquete 0.19.0"
bash "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete actual"
ACT="$TMP/dist/actualizar_supabase_${VERSION}.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
[ "$(stat -c %s "$ACT")" -lt $((200 * 1024)) ] || falla "la actualización pasa de 200 KB"
grep -q "Migración 056_" "$ACT" && ! grep -q "Migración 055_" "$ACT" || falla "la actualización debe traer solo la 056"

# 2) Base 0.19.0 como en Supabase (partes del SQL Editor) con datos de enero y una venta mayorista de 12 tornillos.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist019/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.19.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.19.0/55" ] || falla "no quedó en 0.19.0"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "datos"
BEGIN;
SELECT pruebas.preparar_enero();
SELECT public.editar_producto(pruebas.empresa('A'), pruebas.id('P1'), '{"precio_mayorista_centavos": 1200, "cantidad_mayorista": 12}', 'Mayoreo');
SELECT pruebas.guardar('V_MAY', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 12, 'efectivo', 'CLI2'), gen_random_uuid())->>'venta_id')::uuid);
COMMIT;
SQL

# Lo que ve cada uno (sin horas).
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object(
  'productos', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.codigo) FROM public.v_producto x),
  'alertas', public.alertas_activas(pruebas.empresa('A')) - 'generado_en',
  'preferencias', public.mis_preferencias_alertas(pruebas.empresa('A')),
  'perfil', public.mi_perfil(pruebas.empresa('A')) - 'hora_servidor' - 'permisos',
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor',
  'proyeccion', public.proyeccion_flujo(pruebas.empresa('A')) - 'generado_en',
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en')::text;
ROLLBACK;
SQL
}
ANTES_DUENO="$(foto dueno_a)"
ANTES_ADMIN="$(foto admin_a)"
[ -n "$ANTES_DUENO" ] && [ -n "$ANTES_ADMIN" ] || falla "no se tomó la foto de antes"

# 3) Rechazos sin tocar nada: base sin núcleo y base sin la 055.
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó en una base sin núcleo"; fi
grep -q "FALTA_NUCLEO" "$TMP/sal.txt" || falla "sin núcleo debía decir FALTA_NUCLEO: $(cat "$TMP/sal.txt")"
for p in "$TMP"/dist019/instalar_supabase_parte*.sql; do
  grep -q "Migración 055_" "$p" && continue
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
ANTES_OTRA="$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")"
[ "$ANTES_OTRA" -lt 55 ] || falla "la otra base debía quedar antes de la 055"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 055"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" || falla "sin la 055 debía decir FALTA_VERSION_ANTERIOR: $(cat "$TMP/sal.txt")"
grep -q "055 (núcleo 0.19.0)" "$TMP/sal.txt" || falla "el aviso debía decir 055 (núcleo 0.19.0): $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "$ANTES_OTRA" ] || falla "la base sin la 055 quedó tocada"

# 3b) Un error a mitad (división por cero justo antes del final): no queda nada a medias.
sed 's/^NOTIFY pgrst, .reload schema.;$/SELECT 1 \/ 0 AS falla_a_proposito;\n&/' "$ACT" > "$TMP/act_roto.sql"
grep -q "falla_a_proposito" "$TMP/act_roto.sql" || falla "no se pudo armar la copia con error"
if una "$VIEJA" "$TMP/act_roto.sql" >"$TMP/sal.txt" 2>&1; then falla "la copia con error se aplicó"; fi
[ "$(q "$VIEJA" "SELECT max(numero) || '/' || (to_regprocedure('public.subir_ventas_sin_internet(uuid,uuid,jsonb,text)') IS NULL)
      || '/' || (to_regclass('public.numero_bloque') IS NULL)
      || '/' || (SELECT count(*) FROM information_schema.columns WHERE table_name = 'empresa' AND column_name = 'sin_internet_horas')
      FROM interno._migraciones")" = "55/true/true/0" ] || falla "el error a mitad dejó algo a medias"
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || falla "el error a mitad cambió lo que ve el dueño"

# 4) Actualizar: una sola petición, todo o nada.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 56 | 56 | LISTO" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION ... LISTO: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION | 56 | 56 | LISTO" || falla "verificar_instalacion no dice TODO BIEN"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT checksum FROM interno._migraciones WHERE numero = 56")" \
  = "$(sha256sum "$RAIZ"/nucleo/sql/migraciones/056_*.sql | cut -d' ' -f1)" ] || falla "huella de la 056"
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
DECLARE e uuid := pruebas.empresa('A'); r jsonb; eq uuid; bf jsonb; v integer;
BEGIN
  PERFORM pruebas.como('dueno_a');
  PERFORM pruebas.afirmar((SELECT sin_internet_horas = 24 AND sin_internet_tope_venta_centavos = 1000000 FROM public.empresa WHERE id = e), 'reglas por defecto');
  PERFORM pruebas.afirmar((SELECT count(*) FROM public.rol_permiso WHERE empresa_id = e AND permiso LIKE 'ventas.%sin_internet%') = 4, 'permisos repartidos');
  -- Devolución mayorista de una venta de ANTES de actualizar: igual que en 0.19.0.
  r := public.registrar_devolucion(pruebas.id('V_MAY'), jsonb_build_object('lineas', '[{"linea":1,"cantidad":6}]'::jsonb,
         'motivo', 'Le sobraron', 'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('FUERTE')), gen_random_uuid());
  PERFORM pruebas.afirmar((r->>'total_centavos')::bigint = 5400 AND (r->>'ajuste_mayorista_centavos')::bigint = 1800, 'ajuste mayorista: ' || r::text);
  -- Sin internet: equipo, bloque de tickets (sin régimen fiscal), foto y una venta subida.
  eq := (public.registrar_equipo(e, '{"nombre": "Caja 1"}', gen_random_uuid())->>'equipo_id')::uuid;
  bf := public.reservar_bloque_numeros(e, eq, gen_random_uuid(), jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tamano', 10))->'bloques'->0;
  v := (public.preparar_sin_internet(e, eq, jsonb_build_object('caja_id', pruebas.id('CAJA001')))->>'version')::int;
  r := public.subir_ventas_sin_internet(e, eq, jsonb_build_array(jsonb_build_object('id_operacion', gen_random_uuid(),
    'usuario_id', pruebas.usuario('dueno_a'), 'caja_id', pruebas.id('CAJA001'), 'bloque_id', bf->'bloque_id', 'numero', bf->'desde',
    'numero_documento', bf->'desde_texto', 'tipo_documento', bf->'tipo', 'foto_version', v, 'hora_equipo', public.iso(now()),
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'total_centavos', 2200)),
    'pagos', '[{"forma":"efectivo","monto_centavos":2200}]'::jsonb, 'total_centavos', 2200)));
  PERFORM pruebas.afirmar((r->>'registradas')::int = 1, 'venta sin internet: ' || r::text);
  PERFORM pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', e,
    pruebas.venta('P2', 1, 'efectivo') || jsonb_build_object('caja_id', pruebas.id('CAJA001'))), 'BLOQUE_ACTIVO', 'caja con bloque');
END $$;
ROLLBACK;
SQL
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh"
# migrar.sh reconoce lo instalado (misma huella): solo quedan pendientes las migraciones posteriores a la 056.
{ echo "$PEND" | grep -q "No hay migraciones pendientes" || echo "$PEND" | grep -qE "^  - 05[7-9]_"; } \
  && ! echo "$PEND" | grep -E "^  - 0([0-4][0-9]|5[0-6])_" >/dev/null || falla "migrar.sh no reconoce la base actualizada: $PEND"
echo "ok"
