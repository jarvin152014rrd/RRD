#!/usr/bin/env bash
# PRUEBA: ficha del cliente (formato 2) y herramientas del proveedor: nuevo_cliente.sh crea la empresa con módulos, perfil, licencia y límites en una transacción; aplicar_ficha.sh valida, muestra la vista previa (módulos en orden de dependencias, perfil, licencia, límites con uso), prueba y deshace (MODULO_CON_SALDO, dependencias), pide el identificador del cliente, aplica todo o nada con bitácora y nunca borra; la ficha no viaja como argumento ni guarda claves; lista_clientes.sh muestra base o ficha y marca a quien está al 80 % de un límite
set -euo pipefail
BASE="$1"
RAIZ="${RAIZ:-$(cd "$(dirname "$0")/../.." && pwd)}"
H="$RAIZ/herramientas"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PGDATABASE="$BASE"
falla() { echo "FALLA: $*"; exit 1; }
q() { psql -X -q -tA -v ON_ERROR_STOP=1 -c "$1"; }
C="$TMP/clientes"; mkdir -p "$C/salon"
F="$C/salon/ficha.json"
EMP="(SELECT id FROM public.empresa WHERE nombre = 'Salón Bella')"
# Cambia la ficha con un pedazo de Python (f = la ficha).
editar() { python3 - "$F" "$1" <<'PY'
import json, sys
f = json.load(open(sys.argv[1], encoding="utf-8")); exec(sys.argv[2])
json.dump(f, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}
# psql que anota sus argumentos (para ver que la ficha no viaja como argumento).
REAL="$(dirname "$(command -v psql)")"; mkdir "$TMP/bin"
printf '#!/usr/bin/env bash\necho "ARGS: $*" >> "%s/log"\nexec "%s/psql" "$@"\n' "$TMP" "$REAL" > "$TMP/bin/psql"; chmod +x "$TMP/bin/psql"
: > "$TMP/log"

q "INSERT INTO auth.users (email) VALUES ('bella@salon.hn')"
cat > "$F" <<'EOF'
{"cliente": "salon", "paquete": "esencial",
 "negocio": {"nombre": "Salón Bella", "fecha_inicio": "2026-01-01"},
 "perfil": "pequeno",
 "modulos": {"contabilidad": true, "ventas": true, "inventario": false, "compras": false, "dinero": false},
 "regimen_fiscal": "ninguno",
 "licencia": {"vence_el": "2026-12-31", "dias_gracia": 5},
 "limites": {"usuarios": 1, "cajas": 1, "sucursales": 1, "bodegas": null},
 "dueno": {"correo": "bella@salon.hn", "nombre": "Bella"}}
EOF

# 1) nuevo_cliente.sh con el formato nuevo: empresa, módulos, perfil, licencia y límites juntos.
SIN_PREGUNTAR=1 PATH="$TMP/bin:$PATH" bash "$H/nuevo_cliente.sh" "$F" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "nuevo_cliente con ficha nueva"; }
grep -q "Licencia y límites de la ficha aplicados" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no aplicó licencia y límites"; }
[ "$(q "SELECT string_agg(modulo, ',' ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = $EMP AND activo")" = "contabilidad,ventas" ] || falla "módulos iniciales"
[ "$(q "SELECT perfil || '/' || vendedor_cobra FROM public.empresa WHERE id = $EMP")" = "pequeno/true" ] || falla "perfil pequeño (vendedor cobra)"
[ "$(q "SELECT vence_el || '/' || dias_gracia FROM public.licencia WHERE empresa_id = $EMP")" = "2026-12-31/5" ] || falla "licencia"
[ "$(q "SELECT usuarios || '/' || cajas || '/' || coalesce(bodegas::text, 'null') FROM public.limite_contrato WHERE empresa_id = $EMP")" = "1/1/null" ] || falla "límites"
[ "$(q "SELECT count(*) FROM public.bitacora WHERE empresa_id = $EMP AND tabla = 'limite_contrato' AND motivo = 'Ficha inicial del cliente salon'")" = "1" ] || falla "bitácora de la ficha inicial"
editar "f['negocio']['empresa_id'] = '$(q "SELECT $EMP")'"

# 2) Vista previa: activar dinero e inventario (antes) y fiscal_hn; licencia; límites con uso. Nada cambia.
editar "f['modulos'].update({'dinero': True, 'inventario': True}); f['regimen_fiscal'] = 'fiscal_hn'; f['licencia']['vence_el'] = '2027-01-31'; f['limites']['cajas'] = 2"
PATH="$TMP/bin:$PATH" bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "vista previa"; }
grep -q "activar:    dinero, inventario, fiscal_hn" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "orden de activación"; }
grep -q "vence 2026-12-31 (gracia 5 días) -> vence 2027-01-31" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "licencia en la vista previa"; }
grep -qE "cajas +1 / 1  ->  2" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "límites en la vista previa"; }
grep -q "no se aplicó nada" "$TMP/s.txt" || falla "--solo-mostrar"
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE empresa_id = $EMP AND activo")" = "2" ] || falla "--solo-mostrar cambió algo"

# 3) Confirmación equivocada: cancela.
if echo "otro" | SIN_RESPALDO=1 bash "$H/aplicar_ficha.sh" "$F" >"$TMP/s.txt" 2>&1; then falla "debía cancelar"; fi
grep -q "Cancelado" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no dice Cancelado"; }
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE empresa_id = $EMP AND activo")" = "2" ] || falla "canceló pero cambió"

# 4) Con el identificador del cliente: aplica todo.
echo "salon" | SIN_RESPALDO=1 PATH="$TMP/bin:$PATH" bash "$H/aplicar_ficha.sh" "$F" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "no aplicó"; }
grep -q "Ficha aplicada" "$TMP/s.txt" || falla "no dice Ficha aplicada"
[ "$(q "SELECT string_agg(modulo, ',' ORDER BY modulo) FROM public.modulo_activo WHERE empresa_id = $EMP AND activo")" = "contabilidad,dinero,fiscal_hn,inventario,ventas" ] \
  || falla "módulos aplicados"
[ "$(q "SELECT vence_el FROM public.licencia WHERE empresa_id = $EMP")" = "2027-01-31" ] || falla "licencia aplicada"
[ "$(q "SELECT cajas FROM public.limite_contrato WHERE empresa_id = $EMP")" = "2" ] || falla "límite aplicado"
[ "$(q "SELECT count(*) FROM public.bitacora WHERE empresa_id = $EMP AND tabla = 'modulo_activo' AND motivo LIKE 'Ficha del cliente salon%'")" = "3" ] || falla "bitácora"
grep "ARGS:" "$TMP/log" | grep -qiE "Bella|bella@|2027-01-31|fiscal_hn" && { grep "ARGS:" "$TMP/log"; falla "la ficha viajó como argumento de psql"; }

# 5) Sin cambios.
bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1 || falla "sin cambios no es error"
grep -q "No hay cambios" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no dice No hay cambios"; }

# 6) Dependencias mal pedidas: error claro y nada cambia.
cp "$F" "$TMP/buena.json"
editar "f['modulos']['ventas'] = False"
if SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$H/aplicar_ficha.sh" "$F" >"$TMP/s.txt" 2>&1; then falla "aceptó fiscal_hn sin ventas"; fi
grep -q 'El módulo "fiscal_hn" necesita "ventas"' "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no dice qué falta"; }
cp "$TMP/buena.json" "$F"; editar "f['modulos'].update({'compras': True, 'inventario': False})"
if SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$H/aplicar_ficha.sh" "$F" >"$TMP/s.txt" 2>&1; then falla "aceptó compras sin inventario"; fi
grep -q 'necesita "inventario"' "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "compras sin inventario"; }
[ "$(q "SELECT count(*) FROM public.modulo_activo WHERE empresa_id = $EMP AND activo")" = "5" ] || falla "cambió algo con error"

# 7) La prueba-y-deshacer muestra MODULO_CON_SALDO antes de confirmar (2.1.01.01 con saldo manual).
q "INSERT INTO pruebas.usuario (apodo, id) SELECT 'bella', user_id FROM public.usuario_empresa WHERE empresa_id = $EMP AND rol = 'dueno'"
q "SELECT pruebas.como('bella'); SELECT public.registrar_asiento($EMP, '2026-01-10', 'Deuda vieja', pruebas.lineas('6.1.02.05', '2.1.01.01', 5000), gen_random_uuid());" >/dev/null
cp "$TMP/buena.json" "$F"; editar "f['modulos']['compras'] = True"
if bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1; then falla "no avisó del saldo"; fi
grep -q "MODULO_CON_SALDO" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no muestra MODULO_CON_SALDO"; }

# 8) Apagar un módulo: solo impide lo nuevo; nada se borra.
cp "$TMP/buena.json" "$F"; editar "f['modulos']['dinero'] = False"
N0="$(q "SELECT count(*) FROM public.asiento WHERE empresa_id = $EMP")"
SIN_PREGUNTAR=1 SIN_RESPALDO=1 bash "$H/aplicar_ficha.sh" "$F" >"$TMP/s.txt" 2>&1 || { cat "$TMP/s.txt"; falla "apagar dinero"; }
grep -q "nada se borra" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "la vista previa no lo explica"; }
[ "$(q "SELECT activo || '/' || estuvo_activo FROM public.modulo_activo WHERE empresa_id = $EMP AND modulo = 'dinero'")" = "false/true" ] || falla "dinero apagado"
[ "$(q "SELECT count(*) FROM public.asiento WHERE empresa_id = $EMP")" = "$N0" ] || falla "algo cambió en los libros"

# 9) Fichas peligrosas o mal puestas.
cp "$TMP/buena.json" "$F"; editar "f['conexion'] = 'postgresql://postgres:secreta@db.abc.supabase.co:5432/postgres'"
if bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1; then falla "aceptó una clave en la ficha"; fi
grep -q "CLAVE" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica lo de la clave"; }
cp "$TMP/buena.json" "$F"; editar "f['cliente'] = 'otro'"
if bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1; then falla "aceptó cliente distinto a su carpeta"; fi
grep -q 'carpeta "salon"' "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica la carpeta"; }
cp "$TMP/buena.json" "$F"; editar "f['modulos']['nomina'] = True"
if bash "$H/aplicar_ficha.sh" --solo-mostrar "$F" >"$TMP/s.txt" 2>&1; then falla "aceptó un módulo inventado"; fi
grep -q "nomina" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no dice qué módulo"; }
cp "$TMP/buena.json" "$F"
bash "$H/aplicar_ficha.sh" --solo-mostrar "$RAIZ/personal/ficha.ejemplo.json" >"$TMP/s.txt" 2>&1 && falla "aceptó el formato 1"
grep -q "formato de ficha" "$TMP/s.txt" || { cat "$TMP/s.txt"; falla "no explica el formato"; }

# 10) Lista de clientes: con acceso (base), sin acceso (ficha) y la marca del 80 %.
editar "f['conexion'] = 'postgresql://postgres@/$BASE?host=$PGHOST&port=${PGPORT:-5432}'"
mkdir -p "$C/sinbase" "$C/caida"
cp "$RAIZ/clientes/ejemplo/ficha.json" "$C/sinbase/ficha.json"
python3 - "$C/sinbase/ficha.json" "$C/caida/ficha.json" <<'PY'
import json, sys
f = json.load(open(sys.argv[1], encoding="utf-8")); f["cliente"] = "sinbase"; f.pop("conexion")
json.dump(f, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
f["cliente"] = "caida"; f["conexion"] = "postgresql://postgres@/nadie?host=/no/existe&port=1"
json.dump(f, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
DIR_CLIENTES="$C" bash "$H/lista_clientes.sh" >"$TMP/s.txt" 2>&1 < /dev/null || { cat "$TMP/s.txt"; falla "lista_clientes"; }
V="$(tr -d '[:space:]' < "$RAIZ/VERSION_NUCLEO")"
grep -E "^\(!\) salon +esencial +contabilidad,fiscal_hn,inventario,ventas +2027-01-31 +$V +usu 1/1, caj 1/2, suc 1/1, bod 0/- +base" "$TMP/s.txt" >/dev/null \
  || { cat "$TMP/s.txt"; falla "fila de salon (base, al 100 % de usuarios)"; }
grep -E "^sinbase .*ficha \(sin acceso a la base\)" "$TMP/s.txt" >/dev/null || { cat "$TMP/s.txt"; falla "fila sin conexión"; }
grep -E "^caida .*ficha \(sin acceso a la base\)" "$TMP/s.txt" >/dev/null || { cat "$TMP/s.txt"; falla "fila con base caída"; }
grep -q "Clientes: 3" "$TMP/s.txt" || falla "cuenta de clientes"
[ "$(q "SELECT count(*) FROM public.verificar_bitacora()")" = "0" ] || falla "bitácora"
echo "ok"
