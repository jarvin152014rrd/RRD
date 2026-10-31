#!/usr/bin/env bash
# PRUEBA: dos sesiones comprando y trasladando el mismo producto a la vez: saldos exactos, kardex = libros, compras numeradas sin repetir y reintentos sin duplicar
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=20          # compras y traslados por sesión
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

# Preparación: módulos, bodegas, productos y 100 tornillos a 1000 en B1.
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.como('admin_a');
SELECT public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B1'), '2026-01-02',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000)), gen_random_uuid());
COMMIT;
SQL

# Guion de una sesión: compra 1 tornillo a 1000 (crédito) y traslada 1 de B1 a B2.
# Las 5 primeras compras se mandan con un id_operacion COMPARTIDO por las dos sesiones.
guion() {
  local quien="$1" archivo="$2" i id
  : > "$archivo"
  for i in $(seq 1 "$N"); do
    if [ "$i" -le 5 ]; then id="'dddddddd-0000-0000-0000-$(printf '%012d' "$i")'::uuid"; else id="gen_random_uuid()"; fi
    cat >> "$archivo" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', '$quien-$i', '2026-01-10', 'credito', 'P1', 1, 1000), $id);
COMMIT;
BEGIN;
SELECT pruebas.como('$quien');
SELECT public.trasladar_inventario(pruebas.empresa('A'), pruebas.id('B1'), pruebas.id('B2'), '2026-01-10',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)), gen_random_uuid());
COMMIT;
SQL
  done
}
guion dueno_a "$TMP/s1.sql"
guion admin_a "$TMP/s2.sql"

psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" -f "$TMP/s1.sql" >"$TMP/s1.log" 2>&1 & p1=$!
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" -f "$TMP/s2.sql" >"$TMP/s2.log" 2>&1 & p2=$!
ok=0
wait "$p1" || { echo "sesión 1:"; grep -E 'ERROR' "$TMP/s1.log" | head -3; ok=1; }
wait "$p2" || { echo "sesión 2:"; grep -E 'ERROR' "$TMP/s2.log" | head -3; ok=1; }
[ "$ok" = "0" ] || falla "una sesión tuvo errores"

# A mano: compras = 2*20 - 5 compartidas = 35 (las compartidas entran una sola vez).
# B1 = 100 + 35 - 40 = 95; B2 = 40. Todo a 1000: valores 95,000 y 40,000.
# Libros: inventario 100,000 + 35,000 = 135,000; CxP 35 x 1,150 = 40,250.
E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
[ "$(q "SELECT count(*) || '|' || count(DISTINCT numero) || '|' || min(numero) || '|' || max(numero) FROM public.compra WHERE empresa_id = $E")" = "35|35|1|35" ] \
  || falla "compras: se esperaban 35 numeradas 1..35"
[ "$(q "SELECT pruebas.existencia('B1','P1') || '|' || pruebas.valor('B1','P1') || '|' || pruebas.existencia('B2','P1') || '|' || pruebas.valor('B2','P1')")" = "95.0000|95000|40.0000|40000" ] \
  || falla "saldos: $(q "SELECT pruebas.existencia('B1','P1') || '|' || pruebas.valor('B1','P1') || '|' || pruebas.existencia('B2','P1') || '|' || pruebas.valor('B2','P1')")"
[ "$(q "SELECT pruebas.saldo_libros($E, '1.1.03.01') || '|' || pruebas.saldo_libros($E, '2.1.01.01')")" = "135000|40250" ] \
  || falla "libros distintos de 135000|40250"
[ "$(q "SELECT count(*) FROM public.inventario_movimiento m JOIN public.inventario_saldo s USING (bodega_id, producto_id)
        WHERE m.id = s.ultimo_movimiento_id AND (m.saldo_cantidad, m.saldo_valor_centavos) IS DISTINCT FROM (s.cantidad, s.valor_centavos)")" = "0" ] \
  || falla "el último movimiento no coincide con el saldo"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora se rompió"
echo "ok: 35 compras, B1 95, B2 40, kardex = libros"
