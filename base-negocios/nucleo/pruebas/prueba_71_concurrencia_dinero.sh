#!/usr/bin/env bash
# PRUEBA: dos sesiones sacan dinero de la misma caja a la vez (más de lo que hay): exactamente lo que alcanza se guarda, la caja nunca queda en negativo, las operaciones quedan numeradas sin huecos y el rastro cuadra con los libros
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=20          # traslados de 10,000 por sesión (40 x 10,000 = 400,000 > 300,000 que hay)
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_dinero();     -- caja fuerte 300,000; BAC 1,000,000 (2 operaciones de saldo inicial)
COMMIT;
SQL

guion() {
  local quien="$1" archivo="$2" i
  : > "$archivo"
  for i in $(seq 1 "$N"); do
    cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT 'OK ' || (public.trasladar_dinero(pruebas.empresa('A'), jsonb_build_object('tipo', 'traslado',
  'origen_id', pruebas.id('FUERTE'), 'destino_id', pruebas.id('BANCO'), 'monto_centavos', 10000), gen_random_uuid())->>'numero');
COMMIT;
SQL
  done
}
guion dueno_a "$TMP/s1.sql"
guion admin_a "$TMP/s2.sql"
psql -X -q -tA -d "$BASE" -f "$TMP/s1.sql" >"$TMP/s1.log" 2>&1 & p1=$!
psql -X -q -tA -d "$BASE" -f "$TMP/s2.sql" >"$TMP/s2.log" 2>&1 & p2=$!
wait "$p1" || true; wait "$p2" || true

ok=$(( $(grep -c '^OK' "$TMP/s1.log" || true) + $(grep -c '^OK' "$TMP/s2.log" || true) ))
sin=$(( $(grep -c 'SALDO_INSUFICIENTE' "$TMP/s1.log" || true) + $(grep -c 'SALDO_INSUFICIENTE' "$TMP/s2.log" || true) ))
otros="$(cat "$TMP/s1.log" "$TMP/s2.log" | grep 'ERROR' | grep -vc 'SALDO_INSUFICIENTE' || true)"
[ "$otros" = "0" ] || { cat "$TMP/s1.log" "$TMP/s2.log" | grep ERROR | grep -v SALDO_INSUFICIENTE | head -3; falla "errores inesperados"; }
# A mano: 300,000 / 10,000 = 30 traslados pasan y 10 no.
[ "$ok" = "30" ] && [ "$sin" = "10" ] || falla "se esperaban 30 bien y 10 sin saldo; hubo $ok y $sin"
E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
[ "$(q "SELECT pruebas.dinero('FUERTE') || '|' || pruebas.dinero('BANCO')")" = "0|1300000" ] || falla "saldos: caja fuerte 0 y BAC 1,300,000"
[ "$(q "SELECT count(*) || '|' || min(numero) || '|' || max(numero) FROM public.operacion_dinero WHERE empresa_id = $E")" = "32|1|32" ] \
  || falla "operaciones numeradas sin huecos (2 saldos iniciales + 30 traslados)"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
        WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] || falla "rastro distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok: 30 traslados, 10 rechazados sin saldo, caja en 0"
