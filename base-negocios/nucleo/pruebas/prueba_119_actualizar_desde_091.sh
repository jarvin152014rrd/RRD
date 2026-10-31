#!/usr/bin/env bash
# PRUEBA: actualizar a 0.9.2 una base 0.9.1 con datos: las ventas de antes quedan sin porcentaje de comisión guardado y siguen la regla anterior (el vigente en su fecha al cobrarse); las nuevas guardan el suyo al emitirse; un apartado de un cajero dado de baja que estaba trabado se completa a su nombre; todo cuadra con la bitácora intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_091"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.9.1: migraciones 001 a 038.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 38 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.9.1')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "38" ] || falla "no quedó en la 038"

# 2) Datos de 0.9.1 (sin turnos obligatorios): comisiones al 10 % para el vendedor y para el cajero; V1 al crédito a CLI1
#    a nombre del vendedor (1 tornillo = 1,500); el cajero aparta 2 tornillos (3,000) a CLI1 con 1,000 y lo dan de baja.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas(false);
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Sin turnos');
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'comisiones'), (pruebas.empresa('A'), 'apartados');
SELECT pruebas.como('dueno_a');
SELECT public.configurar_comisiones(pruebas.empresa('A'), '{"activas": true, "base": "precio"}', 'Comisión sobre el precio');
SELECT public.fijar_porcentaje_comision(pruebas.empresa('A'), pruebas.usuario('vendedor_a'), 10, NULL, 'Comisión inicial');
SELECT public.fijar_porcentaje_comision(pruebas.empresa('A'), pruebas.usuario('cajero_a'), 10, NULL, 'Comisión inicial');
SELECT pruebas.guardar('V1', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 1, 'credito', 'CLI1')
  || jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('A1', (public.crear_apartado(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI1'),
  'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 2)),
  'pagos', '[{"forma":"efectivo","monto_centavos":1000}]'::jsonb), gen_random_uuid())->>'apartado_id')::uuid);
SELECT pruebas.como('superusuario');
UPDATE public.usuario_empresa SET activo = false WHERE empresa_id = pruebas.empresa('A') AND user_id = pruebas.usuario('cajero_a');
COMMIT;
SQL

# 3) Actualizar (039).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"
[ "$(q "SELECT count(*) FROM public.venta WHERE comision_porcentaje IS NOT NULL")" = "0" ] || falla "las ventas de antes quedan sin porcentaje guardado"

# 4) Después de actualizar: V2 al crédito (guarda el 10 %); el dueño sube al vendedor a 20 % desde hoy; se cobran las dos
#    (3,000): V1 (de antes) toma la regla anterior = 20 % de 1,304 = round(260.8) = 261; V2 conserva el 10 % = 130.
#    El apartado trabado del cajero dado de baja se completa (2,000) a su nombre: 10 % de 2,609 = 261.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT pruebas.guardar('V2', (public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 1, 'credito', 'CLI1')
  || jsonb_build_object('vendedor_id', pruebas.usuario('vendedor_a')), gen_random_uuid())->>'venta_id')::uuid);
SELECT public.fijar_porcentaje_comision(pruebas.empresa('A'), pruebas.usuario('vendedor_a'), 20, NULL, 'Sube la comisión');
SELECT public.registrar_cobro(pruebas.empresa('A'), jsonb_build_object('cliente_id', pruebas.id('CLI1'),
  'pagos', '[{"forma":"efectivo","monto_centavos":3000}]'::jsonb), gen_random_uuid());
SELECT pruebas.guardar('V3', (public.completar_apartado(pruebas.id('A1'), '{"pagos":[{"forma":"efectivo","monto_centavos":2000}]}',
  gen_random_uuid())->>'venta_id')::uuid);
COMMIT;
SQL
[ "$(q "SELECT comision_porcentaje FROM public.venta WHERE id = pruebas.id('V2')")" = "10.00" ] || falla "V2 guarda el 10 %"
[ "$(q "SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = pruebas.id('V1')")" = "261" ] || falla "V1 (de antes): regla anterior, 261"
[ "$(q "SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = pruebas.id('V2')")" = "130" ] || falla "V2: 10 % guardado, 130"
[ "$(q "SELECT (vendedor_id = pruebas.usuario('cajero_a'))::text FROM public.venta WHERE id = pruebas.id('V3')")" = "true" ] || falla "apartado a nombre del cajero"
[ "$(q "SELECT sum(monto_centavos) FROM public.comision_movimiento WHERE venta_id = pruebas.id('V3')")" = "261" ] || falla "comisión del apartado, 261"
[ "$(q "SELECT interno.total_comisiones_por_pagar($E) = pruebas.saldo_libros($E, '2.1.03.04')")" = "t" ] || falla "comisiones = su cuenta"
[ "$(q "SELECT interno.total_cxc($E) = pruebas.saldo_libros($E, '1.1.02.01')")" = "t" ] || falla "CxC = Clientes"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
