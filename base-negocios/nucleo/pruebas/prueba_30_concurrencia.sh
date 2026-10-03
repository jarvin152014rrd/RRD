#!/usr/bin/env bash
# PRUEBA: dos sesiones registrando asientos a la vez no repiten número, no dejan huecos ni duplican reintentos
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=40          # asientos propios por sesión
COMPARTIDOS=10  # operaciones que AMBAS sesiones mandan con el mismo id_operacion (reintento)

# Arma el guion de una sesión: una transacción por asiento, como la app.
guion() {
  local quien="$1" archivo="$2" i
  : > "$archivo"
  for i in $(seq 1 "$N"); do
    cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-15', '$quien venta $i',
       pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid());
COMMIT;
SQL
    # Intercala operaciones compartidas.
    if [ "$i" -le "$COMPARTIDOS" ]; then
      cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-16', 'Cobro compartido $i',
       pruebas.lineas('1.1.01.01', '4.1.01.01', 1000), ('cccccccc-0000-0000-0000-' || lpad('$i', 12, '0'))::uuid);
COMMIT;
SQL
    fi
  done
}
guion dueno_a "$TMP/s1.sql"
guion admin_a "$TMP/s2.sql"

# Las dos sesiones a la vez.
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" -f "$TMP/s1.sql" >"$TMP/s1.log" 2>&1 & p1=$!
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" -f "$TMP/s2.sql" >"$TMP/s2.log" 2>&1 & p2=$!
ok=0
wait "$p1" || { echo "sesión 1:"; grep -E 'ERROR' "$TMP/s1.log" | head -3; ok=1; }
wait "$p2" || { echo "sesión 2:"; grep -E 'ERROR' "$TMP/s2.log" | head -3; ok=1; }
[ "$ok" = "0" ] || falla "una sesión tuvo errores"

q() { psql -X -q -tA -d "$BASE" -c "$1"; }
esperados=$((2 * N + COMPARTIDOS))
datos="$(q "SELECT count(*), count(DISTINCT numero), min(numero), max(numero) FROM public.asiento
            WHERE empresa_id = (SELECT valor FROM pruebas.dato WHERE clave = 'A')")"
[ "$datos" = "$esperados|$esperados|1|$esperados" ] \
  || falla "se esperaban $esperados asientos numerados 1..$esperados sin repetir; salió (total|distintos|min|max) = $datos"
[ "$(q "SELECT count(*) FROM public.asiento WHERE id_operacion::text LIKE 'cccccccc-%'")" = "$COMPARTIDOS" ] \
  || falla "los reintentos compartidos se duplicaron"
# Caja a mano: 2*40*100 + 10*1000 = 18000 centavos.
[ "$(q "SELECT saldo_centavos FROM public.v_saldo_cuenta WHERE empresa_id = (SELECT valor FROM pruebas.dato WHERE clave = 'A') AND codigo = '1.1.01.01'")" = "18000" ] \
  || falla "saldo de caja distinto de 18000"
# La bitácora encadenada sigue intacta con escrituras simultáneas.
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la cadena de la bitácora se rompió"
echo "ok: $esperados asientos, números 1..$esperados"
