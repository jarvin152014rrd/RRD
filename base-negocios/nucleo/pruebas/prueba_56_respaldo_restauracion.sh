#!/usr/bin/env bash
# PRUEBA: simulacro real: respaldo CIFRADO (gpg y age) de una base con datos, restauración en una base NUEVA y comparación de saldos, kardex, CxP y bitácora (verificar_bitacora = 0); la base restaurada sigue funcionando; no restaura encima de una base con datos ni con la frase equivocada
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
H="$RAIZ/herramientas"
N1="${BASE}_rest1"; N2="${BASE}_rest2"; N3="${BASE}_rest3"
TMP="$(mktemp -d)"
limpiar() { for b in "$N1" "$N2" "$N3"; do dropdb --if-exists "$b" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
(umask 077; echo "frase-del-simulacro-2026" > "$TMP/frase"; echo "frase-equivocada-123456" > "$TMP/mala")

# 1) Base con datos de todo tipo (empresa A), enero cerrado.
psql -X -q -v ON_ERROR_STOP=1 -d "$BASE" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.como('admin_a');
SELECT public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B1'), '2026-01-02', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 100, 'costo_unitario', 1000),
  jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 20.5, 'costo_unitario', 2000)), gen_random_uuid());
SELECT pruebas.guardar('C1', (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'R-1', '2026-01-05', 'credito', 'P1', 50, 1234.5), gen_random_uuid())->>'compra_id')::uuid);
SELECT pruebas.guardar('PG', (public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('C1'), 20000, '2026-01-06', 'caja', gen_random_uuid())->>'pago_id')::uuid);
SELECT public.anular_pago_proveedor(pruebas.id('PG'), 'Pago repetido', gen_random_uuid(), '2026-01-07');
SELECT public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('C1'), 30000, '2026-01-08', 'banco', gen_random_uuid());
SELECT public.trasladar_inventario(pruebas.empresa('A'), pruebas.id('B1'), pruebas.id('B2'), '2026-01-09',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 30)), gen_random_uuid());
SELECT public.ajustar_inventario(pruebas.empresa('A'), pruebas.id('B1'), '2026-01-10',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad_contada', 19.25)), 'Conteo de enero', gen_random_uuid());
SELECT pruebas.como('dueno_a');
SELECT public.registrar_saldo_inicial_cxp(pruebas.empresa('A'), jsonb_build_object('proveedor_id', pruebas.id('PROV2'),
  'numero_documento', 'R-S', 'fecha_documento', '2025-12-15', 'monto_centavos', 44000, 'fecha', '2026-01-02'), gen_random_uuid());
SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-20', 'Venta', pruebas.lineas('1.1.01.01', '4.1.01.01', 99900), gen_random_uuid());
SELECT public.cerrar_periodo(pruebas.empresa('A'), 2026, 1);
COMMIT;
SQL

# Huella de lo que importa: saldos por cuenta, kardex, saldos de inventario, CxP y bitácora.
huella() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" <<'SQL' | md5sum | cut -d' ' -f1
SELECT empresa_id, codigo, debe_centavos, haber_centavos, saldo_centavos FROM public.v_saldo_cuenta ORDER BY 1, 2;
SELECT id, empresa_id, bodega_id, producto_id, tipo, cantidad, valor_centavos, saldo_cantidad, saldo_valor_centavos, saldo_costo_promedio
  FROM public.inventario_movimiento ORDER BY id;
SELECT bodega_id, producto_id, cantidad, valor_centavos, costo_promedio FROM public.inventario_saldo ORDER BY 1, 2;
SELECT documento_id, total_centavos, pagado_centavos, saldo_centavos FROM public.v_cxp_documento ORDER BY 1;
SELECT empresa_id, count(*), max(secuencia), (array_agg(huella ORDER BY secuencia DESC))[1] FROM public.bitacora GROUP BY 1 ORDER BY 1;
SELECT empresa_id, anio, mes, estado FROM public.periodo ORDER BY 1, 2, 3;
SQL
}
antes="$(huella "$BASE")"

# 2) Respaldo cifrado con gpg (frase en archivo 600).
DIR_RESPALDOS="$TMP/r" RESPALDO_CLAVE_ARCHIVO="$TMP/frase" PGDATABASE="$BASE" bash "$H/respaldar.sh" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "respaldar.sh"; }
gpgf="$(ls "$TMP"/r/*.dump.gpg | head -1)"
[ -s "$gpgf" ] && [ "$(stat -c %a "$gpgf")" = "600" ] || falla "respaldo gpg vacío o sin permisos 600"
grep -a -q "Ferretería" "$gpgf" && falla "el respaldo deja ver datos sin descifrar"

# 3) No restaura encima de una base con datos, ni con la frase equivocada.
if echo "$BASE" | RESPALDO_CLAVE_ARCHIVO="$TMP/frase" PGDATABASE="$BASE" bash "$H/restaurar.sh" "$gpgf" >"$TMP/s.txt" 2>&1; then
  falla "restauró encima de una base con datos"
fi
grep -q "ya tiene datos" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica que la base tiene datos"; }
createdb "$N2"
if echo "$N2" | RESPALDO_CLAVE_ARCHIVO="$TMP/mala" PGDATABASE="$N2" bash "$H/restaurar.sh" "$gpgf" >"$TMP/s.txt" 2>&1; then
  falla "restauró con la frase equivocada"
fi
[ "$(psql -X -tA -d "$N2" -c "SELECT to_regnamespace('interno') IS NULL")" = "t" ] || falla "quedó algo a medias con la frase mala"
if echo "otra" | RESPALDO_CLAVE_ARCHIVO="$TMP/frase" PGDATABASE="$N2" bash "$H/restaurar.sh" "$gpgf" >"$TMP/s.txt" 2>&1; then
  falla "restauró sin la confirmación correcta"
fi

# 4) Restauración real en una base NUEVA y comparación.
createdb "$N1"
echo "$N1" | RESPALDO_CLAVE_ARCHIVO="$TMP/frase" PGDATABASE="$N1" bash "$H/restaurar.sh" "$gpgf" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "no restauró"; }
grep -q "verificar_bitacora(): 0 problemas" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "la bitácora restaurada no verifica"; }
[ "$(huella "$N1")" = "$antes" ] || falla "lo restaurado no es igual al original (saldos, kardex, CxP o bitácora)"

# 5) La base restaurada sigue funcionando: numera después del último, la cadena sigue y enero sigue cerrado.
r="$(psql -X -q -tA -v ON_ERROR_STOP=1 -d "$N1" <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT set_config('pruebas.max', (SELECT max(numero) FROM public.asiento WHERE empresa_id = pruebas.empresa('A'))::text, true);
SELECT (public.registrar_asiento(pruebas.empresa('A'), public.hoy_local(pruebas.empresa('A')), 'Primera venta tras restaurar',
        pruebas.lineas('1.1.01.01', '4.1.01.01', 100), gen_random_uuid())->>'numero')::bigint
     = current_setting('pruebas.max')::bigint + 1;
COMMIT;
SQL
)"
echo "$r" | tail -1 | grep -qx "t" || falla "no registra bien en la base restaurada ($r)"
[ "$(psql -X -tA -d "$N1" -c "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la cadena no sigue tras restaurar"
if psql -X -q -v ON_ERROR_STOP=1 -d "$N1" -c "BEGIN; SELECT pruebas.como('dueno_a'); SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-25', 'x', pruebas.lineas('1.1.01.01', '4.1.01.01', 1), gen_random_uuid()); COMMIT;" >/dev/null 2>&1; then
  falla "enero dejó de estar cerrado"
fi

# 6) Con age: cifra con la llave PÚBLICA (no pide nada) y solo abre con la privada.
age-keygen -o "$TMP/llave.txt" 2>/dev/null
publica="$(grep -o 'age1[0-9a-z]*' "$TMP/llave.txt" | head -1)"
DIR_RESPALDOS="$TMP/a" RESPALDO_AGE_DESTINATARIO="$publica" PGDATABASE="$BASE" bash "$H/respaldar.sh" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "respaldo con age"; }
agef="$(ls "$TMP"/a/*.dump.age | head -1)"
[ -s "$agef" ] || falla "no hay respaldo .age"
createdb "$N3"
echo "$N3" | RESPALDO_AGE_IDENTIDAD="$TMP/llave.txt" PGDATABASE="$N3" bash "$H/restaurar.sh" "$agef" >"$TMP/s.txt" 2>&1 \
  || { cat "$TMP/s.txt"; falla "no restauró el .age"; }
[ "$(huella "$N3")" = "$antes" ] || falla "lo restaurado con age no es igual al original"
echo "ok: gpg y age restaurados idénticos; bitácora intacta"
