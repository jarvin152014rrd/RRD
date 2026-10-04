#!/usr/bin/env bash
# PRUEBA: actualizar a 0.10.0 una base 0.9.2 con datos de enero: llegan las cuentas (2.1.01.03 dividendos) y los permisos de fondos (al dueño, admin y contador solo ver), el módulo fondos queda apagado; enero se cierra con su foto y las cifras de antes (utilidad cobrada 35,159; activo 1,798,500); al encender fondos se reparte la utilidad cobrada; todo cuadra y la bitácora está intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_092"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.9.2: migraciones 001 a 039 y datos de enero (pruebas.preparar_enero).
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 39 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.9.2')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "39" ] || falla "no quedó en la 039"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -c "BEGIN; SELECT pruebas.preparar_enero(); COMMIT;" >/dev/null

# 2) Actualizar (040-042).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"
[ "$(q "SELECT count(*) FROM public.cuenta WHERE empresa_id = $E AND codigo = '2.1.01.03' AND nombre = 'Dividendos por pagar a socios'")" = "1" ] || falla "cuenta de dividendos"
[ "$(q "SELECT string_agg(rol || ':' || permiso, ',' ORDER BY rol, permiso) FROM public.rol_permiso WHERE empresa_id = $E AND permiso LIKE 'fondos.%' AND rol <> 'dueno'")" \
  = "admin:fondos.ver,contador:fondos.ver" ] || falla "permisos de fondos"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND permiso LIKE 'fondos.%' AND rol = 'dueno'")" = "6" ] || falla "permisos del dueño"
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE modulo = 'fondos'")" = "0" ] || falla "fondos apagado"

# 3) Cerrar enero (cifras de prueba_120) y repartir con fondos encendido.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT pruebas.guardar('CIERRE', (public.cerrar_mes(pruebas.empresa('A'), 2026, 1)->>'cierre_id')::uuid);
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'fondos');
SELECT pruebas.como('dueno_a');
SELECT pruebas.guardar('F1', (public.crear_fondo(pruebas.empresa('A'), '{"nombre": "Reinversión", "tipo": "reinversion"}', 'Fondo inicial')->>'fondo_id')::uuid);
SELECT public.distribuir_utilidades(pruebas.empresa('A'), 2026, 1, jsonb_build_object('fecha', '2026-02-10',
  'fondos', jsonb_build_array(jsonb_build_object('fondo_id', pruebas.id('F1'), 'porcentaje', 100))), 'Todo a reinversión', gen_random_uuid());
COMMIT;
SQL
[ "$(q "SELECT resumen->>'utilidad_cobrada_centavos' || '/' || (resumen->>'total_activo_centavos') FROM public.cierre WHERE id = pruebas.id('CIERRE')")" \
  = "35159/1798500" ] || falla "cifras de enero en la foto"
[ "$(q "SELECT pruebas.saldo_libros($E, '3.2.02.01') || '/' || pruebas.saldo_libros($E, '3.3.01.02')")" = "35159/-35159" ] || falla "reparto en los libros"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT sum(debe_centavos) = sum(haber_centavos) FROM public.asiento_linea")" = "t" ] || falla "debe = haber"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
