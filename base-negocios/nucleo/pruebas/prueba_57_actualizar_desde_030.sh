#!/usr/bin/env bash
# PRUEBA: actualizar a 0.4.0 una base con datos de 0.3.0: los datos viejos siguen funcionando (precios sin ISV, carga inicial contra 3.1.01.01 que se anula contra esa misma cuenta, pagos que se anulan), permisos quitados por el dueño no vuelven y si el código 3.3.01.03 ya era del cliente se usa el siguiente libre
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_030"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }

# 1) Base en 0.3.0: migraciones 001 a 016, como las aplicaba migrar.sh.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[01][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 16 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.3.0')" >/dev/null
done
[ "$(q "SELECT max(numero) FROM interno._migraciones")" = "16" ] || falla "no quedó en la 016"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null

# 2) Datos y decisiones de 0.3.0.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.como('dueno_a');
-- El cliente ya usaba 3.3.01.03 para otra cosa.
SELECT public.crear_subcuenta(pruebas.empresa('A'), '3.3.01', '3.3.01.03', 'Revaluaciones del cliente');
-- El dueño le quitó al admin ver la contabilidad.
SELECT public.cambiar_permiso_rol(pruebas.empresa('A'), 'admin', 'contabilidad.ver', false, 'El admin no ve los libros');
SELECT pruebas.como('admin_a');
-- Carga inicial vieja (contra 3.1.01.01): P3 2 x 30,000 = 60,000 en B2 (sin movimientos después).
SELECT pruebas.guardar('CV', (public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B2'), '2026-01-02',
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P3'), 'cantidad', 2, 'costo_unitario', 30000)), gen_random_uuid())->>'documento_id')::uuid);
-- Compra al crédito 10 x 1000 = 10,000 + ISV 1,500 = 11,500 y un pago de 5,000.
SELECT pruebas.guardar('CC', (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'V-1', '2026-01-05', 'credito', 'P1', 10, 1000), gen_random_uuid())->>'compra_id')::uuid);
SELECT pruebas.guardar('PV', (public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('CC'), 5000, '2026-01-06', 'caja', gen_random_uuid())->>'pago_id')::uuid);
COMMIT;
SQL
[ "$(q "SELECT pruebas.saldo_libros(pruebas.empresa('A'), '3.1.01.01')")" = "60000" ] || falla "la carga de 0.3.0 no fue contra 3.1.01.01"

# 3) Actualizar con migrar.sh (017 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
ULTIMA="$(ls "$RAIZ"/nucleo/sql/migraciones/[0-9][0-9][0-9]_*.sql | tail -1 | xargs basename | cut -c1-3)"
[ "$(q "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")/$((10#$ULTIMA))" ] || falla "versión final"

# 4) Lo viejo se respeta.
[ "$(q "SELECT nombre FROM public.cuenta WHERE empresa_id = pruebas.empresa('A') AND codigo = '3.3.01.03'")" = "Revaluaciones del cliente" ] \
  || falla "se tocó la subcuenta del cliente"
[ "$(q "SELECT nombre FROM public.cuenta WHERE empresa_id = pruebas.empresa('A') AND codigo = '3.3.01.04'")" = "Saldos de apertura" ] \
  || falla "no creó Saldos de apertura en el siguiente código libre"
[ "$(q "SELECT nombre FROM public.cuenta WHERE empresa_id = pruebas.empresa('B') AND codigo = '3.3.01.03'")" = "Saldos de apertura" ] \
  || falla "la empresa B debía tener 3.3.01.03"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = pruebas.empresa('A') AND rol = 'admin' AND permiso = 'contabilidad.ver'")" = "0" ] \
  || falla "volvió un permiso que el dueño había quitado"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = pruebas.empresa('A') AND rol = 'admin' AND permiso IN ('terceros.ver', 'inventario.anular')")" = "2" ] \
  || falla "el admin no recibió los permisos nuevos"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = pruebas.empresa('A') AND rol = 'contador'")" = "10" ] || falla "faltan permisos del contador"
[ "$(q "SELECT count(*) FROM public.permiso p WHERE NOT EXISTS (SELECT 1 FROM public.rol_permiso r WHERE r.empresa_id = pruebas.empresa('A') AND r.rol = 'dueno' AND r.permiso = p.codigo)")" = "0" ] \
  || falla "el dueño no tiene todos los permisos"
# Precios de antes: SIN ISV (P1 1,500 -> con ISV 1,500 + 225 = 1,725). El defecto nuevo de la empresa: con ISV.
[ "$(q "SELECT precio_incluye_isv::text || '/' || precio_venta_centavos || '/' || precio_con_isv_centavos FROM public.v_producto WHERE producto_id = pruebas.id('P1')")" = "false/1500/1725" ] \
  || falla "el precio viejo cambió de sentido"
[ "$(q "SELECT precio_incluye_isv_defecto FROM public.empresa WHERE id = pruebas.empresa('A')")" = "t" ] || falla "defecto de la empresa"

# 5) Lo viejo sigue funcionando con las funciones nuevas.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.como('admin_a');
-- La carga de 0.3.0 se anula contra la MISMA cuenta que usó (3.1.01.01).
SELECT public.anular_documento_inventario(pruebas.id('CV'), 'Carga duplicada', gen_random_uuid());
-- Una carga nueva va contra Saldos de apertura (3.3.01.04 en esta empresa): P2 5 x 2000 = 10,000.
SELECT public.cargar_saldo_inicial(pruebas.empresa('A'), pruebas.id('B2'), public.hoy_local(pruebas.empresa('A')),
  jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 5, 'costo_unitario', 2000)), gen_random_uuid());
-- El pago de 0.3.0 se anula y entonces la compra también.
SELECT public.anular_pago_proveedor(pruebas.id('PV'), 'Pago mal hecho', gen_random_uuid());
SELECT public.anular_compra(pruebas.id('CC'), 'Factura mal hecha', gen_random_uuid());
COMMIT;
SQL
[ "$(q "SELECT pruebas.saldo_libros(pruebas.empresa('A'), '3.1.01.01')")" = "0" ] || falla "la anulación de la carga vieja no volvió a 3.1.01.01"
[ "$(q "SELECT pruebas.saldo_libros(pruebas.empresa('A'), '3.3.01.04')")" = "10000" ] || falla "la carga nueva no fue a 3.3.01.04"
[ "$(q "SELECT pruebas.saldo_libros(pruebas.empresa('A'), '3.3.01.03')")" = "0" ] || falla "se usó la subcuenta del cliente"
[ "$(q "SELECT pruebas.saldo_libros(pruebas.empresa('A'), '2.1.01.01') || '/' || pruebas.saldo_libros(pruebas.empresa('A'), '1.1.01.01')")" = "0/0" ] \
  || falla "CxP o caja no volvieron a 0"
[ "$(q "SELECT (SELECT sum(valor_centavos) FROM public.inventario_saldo WHERE empresa_id = pruebas.empresa('A')) = pruebas.saldo_libros(pruebas.empresa('A'), '1.1.03.01')")" = "t" ] \
  || falla "kardex distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
