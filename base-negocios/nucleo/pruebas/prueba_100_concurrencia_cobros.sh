#!/usr/bin/env bash
# PRUEBA: concurrencia de cobros y vales: dos cajeros cobran a la vez la misma factura (10 facturas de 23,000; cada uno quiere aplicar 15,000 a cada una): en cada factura entra exactamente un cobro y el otro recibe COBRO_EXCEDE_SALDO (nunca se cobra más del saldo); el mismo vale de 3,000 usado a la vez en dos ventas de 3,000 (10 vales): exactamente una venta lo usa y la otra recibe SALDO_FAVOR_INSUFICIENTE; todo cuadra
set -euo pipefail
BASE="$1"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
falla() { echo "FALLA: $*"; exit 1; }
N=10
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$BASE" -c "$1"; }

psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<SQL
BEGIN;
SELECT pruebas.preparar_ventas(false);
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Prueba sin turnos');
SELECT pruebas.como('cajero_a');
-- N facturas al crédito de 23,000 (1 h de servicio) y N vales de 3,000 (venta a consumidor final devuelta como nota de crédito).
SELECT pruebas.guardar('V' || i, (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('S1', 1, 'credito', 'CLI1'), gen_random_uuid())->>'venta_id')::uuid)
  FROM generate_series(1, $N) i;
SELECT pruebas.guardar('W' || i, (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 2, 'efectivo'), gen_random_uuid())->>'venta_id')::uuid)
  FROM generate_series(1, $N) i;
SELECT pruebas.como('dueno_a');
SELECT pruebas.guardar('VALE' || i, (public.registrar_devolucion(pruebas.id('W' || i),
  '{"lineas":[{"linea":1,"cantidad":2}],"motivo":"Prueba de vales","destino":"saldo_favor"}', gen_random_uuid())->'saldo_favor'->>'saldo_favor_id')::uuid)
  FROM generate_series(1, $N) i;
COMMIT;
SQL

correr() {
  psql -X -q -tA -d "$BASE" -f "$1" >"$1.log" 2>&1 & local p1=$!
  psql -X -q -tA -d "$BASE" -f "$2" >"$2.log" 2>&1 & local p2=$!
  wait "$p1" || true; wait "$p2" || true
}

# 1) Dos cobros a la vez a la misma factura.
for quien in cajero_a admin_a; do
  : > "$TMP/c_$quien.sql"
  for i in $(seq 1 "$N"); do
    cat >> "$TMP/c_$quien.sql" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT 'OK ' || (public.registrar_cobro(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI1'),
  'aplicar', jsonb_build_array(jsonb_build_object('venta_id', pruebas.id('V$i'), 'monto_centavos', 15000)),
  'pagos', '[{"forma":"tarjeta","monto_centavos":15000}]'::jsonb), gen_random_uuid())->>'cobro_id');
COMMIT;
SQL
  done
done
correr "$TMP/c_cajero_a.sql" "$TMP/c_admin_a.sql"
ok=$(cat "$TMP"/c_*.sql.log | grep -c '^OK' || true)
exc=$(cat "$TMP"/c_*.sql.log | grep -c 'COBRO_EXCEDE_SALDO' || true)
[ "$ok" = "$N" ] && [ "$exc" = "$N" ] || { cat "$TMP"/c_*.sql.log | head -20; falla "cobros: se esperaban $N cobros y $N rechazos; hubo $ok y $exc"; }
E="(SELECT valor FROM pruebas.dato WHERE clave = 'A')"
[ "$(q "SELECT count(*) FROM generate_series(1, $N) i WHERE interno.saldo_documento_cxc(pruebas.id('V' || i)) <> 8000")" = "0" ] \
  || falla "cada factura debe quedar en 8,000"
[ "$(q "SELECT interno.total_cxc($E) = pruebas.saldo_libros($E, '1.1.02.01') AND interno.total_cxc($E) = $N * 8000")" = "t" ] || falla "CxC = Clientes"

# 2) El mismo vale usado a la vez en dos ventas de 3,000.
for quien in cajero_a admin_a; do
  : > "$TMP/v_$quien.sql"
  for i in $(seq 1 "$N"); do
    cat >> "$TMP/v_$quien.sql" <<SQL
BEGIN;
SELECT pruebas.como('$quien');
SELECT 'OK ' || (public.registrar_venta(pruebas.empresa('A'), jsonb_build_object('lineas',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
  'pagos', jsonb_build_array(jsonb_build_object('forma', 'saldo_favor', 'saldo_favor_id', pruebas.id('VALE$i')))), gen_random_uuid())->>'venta_id');
COMMIT;
SQL
  done
done
correr "$TMP/v_cajero_a.sql" "$TMP/v_admin_a.sql"
ok=$(cat "$TMP"/v_*.sql.log | grep -c '^OK' || true)
ins=$(cat "$TMP"/v_*.sql.log | grep -c 'SALDO_FAVOR_INSUFICIENTE' || true)
[ "$ok" = "$N" ] && [ "$ins" = "$N" ] || { cat "$TMP"/v_*.sql.log | head -20; falla "vales: se esperaban $N ventas y $N rechazos; hubo $ok y $ins"; }
[ "$(q "SELECT count(*) FROM generate_series(1, $N) i WHERE interno.saldo_favor_lote(pruebas.id('VALE' || i)) <> 0
        OR (SELECT count(*) FROM public.saldo_favor_uso u WHERE u.saldo_favor_id = pruebas.id('VALE' || i) AND u.anulado_en IS NULL) <> 1")" = "0" ] \
  || falla "cada vale se usa una sola vez"
[ "$(q "SELECT interno.total_saldo_favor($E) = coalesce(pruebas.saldo_libros($E, '2.1.04.02'), 0)")" = "t" ] || falla "saldo a favor = su pasivo"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id
        WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] \
  || falla "kardex distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok: $N facturas cobradas una sola vez a la vez; $N vales usados una sola vez a la vez"
