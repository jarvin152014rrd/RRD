#!/usr/bin/env bash
# PRUEBA: cerrar el mes mientras otra sesión registra asientos, compras y pagos con fecha de ese mes: nada entra después del cierre, cada operación queda completa o no queda, kardex = libros y bitácora intacta
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=40
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

# Preparación: inventario, 1000 tornillos a 1000 en B1 y una compra al crédito para abonar.
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.como('admin_a');
SELECT public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B1'), '2026-01-02',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1000, 'costo_unitario', 1000)), gen_random_uuid());
SELECT pruebas.guardar('C0', (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'BASE', '2026-01-03', 'credito', 'P1', 100, 1000), gen_random_uuid())->>'compra_id')::uuid);
COMMIT;
SQL

# Sesión 1: por cada vuelta, un asiento, una compra y un abono con fecha 20/01 (una transacción cada uno).
: > "$TMP/s1.sql"
for i in $(seq 1 "$N"); do
  cat >> "$TMP/s1.sql" <<SQL
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'OK-ASIENTO ' || (public.registrar_asiento(pruebas.empresa('A'), '2026-01-20', 'Venta $i', pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid())->>'numero');
COMMIT;
BEGIN;
SELECT pruebas.como('admin_a');
SELECT 'OK-COMPRA ' || (public.registrar_compra(pruebas.empresa('A'), pruebas.compra('PROV1', 'B1', 'CC-$i', '2026-01-20', 'credito', 'P1', 1, 1000), gen_random_uuid())->>'numero');
COMMIT;
BEGIN;
SELECT pruebas.como('admin_a');
SELECT 'OK-PAGO ' || (public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('C0'), 100, '2026-01-20', 'caja', gen_random_uuid())->>'numero');
COMMIT;
SQL
done
# Sesión 2: espera un poco y cierra enero.
cat > "$TMP/s2.sql" <<'SQL'
SELECT pg_sleep(0.3);
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT 'CERRADO ' || (public.cerrar_periodo(pruebas.empresa('A'), 2026, 1)->>'estado');
COMMIT;
SQL

psql -X -q -tA -d "$BASE" -f "$TMP/s1.sql" >"$TMP/s1.log" 2>&1 & p1=$!
psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -f "$TMP/s2.sql" >"$TMP/s2.log" 2>&1 & p2=$!
wait "$p1" || true
wait "$p2" || { cat "$TMP/s2.log"; falla "el cierre falló"; }
grep -q "CERRADO cerrado" "$TMP/s2.log" || { cat "$TMP/s2.log"; falla "enero no quedó cerrado"; }

# Cada operación: o se guardó (OK-...) o la rechazó el mes cerrado. Ningún otro error.
ok="$(grep -c '^OK-' "$TMP/s1.log" || true)"
cerrado="$(grep -c 'PERIODO_CERRADO' "$TMP/s1.log" || true)"
otros="$(grep 'ERROR' "$TMP/s1.log" | grep -vc 'PERIODO_CERRADO' || true)"
[ "$otros" = "0" ] || { grep 'ERROR' "$TMP/s1.log" | grep -v PERIODO_CERRADO | head -3; falla "errores distintos de PERIODO_CERRADO"; }
[ $((ok + cerrado)) = $((3 * N)) ] || falla "se esperaban $((3 * N)) resultados; hubo $ok bien y $cerrado rechazados"

E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
# Nada con fecha de enero se registró DESPUÉS de cerrar enero. Se compara el
# orden real de la bitácora encadenada (la hora now() es la de inicio de cada transacción).
[ "$(q "SELECT count(*) FROM public.bitacora b
        WHERE b.empresa_id = $E AND b.tabla = 'asiento' AND b.accion = 'INSERT'
          AND (b.despues->>'fecha_contable')::date BETWEEN '2026-01-01' AND '2026-01-31'
          AND b.secuencia > (SELECT max(c.secuencia) FROM public.bitacora c WHERE c.empresa_id = $E AND c.tabla = 'periodo'
                              AND c.despues->>'anio' = '2026' AND c.despues->>'mes' = '1' AND c.despues->>'estado' = 'cerrado')")" = "0" ] \
  || falla "entró un asiento de enero después del cierre"
# Lo guardado coincide con lo que la sesión vio: asientos manuales, compras y pagos.
[ "$(q "SELECT count(*) FROM public.asiento WHERE empresa_id = $E AND origen = 'manual'")" = "$(grep -c '^OK-ASIENTO' "$TMP/s1.log" || true)" ] || falla "asientos manuales no cuadran"
[ "$(q "SELECT count(*) - 1 FROM public.compra WHERE empresa_id = $E")" = "$(grep -c '^OK-COMPRA' "$TMP/s1.log" || true)" ] || falla "compras no cuadran"
[ "$(q "SELECT count(*) FROM public.pago_proveedor WHERE empresa_id = $E")" = "$(grep -c '^OK-PAGO' "$TMP/s1.log" || true)" ] || falla "pagos no cuadran"
# Numeración sin huecos, kardex = libros, CxP = libros, bitácora intacta.
[ "$(q "SELECT count(*) = max(numero) AND count(DISTINCT numero) = count(*) FROM public.asiento WHERE empresa_id = $E")" = "t" ] || falla "números de asiento con huecos"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] || falla "kardex distinto de libros"
[ "$(q "SELECT interno.total_cxp($E) = pruebas.saldo_libros($E, '2.1.01.01')")" = "t" ] || falla "CxP distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora se rompió"
# Y después del cierre, enero ya no recibe nada.
if q "BEGIN; SELECT pruebas.como('dueno_a'); SELECT public.registrar_asiento($E, '2026-01-31', 'Tarde', pruebas.lineas('1.1.01.01', '4.1.01.01', 1), gen_random_uuid()); COMMIT;" >/dev/null 2>"$TMP/err"; then
  falla "aceptó un asiento en enero cerrado"
fi
grep -q PERIODO_CERRADO "$TMP/err" || falla "el error no es PERIODO_CERRADO"
echo "ok: $ok guardadas antes del cierre, $cerrado rechazadas después"
