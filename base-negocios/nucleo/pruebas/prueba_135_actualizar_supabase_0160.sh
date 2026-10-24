#!/usr/bin/env bash
# PRUEBA: (0.16.0) actualizar en "Supabase" una base 0.15.0 instalada con las partes del SQL Editor (mini Supabase, rol sin superusuario, una petición por archivo) pegando SOLO dist/actualizar_supabase_0.16.0.sql: dice ACTUALIZADO A 0.16.0, verificar_instalacion dice TODO BIEN, el dueño ve exactamente lo mismo que antes (dinero, proyección, fondos, cuentas por pagar, comisiones, conciliación, resumen), correrlo otra vez no cambia nada, en una base sin núcleo o sin la 051 se rechaza sin tocar nada, un error a mitad no deja nada a medias, la bitácora queda íntegra, y migrar.sh la reconoce
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
# Fija en 0.16.0 (desde 0.17.0 el paquete actual trae más; la 140 prueba 0.16.0 -> 0.17.0).
VERSION="0.16.0"
VIEJA="${BASE}_015"
OTRA="${BASE}_sin051"
TMP="$(mktemp -d)"
limpiar() { dropdb --if-exists "$VIEJA" >/dev/null 2>&1 || true; dropdb --if-exists "$OTRA" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap limpiar EXIT
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
una() { python3 "$RAIZ/herramientas/sql_una_peticion.py" "$PGHOST" "$PGPORT" supa_postgres "$1" "$2"; }

# 1) Paquete 0.15.0 (migraciones 001-051) y el paquete 0.16.0 (001-052, con la actualización).
mkdir -p "$TMP/v015/herramientas" "$TMP/v015/nucleo/sql/migraciones" "$TMP/dist015" "$TMP/dist" \
  "$TMP/v016/herramientas" "$TMP/v016/nucleo/sql/migraciones"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v015/herramientas/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[01]_*.sql; do cp "$f" "$TMP/v015/nucleo/sql/migraciones/"; done
echo "0.15.0" > "$TMP/v015/VERSION_NUCLEO"
bash "$TMP/v015/herramientas/armar_instalacion.sh" "$TMP/dist015" >/dev/null || falla "no se armó el paquete 0.15.0"
cp "$RAIZ/herramientas/armar_instalacion.sh" "$TMP/v016/herramientas/"
for f in "$RAIZ"/nucleo/sql/migraciones/0[0-4][0-9]_*.sql "$RAIZ"/nucleo/sql/migraciones/05[012]_*.sql; do cp "$f" "$TMP/v016/nucleo/sql/migraciones/"; done
echo "0.16.0" > "$TMP/v016/VERSION_NUCLEO"
bash "$TMP/v016/herramientas/armar_instalacion.sh" "$TMP/dist" >/dev/null || falla "no se armó el paquete 0.16.0"
ACT="$TMP/dist/actualizar_supabase_${VERSION}.sql"
[ -f "$ACT" ] || falla "no hay $ACT"
[ "$(ls "$TMP"/dist/actualizar_supabase_* | wc -l)" = "1" ] || falla "la actualización debía ser un solo archivo"
[ "$(stat -c %s "$ACT")" -lt $((200 * 1024)) ] || falla "la actualización pasa de 200 KB"
grep -q "Migración 052_" "$ACT" && ! grep -q "Migración 051_" "$ACT" || falla "la actualización debe traer solo la 052"

# 2) Base 0.15.0 como en Supabase (partes del SQL Editor) con datos de enero.
createdb "$VIEJA"
psql -X -q -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase"
for p in "$TMP"/dist015/instalar_supabase_parte*.sql; do una "$VIEJA" "$p" >/dev/null || falla "parte 0.15.0 $(basename "$p")"; done
[ "$(q "$VIEJA" "SELECT version_nucleo || '/' || ultima_migracion FROM public.version_esquema")" = "0.15.0/51" ] || falla "no quedó en 0.15.0"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" -f "$RAIZ/nucleo/pruebas/preparar_datos.sql" >/dev/null || falla "preparar_datos"
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "datos de enero"
BEGIN;
SELECT pruebas.preparar_enero();
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'comisiones'), (pruebas.empresa('A'), 'conciliacion');
SELECT pruebas.como('dueno_a');
SELECT public.crear_sucursal(pruebas.empresa('A'), '002', 'Sucursal Norte');
SELECT public.importar_estado_cuenta(pruebas.empresa('A'), pruebas.id('BANCO'), 2026, 1,
  '{"filas":[{"fecha":"2026-01-22","descripcion":"PAGO ENEE","monto_centavos":-11500}]}', gen_random_uuid());
-- El cliente ya usaba 3.1.01.04 "Aportes de socios" con un asiento suyo: la 052 debe poner la del sistema en la siguiente libre.
SELECT public.crear_subcuenta(pruebas.empresa('A'), '3.1.01', '3.1.01.04', 'Aportes de socios');
SELECT public.registrar_asiento(pruebas.empresa('A'), '2026-01-30', 'Aporte anotado a mano', jsonb_build_array(
  jsonb_build_object('cuenta', '3.3.01.01', 'debe', 100), jsonb_build_object('cuenta', '3.1.01.04', 'haber', 100)), gen_random_uuid());
SELECT public.registrar_saldo_inicial_cxp(pruebas.empresa('A'), jsonb_build_object('proveedor_id', pruebas.id('PROV2'),
  'numero_documento', 'SI-9', 'fecha_documento', '2025-12-20', 'monto_centavos', 30000), gen_random_uuid());
COMMIT;
SQL

# Lo que ve una persona (dueño o admin sin restricción), sin horas.
foto() {
  psql -X -q -tA -v ON_ERROR_STOP=1 -d "$VIEJA" <<SQL
BEGIN;
SELECT pruebas.como('$1') \g /dev/null
SELECT jsonb_build_object(
  'dinero', public.donde_esta_mi_dinero(pruebas.empresa('A')) - 'hora_servidor',
  'flujo', public.proyeccion_flujo(pruebas.empresa('A'), 30) - 'generado_en',
  'fondos', public.estado_fondos(pruebas.empresa('A')) - 'generado_en',
  'resumen', public.resumen_hoy(pruebas.empresa('A')) - 'generado_en',
  'cxp', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.documento_id) FROM public.v_cxp_documento x),
  'comisiones', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.vendedor_id) FROM public.v_comision_vendedor x),
  'conciliacion', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.conciliacion_id) FROM public.v_conciliacion x),
  'pagos', (SELECT count(*) FROM public.pago_proveedor), 'lineas', (SELECT count(*) FROM public.compra_linea),
  'saldos_iniciales', (SELECT count(*) FROM public.cxp_saldo_inicial), 'banco', (SELECT count(*) FROM public.banco_movimiento))::text;
ROLLBACK;
SQL
}
ANTES_DUENO="$(foto dueno_a)"
ANTES_ADMIN="$(foto admin_a)"
[ -n "$ANTES_DUENO" ] && [ -n "$ANTES_ADMIN" ] || falla "no se tomó la foto de antes"

# 3) Rechazos sin tocar nada: base sin núcleo y base sin la 051.
createdb "$OTRA"
psql -X -q -d "$OTRA" -f "$RAIZ/nucleo/pruebas/mini_supabase.sql" >/dev/null 2>&1 || falla "mini_supabase (otra)"
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó en una base sin núcleo"; fi
grep -q "FALTA_NUCLEO" "$TMP/sal.txt" || falla "sin núcleo debía decir FALTA_NUCLEO: $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT to_regclass('interno._migraciones') IS NULL")" = "t" ] || falla "la base sin núcleo quedó tocada"
for p in "$TMP"/dist015/instalar_supabase_parte*.sql; do
  case "$(basename "$p")" in *parte13.sql) continue ;; esac   # la 13 trae 047-051
  una "$OTRA" "$p" >/dev/null || falla "parte $(basename "$p") en la otra base"
done
if una "$OTRA" "$ACT" >"$TMP/sal.txt" 2>&1; then falla "se aplicó sin la 051"; fi
grep -q "FALTA_VERSION_ANTERIOR" "$TMP/sal.txt" || falla "sin la 051 debía decir FALTA_VERSION_ANTERIOR: $(cat "$TMP/sal.txt")"
[ "$(q "$OTRA" "SELECT max(numero) FROM interno._migraciones")" = "46" ] || falla "la base sin la 051 quedó tocada"

# 3b) Un error a mitad (copia del archivo con una división por cero justo antes del final): no queda nada a medias.
sed 's/^NOTIFY pgrst, .reload schema.;$/SELECT 1 \/ 0 AS falla_a_proposito;\n&/' "$ACT" > "$TMP/act_roto.sql"
grep -q "falla_a_proposito" "$TMP/act_roto.sql" || falla "no se pudo armar la copia con error"
if una "$VIEJA" "$TMP/act_roto.sql" >"$TMP/sal.txt" 2>&1; then falla "la copia con error se aplicó"; fi
[ "$(q "$VIEJA" "SELECT max(numero) || '/' || (to_regprocedure('public.totales_compras(uuid,date,date,uuid)') IS NULL)
      || '/' || (SELECT count(*) FROM pg_policies WHERE policyname = 'por_sucursal' AND tablename IN ('pago_proveedor', 'cxc_aplicacion', 'saldo_favor'))
      || '/' || (to_regclass('public.periodo_operacion') IS NULL) FROM interno._migraciones")" = "51/true/0/true" ] \
  || falla "el error a mitad dejó algo a medias"
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || falla "el error a mitad cambió lo que ve el dueño"

# 4) Actualizar: una sola petición, todo o nada.
una "$VIEJA" "$ACT" >"$TMP/sal.txt" || falla "la actualización dio error: $(cat "$TMP/sal.txt")"
grep -q "^ACTUALIZADO A $VERSION | $VERSION | 52 | 52" "$TMP/sal.txt" || falla "no dijo ACTUALIZADO A $VERSION: $(cat "$TMP/sal.txt")"
una "$VIEJA" "$TMP/dist/verificar_instalacion.sql" | grep -q "^TODO BIEN | $VERSION |" || falla "verificar_instalacion no dice TODO BIEN"
[ "$(q "$VIEJA" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'interno') AND pg_get_userbyid(p.proowner) <> 'supa_postgres'")" = "0" ] || falla "funciones con otro dueño"
[ "$(q "$VIEJA" "SELECT checksum FROM interno._migraciones WHERE numero = 52")" \
  = "$(sha256sum "$RAIZ/nucleo/sql/migraciones/052_sucursal_totales.sql" | cut -d' ' -f1)" ] || falla "huella de la 052"

[ "$(q "$VIEJA" "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "la bitácora no quedó íntegra"

# 5) El dueño (y quien no tiene restricción) ve exactamente lo mismo.
[ "$(foto dueno_a)" = "$ANTES_DUENO" ] || { echo "antes:   $ANTES_DUENO"; echo "despues: $(foto dueno_a)"; falla "el dueño ve otra cosa después de actualizar"; }
[ "$(foto admin_a)" = "$ANTES_ADMIN" ] || falla "el admin sin restricción ve otra cosa después de actualizar"

# 6) Otra vez: no cambia nada y sigue diciendo ACTUALIZADO.
antes="$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")"
una "$VIEJA" "$ACT" | grep -q "^ACTUALIZADO A $VERSION |" || falla "al repetir no dijo ACTUALIZADO"
[ "$(q "$VIEJA" "SELECT count(*) || '/' || max(aplicada_en) FROM interno._migraciones")" = "$antes" ] || falla "repetir cambió las migraciones"

# 7) Funciona: lo nuevo existe y migrar.sh no ve nada pendiente.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "lecturas nuevas"
BEGIN;
SELECT pruebas.como('dueno_a');
DO $$ BEGIN
  PERFORM pruebas.afirmar((public.totales_compras(pruebas.empresa('A'), '2026-01-01', '2026-01-31')->>'total_centavos')::bigint = 544000, 'totales_compras');
  PERFORM pruebas.afirmar((public.totales_gastos(pruebas.empresa('A'), '2026-01-01', '2026-01-31')->>'gastado_centavos')::bigint = 11500, 'totales_gastos');
  PERFORM pruebas.afirmar((public.mas_vendido(pruebas.empresa('A'), '2026-01-01', '2026-01-31')->'total'->>'total_vendido_centavos')::bigint = 106000, 'mas_vendido');
END $$;
ROLLBACK;
SQL
# 7b) Lo nuevo de la 052 en la empresa que ya existía: cuenta de aportes (la siguiente libre, porque la 3.1.01.04 ya
#     tenía un asiento del cliente), permiso del dueño y un aporte de verdad.
psql -X -q -v ON_ERROR_STOP=1 -d "$VIEJA" >/dev/null <<'SQL' || falla "aporte de socio en la base actualizada"
BEGIN;
SELECT pruebas.como('superusuario');
INSERT INTO public.modulo_activo (empresa_id, modulo) VALUES (pruebas.empresa('A'), 'fondos');
DO $$
DECLARE e uuid := pruebas.empresa('A'); s uuid; r jsonb;
BEGIN
  PERFORM pruebas.afirmar(interno.cuenta_de(e, 'aportes_socios') = '3.1.01.05', 'cuenta de aportes: ' || interno.cuenta_de(e, 'aportes_socios'));
  PERFORM pruebas.afirmar(EXISTS (SELECT 1 FROM public.rol_permiso WHERE empresa_id = e AND rol = 'dueno' AND permiso = 'fondos.aportes'), 'permiso del dueño');
  PERFORM pruebas.como('dueno_a');
  s := (public.guardar_socio(e, jsonb_build_object('user_id', pruebas.usuario('dueno_a'), 'porcentaje', 100), 'Socio único')->>'socio_id')::uuid;
  r := public.registrar_aporte_socio(e, jsonb_build_object('socio_id', s, 'monto_centavos', 250000, 'cuenta_dinero_id', pruebas.id('BANCO')), gen_random_uuid());
  PERFORM pruebas.afirmar(r->>'cuenta_capital' = '3.1.01.05' AND pruebas.saldo_libros(e, '3.1.01.05') = 250000
    AND pruebas.saldo_libros(e, '3.1.01.04') = 100 AND (public.aportes_socios(e)->>'cuadra')::boolean, 'aporte: ' || r::text);
END $$;
ROLLBACK;
SQL
# migrar.sh reconoce lo instalado (misma huella): solo quedan pendientes las migraciones de después de la 052.
PEND="$(PGDATABASE="$VIEJA" SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$RAIZ/herramientas/migrar.sh" --solo-mostrar)" || falla "migrar.sh no reconoce la base actualizada"
if echo "$PEND" | grep -E "^  - 0([0-4][0-9]|5[012])_" >/dev/null; then falla "migrar.sh ve pendiente algo de 0.16.0: $PEND"; fi
echo "ok"
