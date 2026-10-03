#!/usr/bin/env bash
# PRUEBA: actualizar a 0.6.0 una base 0.5.0 con datos: todo sigue como antes (cuentas sin saldo negativo, turnos obligatorios, contabilidad visible, sin perfil), un turno que estaba abierto se cierra igual, llega el permiso del asistente sin devolver los que el dueño quitó, el dinero cuadra con los libros y la bitácora está intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_050"
TMP="$(mktemp -d)"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.5.0: migraciones 001 a 024, como las aplicaba migrar.sh.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-2][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 24 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.5.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "24" ] || falla "no quedó en la 024"

# 2) Datos de 0.5.0: dinero (BAC 1,000,000; caja fuerte 300,000), un gasto de 100,000 desde BAC,
#    un turno ABIERTO del cajero con fondo 0 y el dueño le quitó al admin anular gastos.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_dinero();
SELECT public.cambiar_permiso_rol(pruebas.empresa('A'), 'admin', 'gastos.anular', false, 'Solo el dueño anula gastos');
SELECT pruebas.como('admin_a');
SELECT public.registrar_gasto(pruebas.empresa('A'), jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'),
  'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 100000, 'descripcion', 'Luz', 'fecha', '2026-01-15'), gen_random_uuid());
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('T1', (public.abrir_turno(pruebas.empresa('A'), pruebas.id('CAJA001'), 0, gen_random_uuid())->>'turno_id')::uuid);
COMMIT;
SQL

# 3) Actualizar con migrar.sh (025 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Todo como antes.
[ "$(q "SELECT count(*) FROM public.cuenta_dinero WHERE politica_saldo_negativo <> 'no_permitir' OR sobregiro_limite_centavos IS NOT NULL OR inicia_en_cero_en IS NOT NULL")" = "0" ] \
  || falla "las cuentas de antes deben quedar sin saldo negativo"
[ "$(q "SELECT count(*) FROM public.empresa WHERE NOT turnos_obligatorios OR NOT contabilidad_visible OR doble_aprobacion OR perfil IS NOT NULL")" = "0" ] \
  || falla "las empresas de antes deben quedar como estaban"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND permiso = 'arranque.gestionar' AND rol IN ('dueno','admin')")" = "2" ] \
  || falla "no llegó el permiso del asistente"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND rol = 'admin' AND permiso = 'gastos.anular'")" = "0" ] || falla "volvió un permiso quitado"
[ "$(q "SELECT count(*) FROM public.permiso p WHERE NOT EXISTS (SELECT 1 FROM public.rol_permiso r WHERE r.empresa_id = $E AND r.rol = 'dueno' AND r.permiso = p.codigo)")" = "0" ] \
  || falla "el dueño no tiene todos los permisos"

# 5) Después de actualizar: el turno abierto se cierra igual (fondo 0, entra 5,000, cuenta 5,000);
#    sin política de negativo un gasto mayor que el saldo se rechaza; el asistente responde.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('admin_a');
SELECT public.trasladar_dinero(pruebas.empresa('A'), jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'),
  'destino_id', pruebas.id('CAJA1'), 'monto_centavos', 5000), gen_random_uuid());
SELECT pruebas.como('cajero_a');
SELECT pruebas.afirmar((public.cerrar_turno(pruebas.id('T1'), 5000, gen_random_uuid())->>'diferencia_estado') = 'sin_diferencia', 'turno de antes');
SELECT pruebas.como('admin_a');
SELECT pruebas.debe_fallar(format('SELECT public.registrar_gasto(%L, %L, gen_random_uuid())', pruebas.empresa('A'),
  jsonb_build_object('cuenta_dinero_id', pruebas.id('CAJA1'), 'categoria_id', pruebas.id('CAT_PAPEL'), 'monto_centavos', 5001,
  'descripcion', 'Resmas')), 'SALDO_INSUFICIENTE', 'sin negativo como antes');
SELECT pruebas.como('dueno_a');
SELECT pruebas.afirmar((public.estado_arranque(pruebas.empresa('A'))->>'hechos')::int >= 1, 'asistente');
COMMIT;
SQL
[ "$(q "SELECT pruebas.dinero('BANCO') || '/' || pruebas.dinero('FUERTE') || '/' || pruebas.dinero('CAJA1')")" = "900000/295000/5000" ] \
  || falla "saldos: BAC 1,000,000 - 100,000; fuerte 300,000 - 5,000; caja 5,000"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
