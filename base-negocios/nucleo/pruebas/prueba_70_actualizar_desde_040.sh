#!/usr/bin/env bash
# PRUEBA: actualizar a 0.5.0 una base 0.4.0 con datos: si el cliente ya usaba 1.1.02.04 o 6.1.02.11, las cuentas nuevas de caja van al siguiente código libre y el módulo controla ESA cuenta (no la del cliente); los permisos nuevos llegan sin devolver los que el dueño quitó; compras y pagos de antes siguen igual; el dinero cuadra con los libros
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
VIEJA="${BASE}_040"
TMP="$(mktemp -d)"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" -c "$1"; }

# 1) Base en 0.4.0: migraciones 001 a 020, como las aplicaba migrar.sh.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/simular_supabase.sql" >/dev/null
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-2][0-9]_*.sql; do
  b="$(basename "$f" .sql)"; n=$((10#${b%%_*}))
  [ "$n" -le 20 ] || continue
  psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -1 -f "$f" \
    -c "INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo) VALUES ($n, '$b', '$(sha256sum "$f" | cut -d' ' -f1)', '0.4.0')" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null

# 2) Datos de 0.4.0: subcuentas propias en 1.1.02.04 y 6.1.02.11 (con saldo), compra al
#    crédito pagada en parte desde "caja", y el dueño le quitó al admin anular compras.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_inventario();
SELECT pruebas.como('dueno_a');
SELECT public.crear_subcuenta(pruebas.empresa('A'), '1.1.02', '1.1.02.04', 'Préstamos a socios');
SELECT public.crear_subcuenta(pruebas.empresa('A'), '6.1.02', '6.1.02.11', 'Vigilancia');
SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-03', 'Préstamo a un socio', pruebas.lineas('1.1.02.04', '1.1.01.01', 4000), gen_random_uuid());
SELECT public.cambiar_permiso_rol(pruebas.empresa('A'), 'admin', 'compras.anular', false, 'Solo el dueño anula compras');
SELECT pruebas.como('admin_a');
SELECT pruebas.guardar('CC', (public.registrar_compra(pruebas.empresa('A'),
  pruebas.compra('PROV1', 'B1', 'V-1', '2026-01-05', 'credito', 'P1', 10, 1000), gen_random_uuid())->>'compra_id')::uuid);
SELECT public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('CC'), 5000, '2026-01-06', 'caja', gen_random_uuid());
COMMIT;
SQL

# 3) Actualizar con migrar.sh (021 en adelante).
PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || falla "no se pudo actualizar"
[ "$(q "SELECT version_nucleo FROM public.version_esquema")" = "$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")" ] || falla "versión final"

# 4) Cuentas nuevas: al siguiente código libre; las del cliente intactas.
E="pruebas.empresa('A')"
[ "$(q "SELECT string_agg(codigo || '=' || nombre, '; ' ORDER BY codigo) FROM public.cuenta WHERE empresa_id = $E AND codigo IN ('1.1.02.04','1.1.02.05','1.1.02.06','6.1.02.11','6.1.02.12','4.2.01.03')")" \
  = "1.1.02.04=Préstamos a socios; 1.1.02.05=Diferencias de caja por resolver; 1.1.02.06=Cuentas por cobrar a empleados; 4.2.01.03=Sobrantes de caja; 6.1.02.11=Vigilancia; 6.1.02.12=Faltantes de caja" ] \
  || falla "cuentas nuevas: $(q "SELECT string_agg(codigo || '=' || nombre, '; ' ORDER BY codigo) FROM public.cuenta WHERE empresa_id = $E AND codigo LIKE '1.1.02.%'")"
[ "$(q "SELECT interno.cuenta_de($E, 'diferencia_caja') || ',' || interno.cuenta_de($E, 'cxc_empleados') || ',' || interno.cuenta_de($E, 'faltante_caja') || ',' || interno.cuenta_de(pruebas.empresa('B'), 'diferencia_caja')")" \
  = "1.1.02.05,1.1.02.06,6.1.02.12,1.1.02.04" ] || falla "usos por empresa"
# Permisos: llegan los nuevos; el que quitó el dueño no vuelve.
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND rol = 'admin' AND permiso IN ('dinero.trasladar','gastos.aprobar','caja.supervisar')")" = "3" ] \
  || falla "el admin no recibió los permisos nuevos"
[ "$(q "SELECT count(*) FROM public.rol_permiso WHERE empresa_id = $E AND rol = 'admin' AND permiso = 'compras.anular'")" = "0" ] || falla "volvió un permiso quitado"
[ "$(q "SELECT count(*) FROM public.permiso p WHERE NOT EXISTS (SELECT 1 FROM public.rol_permiso r WHERE r.empresa_id = $E AND r.rol = 'dueno' AND r.permiso = p.codigo)")" = "0" ] \
  || falla "el dueño no tiene todos los permisos"

# 5) Con el módulo "dinero": un turno con faltante va a 1.1.02.05 (controlada) y se cobra a 1.1.02.06;
#    la cuenta del cliente 1.1.02.04 sigue aceptando asientos manuales; lo de antes sigue funcionando.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL'
BEGIN;
SELECT pruebas.preparar_dinero();
SELECT pruebas.como('admin_a');
SELECT public.trasladar_dinero(pruebas.empresa('A'), jsonb_build_object('tipo', 'traslado', 'origen_id', pruebas.id('FUERTE'),
  'destino_id', pruebas.id('CAJA1'), 'monto_centavos', 10000), gen_random_uuid());
SELECT pruebas.como('cajero_a');
SELECT pruebas.guardar('T1', (public.abrir_turno(pruebas.empresa('A'), pruebas.id('CAJA001'), 10000, gen_random_uuid())->>'turno_id')::uuid);
SELECT public.cerrar_turno(pruebas.id('T1'), 9000, gen_random_uuid());
SELECT pruebas.como('admin_a');
SELECT public.resolver_diferencia(pruebas.id('T1'), 'cobrar_al_cajero', 'Faltante reconocido', gen_random_uuid());
SELECT public.pagar_proveedor(pruebas.empresa('A'), pruebas.id('CC'), 1500, public.hoy_local(pruebas.empresa('A')), 'caja', gen_random_uuid());
SELECT pruebas.como('dueno_a');
SELECT public.registrar_asiento(pruebas.empresa('A'), public.hoy_local(pruebas.empresa('A')), 'Abono del socio',
  pruebas.lineas('1.1.01.01', '1.1.02.04', 1000), gen_random_uuid());
COMMIT;
SQL
[ "$(q "SELECT pruebas.saldo_libros($E, '1.1.02.04') || '/' || pruebas.saldo_libros($E, '1.1.02.05') || '/' || pruebas.saldo_libros($E, '1.1.02.06')")" = "3000/0/1000" ] \
  || falla "cuentas de la diferencia: $(q "SELECT pruebas.saldo_libros($E, '1.1.02.04') || '/' || pruebas.saldo_libros($E, '1.1.02.05') || '/' || pruebas.saldo_libros($E, '1.1.02.06')")"
if q "BEGIN; SELECT pruebas.como('dueno_a'); SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-10', 'Por fuera', pruebas.lineas('1.1.02.05', '1.1.01.01', 1), gen_random_uuid()); COMMIT;" >/dev/null 2>"$TMP/err"; then
  falla "aceptó un asiento manual a la cuenta de diferencias (1.1.02.05)"
fi
grep -q CUENTA_CONTROLADA "$TMP/err" || { cat "$TMP/err"; falla "el error no es CUENTA_CONTROLADA"; }
[ "$(q "SELECT interno.total_cxp($E) || '/' || pruebas.saldo_libros($E, '2.1.01.01')")" = "5000/5000" ] || falla "CxP: 11,500 - 5,000 - 1,500 = 5,000"
[ "$(q "SELECT count(*) FROM public.cuenta_dinero d JOIN public.cuenta c ON c.id = d.cuenta_id WHERE interno.saldo_dinero(d.id) <> pruebas.saldo_libros(d.empresa_id, c.codigo)")" = "0" ] \
  || falla "dinero distinto de libros"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
