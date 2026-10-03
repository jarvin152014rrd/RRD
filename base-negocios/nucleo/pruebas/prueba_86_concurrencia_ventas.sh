#!/usr/bin/env bash
# PRUEBA: concurrencia de ventas: dos cajeros facturando a la vez en cajas distintas (cada caja numera en su propio rango CAI) y en la misma caja (un solo rango): ningún número se repite ni se salta; la última unidad vendida por dos a la vez: exactamente uno la vende y el otro recibe EXISTENCIA_INSUFICIENTE sin consumir número
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=20
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas();
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Prueba sin turnos');
SELECT pruebas.guardar('CAJA002', (public.crear_caja(pruebas.empresa('A'),
  (SELECT id FROM public.sucursal WHERE empresa_id = pruebas.empresa('A') AND codigo = '001'), 'Caja 2', '002')->>'caja_id')::uuid);
SELECT public.registrar_cai(pruebas.empresa('A'), jsonb_build_object('caja_id', pruebas.id('CAJA002'), 'tipo_documento', 'factura',
  'cai', 'E1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6', 'rango_desde', '001-002-01-00000001', 'rango_hasta', '001-002-01-00001000',
  'fecha_limite_emision', to_char(public.hoy_local(pruebas.empresa('A')) + 180, 'YYYY-MM-DD')));
COMMIT;
SQL

# guion quien caja cantidad archivo
guion() {
  local quien="$1" caja="$2" n="$3" archivo="$4" i
  : > "$archivo"
  for i in $(seq 1 "$n"); do
    cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT 'OK ' || (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 1, 'tarjeta')
  || jsonb_build_object('caja_id', pruebas.id('$caja')), gen_random_uuid())->>'numero_documento');
COMMIT;
SQL
  done
}
correr() {
  psql -X -q -tA -d "$BASE" -f "$1" >"$1.log" 2>&1 & local p1=$!
  psql -X -q -tA -d "$BASE" -f "$2" >"$2.log" 2>&1 & local p2=$!
  wait "$p1" || true; wait "$p2" || true
}

# 1) Cajas distintas a la vez: cada una 1..20 en su rango.
guion cajero_a CAJA001 "$N" "$TMP/a1.sql"
guion admin_a  CAJA002 "$N" "$TMP/a2.sql"
correr "$TMP/a1.sql" "$TMP/a2.sql"
[ "$(grep -c '^OK 001-001-01-' "$TMP/a1.sql.log")" = "$N" ] || { head -5 "$TMP/a1.sql.log"; falla "caja 1: no salieron $N facturas"; }
[ "$(grep -c '^OK 001-002-01-' "$TMP/a2.sql.log")" = "$N" ] || { head -5 "$TMP/a2.sql.log"; falla "caja 2: no salieron $N facturas"; }

# 2) La misma caja a la vez: 21..60 en el rango de la caja 1.
guion cajero_a CAJA001 "$N" "$TMP/b1.sql"
guion admin_a  CAJA001 "$N" "$TMP/b2.sql"
correr "$TMP/b1.sql" "$TMP/b2.sql"
[ "$(cat "$TMP/b1.sql.log" "$TMP/b2.sql.log" | grep -c '^OK 001-001-01-')" = "$((2 * N))" ] || falla "misma caja: faltan facturas"

E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
for pre in 001-001-01 001-002-01; do
  esperado=$([ "$pre" = "001-001-01" ] && echo $((3 * N)) || echo "$N")
  [ "$(q "SELECT count(*) || '|' || count(DISTINCT numero_documento) || '|' || min(right(numero_documento, 8)::int) || '|' || max(right(numero_documento, 8)::int)
          FROM public.venta WHERE empresa_id = $E AND numero_documento LIKE '$pre-%'")" = "$esperado|$esperado|1|$esperado" ] \
    || falla "rango $pre: se esperaban $esperado facturas del 1 al $esperado sin huecos ni repetidos"
done

# 3) La última unidad: quedan 10 galones; el admin vende 9 y luego dos venden 1 a la vez.
q "BEGIN; SELECT pruebas.como('admin_a'); SELECT public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P3', 9, 'tarjeta') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid()); COMMIT;" >/dev/null
cat > "$TMP/c1.sql" <<'SQL'
BEGIN;
SELECT pruebas.como('cajero_a');
SELECT 'OK ' || (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P3', 1, 'tarjeta') || jsonb_build_object('caja_id', pruebas.id('CAJA001')), gen_random_uuid())->>'numero_documento');
COMMIT;
SQL
sed 's/cajero_a/admin_a/' "$TMP/c1.sql" > "$TMP/c2.sql"
correr "$TMP/c1.sql" "$TMP/c2.sql"
ok=$(cat "$TMP/c1.sql.log" "$TMP/c2.sql.log" | grep -c '^OK' || true)
sin=$(cat "$TMP/c1.sql.log" "$TMP/c2.sql.log" | grep -c 'EXISTENCIA_INSUFICIENTE' || true)
[ "$ok" = "1" ] && [ "$sin" = "1" ] || { cat "$TMP/c1.sql.log" "$TMP/c2.sql.log"; falla "última unidad: se esperaba 1 venta y 1 rechazo; hubo $ok y $sin"; }
[ "$(q "SELECT pruebas.existencia('B1', 'P3') || '|' || pruebas.valor('B1', 'P3')")" = "0.0000|0" ] || falla "pintura en 0 unidades y L 0.00"
# 60 + 1 (9 galones) + 1 (la última) = 62, sin huecos.
[ "$(q "SELECT count(*) || '|' || max(right(numero_documento, 8)::int) FROM public.venta WHERE empresa_id = $E AND numero_documento LIKE '001-001-01-%'")" = "62|62" ] \
  || falla "el rechazo no debe consumir número"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
        WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] \
  || falla "kardex distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok: 2 cajas x $N y misma caja 2 x $N sin huecos; última unidad vendida una sola vez"
