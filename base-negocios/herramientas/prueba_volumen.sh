#!/usr/bin/env bash
# =====================================================================
# prueba_volumen.sh  -  Prueba de volumen ligera (NO está en probar.sh:
# tarda varios minutos). Solo usa la base local de pruebas.
#
#   bash herramientas/prueba_volumen.sh            # 20,000 ventas
#   VENTAS=5000 bash herramientas/prueba_volumen.sh
#
# Qué hace:
#   1. Crea la base "volumen" en el PostgreSQL local (.pgdata) con el
#      simulador de Supabase, todas las migraciones y los datos de prueba.
#   2. Registra VENTAS ventas REALES con registrar_venta (asiento, kardex,
#      rastro del dinero y bitácora), repartidas en los últimos 90 días, en
#      dos sucursales, en lotes de 1,000 por transacción.
#   3. Mide (como el dueño, que ve todo): resumen_hoy, alertas_activas,
#      estado_resultados del mes pasado, libro_ventas del mes pasado,
#      reporte_sucursales de 90 días y vigilancia_empleados de 30 días.
#      Cada consulta se corre 3 veces y se informa la mejor.
# Variables: VENTAS (defecto 20000), MANTENER_SERVIDOR=1, MANTENER_BASE=1.
# =====================================================================
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export RAIZ
VENTAS="${VENTAS:-20000}"
BASE="volumen"
DIR_PRUEBAS="$RAIZ/nucleo/pruebas"

source "$RAIZ/herramientas/servidor_local.sh"
unset PGDATABASE DATABASE_URL
local_encender || exit 1
trap local_apagar EXIT
psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

echo "Preparando base de volumen ..."
dropdb --if-exists "$BASE" >/dev/null 2>&1
createdb "$BASE" || exit 1
psql_q -d "$BASE" -f "$DIR_PRUEBAS/simular_supabase.sql" >/dev/null || exit 1
PGDATABASE="$BASE" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" >/dev/null || exit 1
psql_q -d "$BASE" -f "$DIR_PRUEBAS/preparar_datos.sql" >/dev/null || exit 1

# Datos base: ventas, sucursal Norte con su caja y bodega, mucha existencia.
psql_q -d "$BASE" <<'SQL' >/dev/null || exit 1
DO $$
DECLARE
  e  uuid := pruebas.empresa('A');
  s2 uuid;
  c2 uuid;
BEGIN
  PERFORM pruebas.preparar_ventas(false);
  PERFORM public.configurar_empresa(e, '{"turnos_obligatorios": false}', 'Prueba de volumen');
  s2 := (public.crear_sucursal(e, '002', 'Sucursal Norte')->>'sucursal_id')::uuid;
  c2 := (public.crear_caja(e, s2, 'Caja Norte', '001')->>'caja_id')::uuid;
  PERFORM pruebas.guardar('CAJA002', c2);
  PERFORM public.crear_cuenta_dinero(e, jsonb_build_object('tipo', 'efectivo_caja', 'nombre', 'Caja Norte', 'caja_id', c2));
  PERFORM pruebas.guardar('B3', (public.crear_bodega(e, s2, 'B3', 'Bodega Norte')->>'bodega_id')::uuid);
  PERFORM public.registrar_compra(e, jsonb_build_object('proveedor_id', pruebas.id('PROV2'), 'bodega_id', pruebas.id(b),
    'numero_documento', 'VOL-' || b, 'fecha', to_char(public.hoy_local(e) - 100, 'YYYY-MM-DD'), 'condicion', 'credito',
    'lineas', jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 200000, 'costo_unitario', 1000),
                                jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 200000, 'costo_unitario', 1500))), gen_random_uuid())
    FROM unnest(ARRAY['B1', 'B3']) b;
END $$;
SQL

echo "Registrando $VENTAS ventas (lotes de 1,000) ..."
inicio=$(date +%s)
hechas=0
while [ "$hechas" -lt "$VENTAS" ]; do
  lote=$(( VENTAS - hechas < 1000 ? VENTAS - hechas : 1000 ))
  psql_q -d "$BASE" -v lote="$lote" -v base="$hechas" <<'SQL' >/dev/null || { echo "FALLA registrando ventas"; exit 1; }
SELECT set_config('vol.lote', :'lote', false), set_config('vol.base', :'base', false);
DO $$
DECLARE
  e   uuid := pruebas.empresa('A');
  hoy date := public.hoy_local(e);
  i   integer;
  k   integer;
BEGIN
  PERFORM pruebas.como('dueno_a');
  FOR i IN 1..current_setting('vol.lote')::integer LOOP
    k := current_setting('vol.base')::integer + i;
    PERFORM public.registrar_venta(e, jsonb_build_object(
      'caja_id', CASE WHEN k % 3 = 0 THEN pruebas.id('CAJA002') ELSE pruebas.id('CAJA001') END,
      'fecha', to_char(hoy - (k % 90), 'YYYY-MM-DD'),
      'lineas', CASE WHEN k % 5 = 0
        THEN jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1 + k % 4),
                               jsonb_build_object('producto_id', pruebas.id('S1'), 'cantidad', 1))
        ELSE jsonb_build_array(jsonb_build_object('producto_id', pruebas.id('P2'), 'cantidad', 0.5 + (k % 3)),
                               jsonb_build_object('producto_id', pruebas.id('P1'), 'cantidad', 1)) END,
      'pagos', jsonb_build_array(jsonb_build_object('forma', CASE WHEN k % 4 = 0 THEN 'tarjeta' ELSE 'efectivo' END))),
      gen_random_uuid());
  END LOOP;
END $$;
SQL
  hechas=$(( hechas + lote ))
  echo "  $hechas ventas ($(( $(date +%s) - inicio )) s)"
done
psql_q -d "$BASE" -c "ANALYZE" >/dev/null

echo
echo "Tiempos (mejor de 3, en milisegundos):"
psql -X -q -At -v ON_ERROR_STOP=1 -d "$BASE" <<'SQL' || { echo "FALLA midiendo"; exit 1; }
CREATE FUNCTION pg_temp.medir(p_nombre text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; mejor numeric := NULL; ms numeric; i integer;
BEGIN
  FOR i IN 1..3 LOOP
    t0 := clock_timestamp();
    EXECUTE p_sql;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    mejor := least(coalesce(mejor, ms), ms);
  END LOOP;
  RETURN rpad(p_nombre, 40) || lpad(round(mejor)::text, 8) || ' ms';
END $$;
SELECT pruebas.como('dueno_a');
SELECT 'ventas en la base: ' || count(*) FROM public.venta;
WITH x AS (SELECT pruebas.empresa('A') e, public.hoy_local(pruebas.empresa('A')) hoy)
SELECT pg_temp.medir(n, format(q, x.e, x.hoy)) FROM x, (VALUES
  (1, 'resumen_hoy',                    'SELECT public.resumen_hoy(%L)'),
  (2, 'alertas_activas',                'SELECT public.alertas_activas(%L)'),
  (3, 'estado_resultados (mes pasado)', 'SELECT public.estado_resultados(%L, extract(year FROM date_trunc(''month'', %L::date) - interval ''1 day'')::int, extract(month FROM date_trunc(''month'', %2$L::date) - interval ''1 day'')::int)'),
  (4, 'libro_ventas (mes pasado)',      'SELECT public.libro_ventas(%L, extract(year FROM date_trunc(''month'', %L::date) - interval ''1 day'')::int, extract(month FROM date_trunc(''month'', %2$L::date) - interval ''1 day'')::int)'),
  (5, 'reporte_sucursales (90 días)',   'SELECT public.reporte_sucursales(%L, %L::date - 89, %2$L::date)'),
  (6, 'vigilancia_empleados (30 días)', 'SELECT public.vigilancia_empleados(%L, %L::date - 29, %2$L::date)')) v(o, n, q)
ORDER BY o;
SQL
[ "${MANTENER_BASE:-0}" = "1" ] || dropdb --if-exists "$BASE" >/dev/null 2>&1
echo "Listo."
