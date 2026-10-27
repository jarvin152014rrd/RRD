#!/usr/bin/env bash
# PRUEBA: (0.20.0) vender sin internet a la vez: dos equipos reservan la MISMA caja al mismo tiempo (uno la recibe, el otro BLOQUE_ACTIVO); dos equipos en cajas distintas suben a la vez (cada rango CAI queda correlativo, sin huecos ni repetidos); la misma tanda subida dos veces a la vez (dos pestañas o un reintento) no duplica nada
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }
N=10

psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas();
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Prueba sin turnos');
SELECT pruebas.guardar('CAJA002', (public.crear_caja(pruebas.empresa('A'),
  (SELECT id FROM public.sucursal WHERE empresa_id = pruebas.empresa('A') AND codigo = '001'), 'Caja 2', '002')->>'caja_id')::uuid);
SELECT public.registrar_cai(pruebas.empresa('A'), jsonb_build_object('caja_id', pruebas.id('CAJA002'), 'tipo_documento', 'factura',
  'cai', 'E1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-002-01-00000001', 'rango_hasta', '001-002-01-00001000',
  'fecha_limite_emision', to_char(public.hoy_local(pruebas.empresa('A')) + 180, 'YYYY-MM-DD')));
SELECT pruebas.guardar('EQ1', (public.registrar_equipo(pruebas.empresa('A'), '{"nombre": "Equipo 1"}', gen_random_uuid())->>'equipo_id')::uuid);
SELECT pruebas.guardar('EQ2', (public.registrar_equipo(pruebas.empresa('A'), '{"nombre": "Equipo 2"}', gen_random_uuid())->>'equipo_id')::uuid);
COMMIT;
SQL

correr() {
  psql -X -q -tA -d "$BASE" -f "$1" >"$1.log" 2>&1 & local p1=$!
  psql -X -q -tA -d "$BASE" -f "$2" >"$2.log" 2>&1 & local p2=$!
  wait "$p1" || true; wait "$p2" || true
}

# 1) Los dos equipos piden la caja 1 a la vez.
for i in 1 2; do
  cat > "$TMP/r$i.sql" <<SQL
BEGIN;
SELECT pruebas.como('$([ $i = 1 ] && echo dueno_a || echo admin_a)');
SELECT 'OK ' || (public.reservar_bloque_numeros(pruebas.empresa('A'), pruebas.id('EQ$i'), gen_random_uuid(),
  jsonb_build_object('caja_id', pruebas.id('CAJA001'), 'tamano', 20))->'bloques'->0->>'desde_texto');
COMMIT;
SQL
done
correr "$TMP/r1.sql" "$TMP/r2.sql"
[ "$(cat "$TMP/r1.sql.log" "$TMP/r2.sql.log" | grep -c '^OK 001-001-01-00000001')" = "1" ] \
  || { cat "$TMP"/r*.log; falla "la caja 1 debía quedar en UN solo equipo"; }
[ "$(cat "$TMP/r1.sql.log" "$TMP/r2.sql.log" | grep -c 'BLOQUE_ACTIVO')" = "1" ] || { cat "$TMP"/r*.log; falla "el otro equipo debía recibir BLOQUE_ACTIVO"; }
GANO="$(grep -l '^OK' "$TMP/r1.sql.log" >/dev/null && echo 1 || echo 2)"
OTRO=$((3 - GANO))
QUIEN_GANO=$([ "$GANO" = 1 ] && echo dueno_a || echo admin_a)
QUIEN_OTRO=$([ "$OTRO" = 1 ] && echo dueno_a || echo admin_a)
# El otro equipo toma la caja 2.
q "BEGIN; SELECT pruebas.como('$QUIEN_OTRO'); SELECT public.reservar_bloque_numeros(pruebas.empresa('A'), pruebas.id('EQ$OTRO'), gen_random_uuid(),
     jsonb_build_object('caja_id', pruebas.id('CAJA002'), 'tamano', 20)); COMMIT;" >/dev/null

# 2) Cada equipo sube N ventas (una por llamada) a la vez; y la misma tanda dos veces a la vez.
guion() {   # quien equipo caja archivo [primera]
  local quien="$1" eq="$2" caja="$3" archivo="$4" i
  : > "$archivo"
  for i in $(seq 1 "$N"); do
    cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT 'OK ' || (r->'resultados'->0->>'estado') || ' ' || (r->'resultados'->0->>'numero_documento') FROM (
SELECT public.subir_ventas_sin_internet(pruebas.empresa('A'), pruebas.id('$eq'), jsonb_build_array(jsonb_build_object(
  'id_operacion', md5('$eq-$i')::uuid, 'usuario_id', pruebas.usuario('$quien'), 'caja_id', pruebas.id('$caja'),
  'bloque_id', b->'bloque_id', 'numero', (b->>'desde')::int + $i - 1,
  'numero_documento', (b->>'prefijo') || '-' || lpad(((b->>'desde')::int + $i - 1)::text, 8, '0'), 'tipo_documento', 'factura',
  'foto_version', (SELECT max(version) FROM public.catalogo_foto), 'hora_equipo', public.iso(now()),
  'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 1, 'total_centavos', 2200)),
  'pagos', '[{"forma":"efectivo","monto_centavos":2200}]'::jsonb, 'total_centavos', 2200))) AS r
  FROM (SELECT public.bloques_del_equipo(pruebas.empresa('A'), pruebas.id('$eq'))->'bloques'->0 AS b) z) y;
COMMIT;
SQL
  done
}
q "BEGIN; SELECT pruebas.como('dueno_a'); SELECT public.preparar_sin_internet(pruebas.empresa('A'), pruebas.id('EQ1'), jsonb_build_object('caja_id', pruebas.id('CAJA001'))); COMMIT;" >/dev/null
CAJA_GANO=CAJA001; CAJA_OTRO=CAJA002
guion "$QUIEN_GANO" "EQ$GANO" "$CAJA_GANO" "$TMP/s1.sql"
guion "$QUIEN_OTRO" "EQ$OTRO" "$CAJA_OTRO" "$TMP/s2.sql"
correr "$TMP/s1.sql" "$TMP/s2.sql"
[ "$(grep -c '^OK registrada 001-001-01-' "$TMP/s1.sql.log")" = "$N" ] || { head -8 "$TMP/s1.sql.log"; falla "caja 1: no se registraron $N"; }
[ "$(grep -c '^OK registrada 001-002-01-' "$TMP/s2.sql.log")" = "$N" ] || { head -8 "$TMP/s2.sql.log"; falla "caja 2: no se registraron $N"; }
# La misma tanda dos veces a la vez: todo "ya estaba".
cp "$TMP/s1.sql" "$TMP/d1.sql"; cp "$TMP/s1.sql" "$TMP/d2.sql"
correr "$TMP/d1.sql" "$TMP/d2.sql"
[ "$(cat "$TMP/d1.sql.log" "$TMP/d2.sql.log" | grep -c '^OK ya_estaba')" = "$((2 * N))" ] || { head -5 "$TMP/d1.sql.log"; falla "repetir a la vez debía dar ya_estaba"; }

E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
for pre in 001-001-01 001-002-01; do
  [ "$(q "SELECT count(*) || '|' || count(DISTINCT numero_documento) || '|' || min(right(numero_documento, 8)::int) || '|' || max(right(numero_documento, 8)::int)
          FROM public.venta WHERE empresa_id = $E AND numero_documento LIKE '$pre-%'")" = "$N|$N|1|$N" ] \
    || falla "rango $pre: se esperaban $N facturas del 1 al $N sin huecos ni repetidos"
done
[ "$(q "SELECT count(*) FROM public.venta_sin_internet WHERE empresa_id = $E")" = "$((2 * N))" ] || falla "ventas sin internet duplicadas"
echo ok
