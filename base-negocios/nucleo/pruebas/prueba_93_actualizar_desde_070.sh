#!/usr/bin/env bash
# PRUEBA: actualizar a 0.8.0 una base 0.7.0 con datos: las ventas de antes (promoción + descuento manual) quedan igual, una venta pendiente se aprueba igual, una cotización vigente se convierte con sus precios cotizados, los módulos de antes quedan como "estuvieron activos" (y una combinación vieja sin su dependencia no rompe la actualización), llegan los permisos y límites nuevos (sin límites = como antes), el vendedor sigue sin cobrar y todo cuadra con la bitácora intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_070"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.7.0: migraciones 001 a 029.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 29 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.7.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "29" ] || falla "no quedó en la 029"

# 2) Datos de 0.7.0: ventas con promoción + descuento manual (se permitía), una venta pendiente,
#    una cotización vigente con promoción + descuento, y en la empresa B "compras" sin "inventario".
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_ventas(false);
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Sin turnos');
SELECT pruebas.guardar('CAT', (public.crear_categoria(pruebas.empresa('A'), 'Ferretería')->>'categoria_id')::uuid);
SELECT public.editar_producto(pruebas.empresa('A'), pruebas.id('P1'), jsonb_build_object('categoria_id', pruebas.id('CAT')));
SELECT public.crear_promocion(pruebas.empresa('A'), jsonb_build_object('nombre', 'Diez', 'categoria_id', pruebas.id('CAT'), 'tipo', 'porcentaje',
  'porcentaje', 10, 'fecha_inicio', to_char(public.hoy_local(pruebas.empresa('A')) - 1, 'YYYY-MM-DD'),
  'fecha_fin', to_char(public.hoy_local(pruebas.empresa('A')) + 1, 'YYYY-MM-DD')));
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('V1', (public.registrar_venta(pruebas.empresa('A'), jsonb_build_object('lineas', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'descuento_porcentaje', 5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb),
  gen_random_uuid())->>'venta_id')::uuid);
SELECT pruebas.guardar('V2', (public.registrar_venta(pruebas.empresa('A'), jsonb_build_object('lineas', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 1, 'descuento_porcentaje', 15)), 'pagos', '[{"forma":"efectivo"}]'::jsonb),
  gen_random_uuid())->>'aprobacion_id')::uuid);
SELECT pruebas.guardar('COT', (public.crear_cotizacion(pruebas.empresa('A'), jsonb_build_object('lineas', jsonb_build_array(
  jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 10, 'descuento_porcentaje', 5))), gen_random_uuid())->>'cotizacion_id')::uuid);
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('B'), 'compras');
COMMIT;
SQL
[ "$(q "SELECT total_centavos FROM public.venta WHERE id = pruebas.id('V1')")" = "12825" ] || falla "venta vieja con dos descuentos"

# 3) Actualizar (030 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Lo de antes, igual.
[ "$(q "SELECT total_centavos || '/' || descuento_manual_centavos FROM public.venta WHERE id = pruebas.id('V1')")" = "12825/587" ] || falla "venta vieja intacta"
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE NOT estuvo_activo")" = "0" ] || falla "los módulos de antes cuentan como usados"
[ "$(q "SELECT count(*) FROM public.modulo_dependencia")" = "10" ] || falla "dependencias (0.11.0: 10 con conciliacion)"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND permiso = 'proveedor.solicitar'")" = "2" ] || falla "permiso nuevo: dueño y admin"
[ "$(q "SELECT count(*) FROM public.limite_contrato")" = "0" ] || falla "sin límites: como antes"
[ "$(q "SELECT bool_or(vendedor_cobra) FROM public.empresa")" = "f" ] || falla "el vendedor sigue sin cobrar"

# 5) Después de actualizar: se aprueba la venta pendiente, la cotización se convierte con sus precios,
#    las ventas nuevas siguen la regla nueva, y la empresa B (compras sin inventario, de antes) puede seguir cambiando.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('admin_a');
SELECT pruebas.afirmar((public.resolver_aprobacion(pruebas.id('V2'), true, 'Aprobada después de actualizar', gen_random_uuid())->>'estado') = 'emitida', 'pendiente aprobada');
SELECT pruebas.como('cajero_a');
SELECT pruebas.afirmar((public.convertir_cotizacion_a_venta(pruebas.id('COT'), '{"pagos":[{"forma":"efectivo"}]}', gen_random_uuid())->>'total_centavos')::bigint = 12825,
  'cotización vieja con sus precios cotizados');
SELECT pruebas.debe_fallar(format('SELECT public.registrar_venta(%L, %L, gen_random_uuid())', pruebas.empresa('A'), jsonb_build_object('lineas',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1, 'descuento_porcentaje', 5)), 'pagos', '[{"forma":"efectivo"}]'::jsonb)),
  'DESCUENTO_DOBLE', 'venta nueva: regla nueva');
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('B'), 'dinero');
UPDATE public.modulo_activo SET activo = false WHERE empresa_id = pruebas.empresa('B') AND modulo = 'compras';
COMMIT;
SQL
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] || falla "kardex"
[ "$(q "SELECT (SELECT sum(impuesto_centavos) FROM public.venta WHERE empresa_id = $E AND estado = 'emitida') = pruebas.saldo_libros($E, '2.1.02.01')")" = "t" ] || falla "ISV"
[ "$(q "SELECT interno.total_cxp($E) = pruebas.saldo_libros($E, '2.1.01.01') AND interno.total_cxc($E) = coalesce(pruebas.saldo_libros($E, '1.1.02.01'), 0)")" = "t" ] || falla "CxP y CxC"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
