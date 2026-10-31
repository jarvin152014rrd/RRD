#!/usr/bin/env bash
# PRUEBA: actualizar a 0.9.1 una base 0.9.0 con datos: los movimientos de dinero de antes quedan sin turno de origen; llegan el permiso cobros.baja_vales (solo el dueño) y la cuenta 4.2.01.04; un cobro en efectivo de un turno ya cerrado se anula desde el turno del admin con referencia al turno original; una devolución pendiente que quedó atascada se destraba; un vale vencido de antes se da de baja; todo cuadra con la bitácora intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_090"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.9.0: migraciones 001 a 037.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 37 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.9.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "37" ] || falla "no quedó en la 037"

# 2) Datos de 0.9.0 (turnos obligatorios): el dueño vende al crédito a CLI2 (4 tornillos = 6,000); el cajero abre T1,
#    pide devolver 2 (pendiente, sin destino), cobra los 6,000 en efectivo, vende hace 5 días 2 tornillos (3,000) y
#    devuelve 1 a un vale de 1 día (vencido); cierra T1 con 9,000.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas(false);
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"vale_dias_vigencia": 1}', 'Vales de un día');
SELECT pruebas.guardar('V1', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 4, 'credito', 'CLI2'), gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('T1', (public.abrir_turno(pruebas.empresa('A'), pruebas.id('CAJA001'), 0, gen_random_uuid())->>'turno_id')::uuid);
SELECT pruebas.guardar('D1', (public.registrar_devolucion(pruebas.id('V1'), '{"lineas":[{"linea":1,"cantidad":2}],"motivo":"Vinieron dañados"}',
  gen_random_uuid())->>'devolucion_id')::uuid);
SELECT pruebas.guardar('C1', (public.registrar_cobro(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI2'),
  'pagos', '[{"forma":"efectivo","monto_centavos":6000}]'::jsonb), gen_random_uuid())->>'cobro_id')::uuid);
SELECT pruebas.guardar('V2', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 2) || jsonb_build_object('fecha', public.hoy_local() - 5),
  gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.como('dueno_a');
SELECT public.registrar_devolucion(pruebas.id('V2'), jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Lo cambia otro día',
  'destino', 'saldo_favor', 'fecha', public.hoy_local() - 5), gen_random_uuid());
SELECT pruebas.como('cajero_a');
SELECT public.cerrar_turno(pruebas.id('T1'), 9000, gen_random_uuid());
COMMIT;
SQL
ANTES="$(q "SELECT count(*) FROM public.dinero_movimiento")"

# 3) Actualizar (038).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Lo de antes, igual; lo nuevo, en su lugar.
[ "$(q "SELECT count(*) FROM public.dinero_movimiento WHERE turno_origen_id IS NULL")" = "$ANTES" ] || falla "movimientos de antes sin turno de origen"
[ "$(q "SELECT string_agg(rol, ',' ORDER BY rol) FROM public.rol_permiso WHERE empresa_id = $E AND permiso = 'cobros.baja_vales'")" = "dueno" ] \
  || falla "cobros.baja_vales solo para el dueño"
[ "$(q "SELECT interno.cuenta_de($E, 'vales_vencidos')")" = "4.2.01.04" ] || falla "cuenta de vales vencidos"

# 5) Después de actualizar.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
-- La devolución atascada (el cliente pagó antes de aprobarla): destino saldo a favor y se aprueba.
SELECT pruebas.como('admin_a');
SELECT public.definir_destino_devolucion(pruebas.id('D1'), '{"destino":"saldo_favor"}', 'El cliente ya pagó');
SELECT pruebas.afirmar((public.resolver_aprobacion((SELECT aprobacion_id FROM public.devolucion WHERE id = pruebas.id('D1')), true, 'Revisado',
  gen_random_uuid())->>'saldo_favor_centavos')::bigint = 3000, 'devolución destrabada: 3,000 a favor');
-- El cobro de T1 (cerrado) se anula desde el turno del admin (fondo 9,000: queda 3,000), con referencia a T1.
SELECT pruebas.guardar('T2', (public.abrir_turno(pruebas.empresa('A'), pruebas.id('CAJA001'), 9000, gen_random_uuid())->>'turno_id')::uuid);
SELECT public.anular_cobro(pruebas.id('C1'), 'Cobro duplicado', gen_random_uuid());
-- El vale vencido de antes se da de baja (dueño).
SELECT pruebas.como('dueno_a');
SELECT pruebas.afirmar((public.dar_baja_vales_vencidos(pruebas.empresa('A'), '{}', 'Vales vencidos de antes', gen_random_uuid())->>'monto_centavos')::bigint = 1500,
  'vale vencido de 1,500 dado de baja');
COMMIT;
SQL
[ "$(q "SELECT (turno_id = pruebas.id('T2') AND turno_origen_id = pruebas.id('T1'))::text FROM public.dinero_movimiento
        WHERE documento_id = pruebas.id('C1') AND operacion = 'anulacion_cobro'")" = "true" ] || falla "anulación desde T2 con referencia a T1"
[ "$(q "SELECT pruebas.dinero('CAJA1')")" = "3000" ] || falla "caja con 3,000"
[ "$(q "SELECT pruebas.saldo_libros($E, '4.2.01.04')")" = "1500" ] || falla "vale a otros ingresos"
[ "$(q "SELECT interno.total_cxc($E) = pruebas.saldo_libros($E, '1.1.02.01')")" = "t" ] || falla "CxC = Clientes"
[ "$(q "SELECT interno.total_saldo_favor($E) = pruebas.saldo_libros($E, '2.1.04.02')")" = "t" ] || falla "saldo a favor = su pasivo"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] || falla "kardex"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
