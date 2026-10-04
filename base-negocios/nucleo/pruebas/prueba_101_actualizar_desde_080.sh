#!/usr/bin/env bash
# PRUEBA: actualizar a 0.9.0 una base 0.8.0 con datos: las ventas al crédito de antes aparecen en CxC (cobrado 0) y se cobran, condonan y devuelven; una venta pendiente de antes se aprueba igual; una venta de antes se anula igual; llegan las cuentas nuevas (si el código ya era del cliente se usa el siguiente libre), los permisos nuevos y los módulos apartados y comisiones (apagados); el asistente marca clientes con saldos iniciales; todo cuadra con la bitácora intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_080"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.8.0: migraciones 001 a 032.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 32 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.8.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "32" ] || falla "no quedó en la 032"

# 2) Datos de 0.8.0: dos ventas al crédito (una se anulará), una pendiente de aprobación, una de contado,
#    y el cliente ya tenía su propia cuenta 2.1.04.02.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas(false);
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Sin turnos');
SELECT public.crear_subcuenta(pruebas.empresa('A'), '2.1.04', '2.1.04.02', 'Depósitos de clientes');
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('V1', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 10, 'credito', 'CLI1'), gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.guardar('V2', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P3', 1, 'credito', 'CLI1'), gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.guardar('V3', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 2, 'efectivo'), gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.guardar('AP', (public.registrar_venta(pruebas.empresa('A'), jsonb_build_object('lineas', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2, 'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb),
  gen_random_uuid())->>'aprobacion_id')::uuid);
COMMIT;
SQL

# 3) Actualizar (033 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Lo de antes, igual; lo nuevo, en su lugar.
[ "$(q "SELECT count(*) || '/' || sum(cobrado_centavos) || '/' || sum(saldo_centavos) FROM public.v_cxc_documento WHERE empresa_id = $E")" = "2/0/60000" ] \
  || falla "las ventas al crédito de antes en CxC"
[ "$(q "SELECT interno.cuenta_de($E, 'saldo_favor')")" = "2.1.04.03" ] || falla "2.1.04.02 era del cliente: se usa la siguiente"
[ "$(q "SELECT count(*) FROM public.cuenta WHERE empresa_id = $E AND codigo IN ('2.1.04.03', '6.1.02.12', '4.1.01.04', '2.1.03.04', '6.1.01.04')")" = "5" ] \
  || falla "cuentas nuevas"
[ "$(q "SELECT count(*) FROM public.modulo_dependencia")" = "9" ] || falla "dependencias (0.10.0: 9 con fondos)"
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE modulo IN ('apartados', 'comisiones')")" = "0" ] || falla "módulos nuevos apagados"
[ "$(q "SELECT string_agg(rol || ':' || permiso, ',' ORDER BY rol, permiso) FROM public.rol_permiso WHERE empresa_id = $E
        AND permiso IN ('cobros.anular', 'ventas.devolver', 'ventas.saldo_inicial', 'comisiones.ver')")" \
  = "admin:cobros.anular,admin:comisiones.ver,admin:ventas.devolver,cajero:ventas.devolver,contador:comisiones.ver,dueno:cobros.anular,dueno:comisiones.ver,dueno:ventas.devolver,dueno:ventas.saldo_inicial" ] \
  || falla "permisos nuevos"

# 5) Después de actualizar: cobrar, condonar, devolver y anular ventas de antes; aprobar la pendiente; saldo inicial de cliente.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('cajero_a');
SELECT pruebas.afirmar((public.registrar_cobro(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI1'), 'excedente', 'saldo_favor',
  'aplicar', jsonb_build_array(jsonb_build_object('venta_id', pruebas.id('V1'), 'monto_centavos', 15000)),
  'pagos', '[{"forma":"efectivo","monto_centavos":20000}]'::jsonb), gen_random_uuid())->>'excedente_centavos')::bigint = 5000, 'cobro: V1 15,000 + 5,000 a favor');
SELECT pruebas.como('admin_a');
SELECT pruebas.afirmar((public.resolver_aprobacion(pruebas.id('AP'), true, 'Aprobada después de actualizar', gen_random_uuid())->>'estado') = 'emitida', 'pendiente aprobada');
SELECT pruebas.como('dueno_a');
SELECT public.registrar_devolucion(pruebas.id('V2'), '{"lineas":[{"linea":1,"cantidad":1}],"motivo":"Devuelto tras actualizar"}', gen_random_uuid());
SELECT public.registrar_devolucion(pruebas.id('V3'), jsonb_build_object('lineas', '[{"linea":1,"cantidad":1}]'::jsonb, 'motivo', 'Devuelto tras actualizar',
  'destino', 'dinero', 'cuenta_dinero_id', pruebas.id('CAJA1')), gen_random_uuid());
SELECT public.registrar_saldo_inicial_cxc(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI2'), 'numero_documento', 'F-9',
  'fecha_documento', '2025-12-20', 'monto_centavos', 4321), gen_random_uuid());
SELECT pruebas.afirmar(public.estado_arranque(pruebas.empresa('A'))->'pasos'->4->>'detalle' LIKE '1 saldo(s) inicial(es)%', 'asistente: saldos de clientes');
COMMIT;
SQL
[ "$(q "SELECT interno.saldo_documento_cxc(pruebas.id('V2')) || '/' || interno.total_cxc($E)")" = "0/4321" ] || falla "V2 rebajada por la nota de crédito"
[ "$(q "SELECT interno.total_cxc($E) = pruebas.saldo_libros($E, '1.1.02.01')")" = "t" ] || falla "CxC = Clientes"
[ "$(q "SELECT interno.total_saldo_favor($E) = pruebas.saldo_libros($E, '2.1.04.03') AND interno.total_saldo_favor($E) = 5000")" = "t" ] || falla "saldo a favor en 2.1.04.03"
[ "$(q "SELECT (SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = $E AND estado = 'emitida')
          - (SELECT sum(impuesto_centavos) FROM public.devolucion WHERE empresa_id = $E AND estado = 'aplicada') = pruebas.saldo_libros($E, '2.1.02.01')")" = "t" ] \
  || falla "ISV = ventas - notas de crédito"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] || falla "kardex"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
