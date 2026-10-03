#!/usr/bin/env bash
# PRUEBA: actualizar a 0.7.0 una base 0.6.0 con datos: los productos quedan como bienes con su mismo impuesto (ahora de la tabla), cada empresa recibe sus impuestos, las compras de antes se anulan igual, llegan los permisos de ventas sin devolver los que el dueño quitó, la aprobación de gastos de antes se resuelve igual (una aprobación) y se puede activar ventas y vender; el dinero y el inventario cuadran y la bitácora está intacta
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_060"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }
E="pruebas.empresa('A')"

# 1) Base en 0.6.0: migraciones 001 a 025.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-9][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 25 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.6.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "25" ] || falla "no quedó en la 025"

# 2) Datos de 0.6.0: inventario, dinero, una compra al crédito (P1 10 x L 10.00 + ISV 15 %), un gasto del
#    admin pendiente de aprobación y el dueño le quitó al admin "gastos.anular".
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.preparar_dinero();
SELECT pruebas.guardar('C1', (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'F-OLD-1', '2026-01-05', 'credito', 'P1', 10, 1000), gen_random_uuid())->>'compra_id')::uuid);
SELECT public.cambiar_permiso_rol(pruebas.empresa('A'), 'admin', 'gastos.anular', false, 'Solo el dueño anula gastos');
SELECT public.configurar_tope_rol(pruebas.empresa('A'), 'admin', 'gasto', 0, 500000, 'Todo gasto del admin con aprobación');
SELECT pruebas.como('admin_a');
SELECT pruebas.guardar('G1', (public.registrar_gasto(pruebas.empresa('A'), jsonb_build_object('cuenta_dinero_id', pruebas.id('BANCO'),
  'categoria_id', pruebas.id('CAT_LUZ'), 'monto_centavos', 100000, 'descripcion', 'Luz', 'fecha', '2026-01-15'), gen_random_uuid())->>'aprobacion_id')::uuid);
COMMIT;
SQL

# 3) Actualizar (026 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Todo como antes.
[ "$(q "SELECT count(*) FROM public.producto WHERE tipo <> 'bien'")" = "0" ] || falla "los productos de antes son bienes"
[ "$(q "SELECT string_agg(tipo_impuesto, ',' ORDER BY codigo) FROM public.producto WHERE empresa_id = $E")" = "EXENTO,ISV18,ISV15" ] \
  || falla "mismo impuesto que antes"
[ "$(q "SELECT count(*) FROM public.impuesto WHERE empresa_id IN (SELECT id FROM public.empresa)")" = "8" ] || falla "4 impuestos por empresa"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND rol = 'admin' AND permiso = 'gastos.anular'")" = "0" ] || falla "volvió un permiso quitado"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND permiso LIKE 'ventas.%'")" = "28" ] || falla "permisos de ventas: dueño 10, admin 9, cajero 5, vendedor 3, contador 1 (0.9.0: saldo_inicial y devolver)"
[ "$(q "SELECT count(*) FROM public.permiso p WHERE NOT EXISTS (SELECT 1 FROM public.rol_permiso r WHERE r.empresa_id = $E AND r.rol = 'dueno' AND r.permiso = p.codigo)")" = "0" ] \
  || falla "el dueño no tiene todos los permisos"
[ "$(q "SELECT aprobaciones_requeridas FROM public.aprobacion WHERE id = pruebas.id('G1')")" = "1" ] || falla "aprobación de antes: una sola"
[ "$(q "SELECT documento_venta_modo || '/' || credito_politica || '/' || permite_servicios FROM public.empresa WHERE id = $E")" = "solo_factura/segun_limite/true" ] \
  || falla "valores iniciales de ventas"

# 5) Después de actualizar: se aprueba el gasto viejo, se anula la compra vieja, se activa ventas y se vende (ticket: sin régimen fiscal).
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('dueno_a');
SELECT pruebas.afirmar((public.resolver_aprobacion(pruebas.id('G1'), true, NULL, gen_random_uuid())->>'estado') = 'aplicado', 'gasto viejo aprobado');
SELECT pruebas.afirmar((public.anular_compra(pruebas.id('C1'), 'Prueba de anulación vieja', gen_random_uuid())->>'duplicado')::boolean = false, 'compra vieja anulada');
SELECT public.registrar_compra(pruebas.empresa('A'), pruebas.compra('PROV1', 'B1', 'F-NEW-1', '2026-01-06', 'credito', 'P1', 10, 1000), gen_random_uuid());
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'ventas');
SELECT pruebas.como('dueno_a');
SELECT public.configurar_empresa(pruebas.empresa('A'), '{"turnos_obligatorios": false}', 'Sin turnos');
SELECT pruebas.afirmar((public.registrar_venta(pruebas.empresa('A'), pruebas.venta('P1', 2), gen_random_uuid())->>'numero_documento') = 'T-001-001-00000001', 'venta con ticket');
COMMIT;
SQL
[ "$(q "SELECT pruebas.dinero('CAJA1') || '/' || pruebas.dinero('BANCO')")" = "3000/900000" ] || falla "caja 3,000 (2 x 1,500); BAC 1,000,000 - 100,000"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = $E) = pruebas.saldo_libros($E, '1.1.03.01')")" = "t" ] || falla "kardex"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
