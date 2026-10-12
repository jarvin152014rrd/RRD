#!/usr/bin/env bash
# =====================================================================
# armar_instalacion.sh  -  Arma el paquete SQL para instalar el núcleo en un
# proyecto REAL de Supabase pegándolo en el SQL Editor (sin terminal).
#
#   bash herramientas/armar_instalacion.sh [carpeta_destino]
#
# Deja en dist/ (o la carpeta indicada; dist/ no va a git):
#   instalar_supabase_parte01.sql ... parteNN.sql   las migraciones 001-0NN en
#        orden, partes de hasta MAX_KB (defecto 200 KB) para pegar una por una
#   verificar_instalacion.sql   consulta: versión, migraciones y "TODO BIEN"
#   LEEME.txt                   el orden y qué hacer (detalle: docs/SUPABASE.md)
#
# Cada parte:
#   * revisa antes que sea Supabase (esquema auth y roles anon/authenticated/
#     service_role ya existen; NO los crea), que se corra con el rol postgres,
#     que la parte anterior ya esté y que la base no tenga un núcleo más nuevo;
#   * aplica cada migración UNA vez: si ya está en interno._migraciones con la
#     misma huella (sha256 del archivo, igual que migrar.sh) la salta; si está
#     con otra huella, se detiene (las migraciones no se editan);
#   * es todo-o-nada: el SQL Editor manda el texto en una sola petición y
#     PostgreSQL lo corre en una sola transacción; si algo falla no queda nada
#     a medias y se puede volver a correr;
#   * avisa a la API (PostgREST) que recargue el esquema.
# Sin nada del simulador local: no crea roles, ni el esquema auth, ni auth.uid().
#
# Después de instalar así, migrar.sh también reconoce la base (misma tabla y
# misma huella), por si luego se actualiza por terminal.
# Variable opcional: MAX_KB (tamaño máximo de cada parte, defecto 200).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DESTINO="${1:-$RAIZ/dist}"
case "${1:-}" in -h|--ayuda) sed -n '2,31p' "$0"; exit 0 ;; esac
MAX_KB="${MAX_KB:-200}"
mkdir -p "$DESTINO"
rm -f "$DESTINO"/instalar_supabase_parte[0-9][0-9].sql

python3 - "$RAIZ" "$DESTINO" "$MAX_KB" <<'PY'
import glob, hashlib, os, re, sys

raiz, destino, max_kb = sys.argv[1], sys.argv[2], int(sys.argv[3])
version = open(os.path.join(raiz, "VERSION_NUCLEO")).read().strip()
archivos = sorted(glob.glob(os.path.join(raiz, "nucleo", "sql", "migraciones", "[0-9][0-9][0-9]_*.sql")))
if not archivos:
    sys.exit("ERROR: no hay migraciones.")
ultima = int(os.path.basename(archivos[-1])[:3])
total = len(archivos)
if [int(os.path.basename(a)[:3]) for a in archivos] != list(range(1, total + 1)):
    sys.exit("ERROR: los números de las migraciones no son seguidos desde 001.")

def bloque(archivo):
    """Una migración envuelta: se aplica solo si falta, y se registra con su huella."""
    datos = open(archivo, "rb").read()
    suma = hashlib.sha256(datos).hexdigest()
    texto = datos.decode("utf-8")
    nombre = os.path.basename(archivo)[:-4]
    n = int(nombre[:3])
    tag_m, tag_d = "$mig_%03d$" % n, "$instalar_%03d$" % n
    if tag_m in texto or tag_d in texto:
        sys.exit("ERROR: %s contiene la marca %s; cámbiela en el generador." % (nombre, tag_m))
    return f"""
-- ---------------------------------------------------------------------
-- Migración {nombre}
-- ---------------------------------------------------------------------
DO {tag_d}
DECLARE v_previa text;
BEGIN
  IF to_regclass('interno._migraciones') IS NOT NULL THEN
    EXECUTE 'SELECT checksum FROM interno._migraciones WHERE numero = $1' INTO v_previa USING {n};
  END IF;
  IF v_previa = '{suma}' THEN
    RAISE NOTICE 'Ya estaba instalada: {nombre}';
    RETURN;
  ELSIF v_previa IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRACION_DISTINTA: la migración {nombre} ya está instalada pero con otro contenido. No se cambió nada. Avise a su proveedor.';
  END IF;
  EXECUTE {tag_m}{texto}{tag_m};
  INSERT INTO interno._migraciones (numero, nombre, checksum, version_nucleo)
  VALUES ({n}, '{nombre}', '{suma}', '{version}');
END {tag_d};
""", n

bloques = [bloque(a) for a in archivos]

# Partes: se juntan migraciones seguidas mientras quepan en MAX_KB.
limite = max_kb * 1024 - 6000          # espacio para el encabezado y el final
partes, actual, tam = [], [], 0
for texto, n in bloques:
    t = len(texto.encode("utf-8"))
    if actual and tam + t > limite:
        partes.append(actual); actual, tam = [], 0
    actual.append((texto, n)); tam += t
if actual:
    partes.append(actual)
cuantas = len(partes)

for i, parte in enumerate(partes, 1):
    desde, hasta = parte[0][1], parte[-1][1]
    previa = desde - 1
    revisar_anterior = "" if previa == 0 else f"""
  -- (con IF separados: si la tabla aún no existe, la consulta ni se prepara)
  IF to_regclass('interno._migraciones') IS NULL THEN
    v_falta := true;
  ELSE
    EXECUTE 'SELECT NOT EXISTS (SELECT 1 FROM interno._migraciones WHERE numero = {previa})' INTO v_falta;
  END IF;
  IF v_falta THEN
    RAISE EXCEPTION 'FALTA_PARTE_ANTERIOR: primero corra la parte {i - 1:02d} (instalar_supabase_parte{i - 1:02d}.sql). No se cambió nada.';
  END IF;"""
    cabeza = f"""-- =====================================================================
-- instalar_supabase_parte{i:02d}.sql  -  Núcleo {version}, parte {i} de {cuantas}
-- Migraciones {desde:03d} a {hasta:03d}.
--
-- CÓMO: Supabase > SQL Editor > New query > pegue TODO este archivo > Run.
-- Debe salir abajo una tabla con "Parte {i} de {cuantas} lista".
-- Si sale un error en rojo, no quedó nada a medias: lea el mensaje y vea
-- docs/SUPABASE.md, "Qué hacer si algo falla". Se puede volver a correr.
-- (Generado por herramientas/armar_instalacion.sh; no lo edite a mano.)
-- =====================================================================

DO $revisar$
DECLARE v_falta boolean;
  v_nueva boolean := false;
BEGIN
  IF current_user IN ('anon', 'authenticated', 'service_role') THEN
    RAISE EXCEPTION 'ROL_EQUIVOCADO: en el SQL Editor elija el rol "postgres" (arriba a la derecha) y vuelva a correr.';
  END IF;
  IF to_regclass('auth.users') IS NULL OR to_regprocedure('auth.uid()') IS NULL
     OR (SELECT count(*) FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role')) <> 3 THEN
    RAISE EXCEPTION 'NO_ES_SUPABASE: esta base no tiene Supabase Auth (esquema auth y roles). Use un proyecto de Supabase.';
  END IF;
  IF to_regclass('interno._migraciones') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM interno._migraciones WHERE numero > {ultima})' INTO v_nueva;
  END IF;
  IF v_nueva THEN
    RAISE EXCEPTION 'PAQUETE_VIEJO: la base ya tiene un núcleo más nuevo que este paquete ({version}). No se cambió nada.';
  END IF;{revisar_anterior}
END $revisar$;
"""
    pie = f"""
-- Avisar a la API de Supabase que hay funciones nuevas.
NOTIFY pgrst, 'reload schema';

SELECT 'Parte {i} de {cuantas} lista' AS resultado,
       (SELECT max(numero) FROM interno._migraciones) AS ultima_migracion,
       '{"Siga con la parte %02d" % (i + 1) if i < cuantas else "Terminó. Corra verificar_instalacion.sql"}' AS siguiente;
"""
    ruta = os.path.join(destino, "instalar_supabase_parte%02d.sql" % i)
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(cabeza + "".join(t for t, _ in parte) + pie)
    kb = os.path.getsize(ruta) / 1024
    aviso = "  (AVISO: más grande que %d KB: una sola migración no se parte)" % max_kb if kb > max_kb else ""
    print("  %s  migraciones %03d-%03d  %.0f KB%s" % (os.path.basename(ruta), desde, hasta, kb, aviso))

with open(os.path.join(destino, "verificar_instalacion.sql"), "w", encoding="utf-8") as f:
    f.write(f"""-- verificar_instalacion.sql  -  ¿Quedó bien instalado el núcleo {version}?
-- Supabase > SQL Editor > New query > pegue esto > Run.
SELECT CASE WHEN count(*) = {total} AND max(numero) = {ultima}
                 AND (SELECT version_nucleo FROM public.version_esquema) = '{version}'
            THEN 'TODO BIEN' ELSE 'FALTAN PARTES: corra las que faltan, en orden' END AS resultado,
       (SELECT version_nucleo FROM public.version_esquema) AS version,
       count(*) AS migraciones,
       {total} AS migraciones_esperadas
FROM interno._migraciones;
""")

with open(os.path.join(destino, "LEEME.txt"), "w", encoding="utf-8") as f:
    f.write(f"""Instalación del núcleo {version} en Supabase ({cuantas} partes, {total} migraciones).
Guía completa paso a paso: docs/SUPABASE.md

1. Supabase > SQL Editor > New query.
2. Pegue instalar_supabase_parte01.sql completo > Run > debe decir "Parte 1 de {cuantas} lista".
3. Repita con cada parte EN ORDEN hasta la {cuantas:02d}.
4. Pegue verificar_instalacion.sql > Run > debe decir TODO BIEN y versión {version}.
5. (Opcional) primer cliente: instalar_supabase_primer_cliente_<cliente>.sql
   (lo arma herramientas/exportar_supabase.sh o el Armador > Clientes > Exportar para Supabase).
Si una parte da error, no queda nada a medias; vea "Qué hacer si algo falla" en docs/SUPABASE.md.
""")
print("Listo: %d partes del núcleo %s en %s" % (cuantas, version, destino))
PY
