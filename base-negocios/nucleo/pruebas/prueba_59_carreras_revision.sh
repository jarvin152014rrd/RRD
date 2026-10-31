#!/usr/bin/env bash
# PRUEBA: carreras entre dos sesiones (revisión 0.4.0): el mismo id_operacion en una compra y en un asiento manual a la vez da ID_OPERACION_USADO (C); activar inventario mientras otra sesión mete un asiento a 1.1.03.01 da MODULO_CON_SALDO (B); quitar "decimales" mientras otra sesión deja una existencia fraccionaria (y al revés) nunca deja fracciones en un producto sin decimales (F)
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }
E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"

# Corre dos guiones a la vez: el primero toma el candado y espera; el
# segundo empieza 0.5 s después (queda esperando el candado).
dos_a_la_vez() {
  psql -X -q -tA -d "$BASE" -f "$TMP/s1.sql" >"$TMP/s1.log" 2>&1 & local p1=$!
  psql -X -q -tA -d "$BASE" -f "$TMP/s2.sql" >"$TMP/s2.log" 2>&1 & local p2=$!
  wait "$p1" || true; wait "$p2" || true
}

# ---------------------------------------------------------------------
# B) Activar inventario mientras otra sesión registra un asiento a 1.1.03.01
#    (el módulo aún no está activo, así que el asiento manual es válido).
# ---------------------------------------------------------------------
cat > "$TMP/s1.sql" <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'ASIENTO ' || (public.registrar_asiento(pruebas.empresa('A'), '2026-01-05', 'Inventario sin módulo',
  pruebas.lineas('1.1.03.01', '3.1.01.01', 70000), gen_random_uuid())->>'numero');
SELECT pg_sleep(1.5);
COMMIT;
SQL
cat > "$TMP/s2.sql" <<'SQL'
SELECT pg_sleep(0.5);
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'inventario');
SELECT 'ACTIVADO';
SQL
dos_a_la_vez
grep -q '^ASIENTO' "$TMP/s1.log" || { cat "$TMP/s1.log"; falla "B: el asiento no entró"; }
grep -q 'MODULO_CON_SALDO' "$TMP/s2.log" || { cat "$TMP/s2.log"; falla "B: activó inventario con un saldo que el kardex no explica"; }
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE empresa_id = $E AND modulo = 'inventario' AND activo")" = "0" ] \
  || falla "B: quedó activo"
# Se deja la empresa como estaba para lo que sigue (contra-asiento).
q "BEGIN; SELECT pruebas.como('dueno_a'); SELECT public.anular_asiento((SELECT id FROM public.asiento WHERE empresa_id = $E AND descripcion = 'Inventario sin módulo'), 'Era una prueba', gen_random_uuid()); COMMIT;" >/dev/null

# ---------------------------------------------------------------------
# C) Mismo id_operacion: compra en la sesión 1, asiento manual en la 2.
# ---------------------------------------------------------------------
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
COMMIT;
SQL
ID="eeeeeeee-0000-0000-0000-000000000001"
cat > "$TMP/s1.sql" <<SQL
BEGIN;
SELECT pruebas.como('admin_a');
SELECT 'COMPRA ' || (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'CARRERA-1', '2026-01-10', 'credito', 'P1', 1, 1000), '$ID')->>'numero');
SELECT pg_sleep(1.5);
COMMIT;
SQL
cat > "$TMP/s2.sql" <<SQL
SELECT pg_sleep(0.5);
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'ASIENTO ' || public.registrar_asiento(pruebas.empresa('A'), '2026-01-10', 'Mismo id', pruebas.lineas('1.1.01.01', '4.1.01.01', 500), '$ID')::text;
COMMIT;
SQL
dos_a_la_vez
grep -q '^COMPRA' "$TMP/s1.log" || { cat "$TMP/s1.log"; falla "C: la compra no entró"; }
grep -q 'ID_OPERACION_USADO' "$TMP/s2.log" || { cat "$TMP/s2.log"; falla "C: el asiento con el mismo id no dio ID_OPERACION_USADO"; }
[ "$(q "SELECT count(*) FROM public.asiento WHERE empresa_id = $E AND descripcion = 'Mismo id'")" = "0" ] || falla "C: entró el asiento"

# ---------------------------------------------------------------------
# F1) Sesión 1 deja 2.5 lb de arroz (P2, con decimales); sesión 2 quita los decimales.
# F2) Al revés con azúcar (P4): sesión 1 quita los decimales; sesión 2 cuenta 4.5.
# ---------------------------------------------------------------------
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT pruebas.guardar('P4', (public.crear_producto(pruebas.empresa('A'), jsonb_build_object('codigo', 'AZU-001', 'nombre', 'Azúcar',
  'unidad_id', (SELECT id FROM public.unidad WHERE empresa_id IS NULL AND codigo = 'LB'), 'tipo_impuesto', 'EXENTO',
  'permite_fracciones', true), gen_random_uuid())->>'producto_id')::uuid);
SELECT public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B2'), '2026-01-02', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 2, 'costo_unitario', 1000),
  jsonb_build_object('producto_id', pruebas.id('P4'), 'cantidad', 4, 'costo_unitario', 1000)), gen_random_uuid());
COMMIT;
SQL
cat > "$TMP/s1.sql" <<'SQL'
BEGIN;
SELECT pruebas.como('admin_a');
SELECT 'AJUSTE ' || (public.ajustar_inventario(pruebas.empresa('A'), pruebas.id('B2'), '2026-01-03',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad_contada', 2.5)), 'Conteo de arroz', gen_random_uuid())->>'numero');
SELECT pg_sleep(1.5);
COMMIT;
SQL
cat > "$TMP/s2.sql" <<'SQL'
SELECT pg_sleep(0.5);
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'EDITADO ' || public.editar_producto(pruebas.empresa('A'), pruebas.id('P2'), '{"permite_fracciones": false}', 'Solo libras enteras')::text;
COMMIT;
SQL
dos_a_la_vez
grep -q '^AJUSTE' "$TMP/s1.log" || { cat "$TMP/s1.log"; falla "F1: el ajuste no entró"; }
grep -q 'NO_PERMITIDO' "$TMP/s2.log" || { cat "$TMP/s2.log"; falla "F1: quitó los decimales con 2.5 en existencia"; }

cat > "$TMP/s1.sql" <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'EDITADO ' || public.editar_producto(pruebas.empresa('A'), pruebas.id('P4'), '{"permite_fracciones": false}', 'Solo libras enteras')::text;
SELECT pg_sleep(1.5);
COMMIT;
SQL
cat > "$TMP/s2.sql" <<'SQL'
SELECT pg_sleep(0.5);
BEGIN;
SELECT pruebas.como('admin_a');
SELECT 'AJUSTE ' || (public.ajustar_inventario(pruebas.empresa('A'), pruebas.id('B2'), '2026-01-03',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P4'), 'cantidad_contada', 4.5)), 'Conteo de azúcar', gen_random_uuid())->>'numero');
COMMIT;
SQL
dos_a_la_vez
grep -q '^EDITADO' "$TMP/s1.log" || { cat "$TMP/s1.log"; falla "F2: no quitó los decimales"; }
grep -q 'CANTIDAD_INVALIDA' "$TMP/s2.log" || { cat "$TMP/s2.log"; falla "F2: dejó 4.5 en un producto sin decimales"; }

[ "$(q "SELECT count(*) FROM public.inventario_saldo s JOIN public.producto p ON p.id = s.producto_id
        WHERE NOT p.permite_fracciones AND s.cantidad <> trunc(s.cantidad)")" = "0" ] || falla "hay existencias fraccionarias sin decimales"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] \
  || falla "kardex distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
