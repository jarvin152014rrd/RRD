#!/usr/bin/env python3
# =====================================================================
# ficha.py  -  Lee, valida y convierte la ficha de un cliente.
# No se usa solo: lo llaman nuevo_cliente.sh, aplicar_ficha.sh y
# lista_clientes.sh.
#
#   python3 ficha.py validar ARCHIVO      JSON válido + personal/ficha.schema.json
#                                         (si python3 tiene jsonschema) + reglas extra
#   python3 ficha.py normalizar ARCHIVO   imprime un JSON con lo que usan las herramientas:
#       cliente, paquete, nombre, empresa_id, conexion, formato,
#       crear   (lo que recibe crear_empresa_inicial)
#       cambios (lo que reciben vista_previa_ficha / aplicar_ficha)
#   python3 ficha.py vista_previa         lee el JSON de vista_previa_ficha (entrada
#                                         estándar) y lo muestra en palabras sencillas
#   python3 ficha.py tabla                lee las filas de lista_clientes.sh y
#                                         dibuja la tabla
#
# Formatos de ficha:
#   2 (actual, clientes/<cliente>/ficha.json): "cliente", "paquete", "negocio",
#     "perfil", "modulos" {nombre: true/false}, "regimen_fiscal", "licencia",
#     "limites", "conexion" (sin clave), "dueno", "proveedor", "tema".
#   1 (de antes, personal/ficha.ejemplo.json): plana, "modulos" como lista.
#     Se sigue aceptando para crear empresas.
# =====================================================================
import json
import os
import sys
import urllib.parse

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ESQUEMA = os.path.join(RAIZ, "personal", "ficha.schema.json")
MODULOS = ["contabilidad", "inventario", "dinero", "ventas", "compras"]   # los que van en "modulos"
REGIMENES = {"ninguno": None, "fiscal_hn": "fiscal_hn"}
CAMPOS_NEGOCIO = ["nombre", "rtn", "rubro", "moneda", "pais", "zona_horaria", "fecha_inicio", "dias_futuro_max"]
LIMITES = ["usuarios", "cajas", "sucursales", "bodegas"]


def error(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def leer(archivo):
    try:
        with open(archivo, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        error("no existe el archivo " + archivo)
    except json.JSONDecodeError as e:
        error("la ficha no es JSON válido (revise comas, comillas y llaves): línea %d, columna %d" % (e.lineno, e.colno))


def es_nueva(f):
    return isinstance(f, dict) and "negocio" in f


def validar(archivo):
    f = leer(archivo)
    try:
        import jsonschema
    except ImportError:
        print("AVISO: python3 no tiene 'jsonschema'; se omite esa revisión (la base valida igual).")
        jsonschema = None
    if jsonschema is not None:
        with open(ESQUEMA, encoding="utf-8") as s:
            esquema = json.load(s)
        errores = sorted(jsonschema.Draft202012Validator(esquema).iter_errors(f), key=lambda e: list(e.path))
        if errores:
            for e in errores:
                campo = ".".join(str(p) for p in e.path) or "(ficha)"
                print("  - %s: %s" % (campo, e.message), file=sys.stderr)
            error("la ficha no cumple personal/ficha.schema.json (ver arriba).")
        print("Ficha revisada contra ficha.schema.json: bien.")
    # Reglas que el esquema no expresa bien.
    if es_nueva(f):
        con = f.get("conexion")
        if con:
            p = urllib.parse.urlsplit(con)
            q = dict(urllib.parse.parse_qsl(p.query))
            if p.password or "password" in q:
                error("la ficha trae la CLAVE de la base en \"conexion\". Quítela: la clave nunca se guarda en archivos.")
        carpeta = os.path.basename(os.path.dirname(os.path.abspath(archivo)))
        if os.path.basename(archivo) == "ficha.json" and carpeta != f.get("cliente"):
            error("la ficha está en la carpeta \"%s\" pero dice \"cliente\": \"%s\". Deben ser iguales." % (carpeta, f.get("cliente")))
    return f


def normalizar(archivo):
    f = leer(archivo)
    if es_nueva(f):
        n = f["negocio"]
        crear = {k: n[k] for k in CAMPOS_NEGOCIO if k in n}
        mods = dict(f.get("modulos") or {})
        mods["contabilidad"] = True
        regimen = REGIMENES.get(f.get("regimen_fiscal") or "ninguno")
        lista = [m for m in MODULOS if mods.get(m)]
        if regimen:
            lista.append(regimen)
        if f.get("perfil") is not None:
            crear["perfil"] = f["perfil"]
        crear["modulos"] = lista
        for k in ("dueno", "proveedor", "tema"):
            if k in f:
                crear[k] = f[k]
        cambios = {"modulos": {m: bool(mods[m]) for m in MODULOS if m in mods}}
        if "regimen_fiscal" in f:
            cambios["modulos"]["fiscal_hn"] = regimen == "fiscal_hn"
        if f.get("perfil") is not None:
            cambios["perfil"] = f["perfil"]
        if f.get("licencia") is not None:
            cambios["licencia"] = f["licencia"]
        if f.get("limites") is not None:
            cambios["limites"] = {k: f["limites"][k] for k in LIMITES if k in f["limites"]}
        salida = {"formato": 2, "cliente": f.get("cliente"), "paquete": f.get("paquete"), "nombre": n.get("nombre"),
                  "empresa_id": n.get("empresa_id"), "conexion": f.get("conexion"), "crear": crear, "cambios": cambios,
                  "licencia": f.get("licencia"), "limites": f.get("limites")}
    else:
        crear = {k: v for k, v in f.items() if k != "$schema"}
        salida = {"formato": 1, "cliente": None, "paquete": None, "nombre": f.get("nombre"), "empresa_id": None,
                  "conexion": None, "crear": crear, "cambios": {}, "licencia": None, "limites": None}
    print(json.dumps(salida, ensure_ascii=False))


def si_no(b):
    return "sí" if b else "no"


def vista_previa():
    v = json.load(sys.stdin)
    print("Empresa: %s (%s)" % (v.get("empresa"), v.get("empresa_id")))
    m = v.get("modulos") or {}
    print("Módulos:")
    print("  activar:    " + (", ".join(m.get("activar") or []) or "(ninguno)"))
    print("  desactivar: " + (", ".join(m.get("desactivar") or []) or "(ninguno)") +
          ("   (solo impide operaciones nuevas; nada se borra)" if m.get("desactivar") else ""))
    print("  quedan activos: " + ", ".join(m.get("quedan_activos") or []))
    p = v.get("perfil")
    print("Perfil: " + ("%s -> %s" % (p.get("actual") or "(sin perfil)", p.get("nuevo")) if p else "sin cambio"))
    if p:
        for c in (p.get("detalle") or {}).get("cambios") or []:
            print("    %s: %s -> %s" % (c.get("campo"), c.get("actual"), c.get("nuevo")))
    lic = v.get("licencia")
    if lic:
        a = lic.get("actual") or {}
        print("Licencia: vence %s (gracia %s días) -> vence %s (gracia %s días)" % (
            a.get("vence_el", "(sin licencia)"), a.get("dias_gracia", "-"), lic["nuevo"]["vence_el"], lic["nuevo"]["dias_gracia"]))
    else:
        print("Licencia: sin cambio")
    hoy = v.get("limites_hoy") or {}
    lims = v.get("limites") or {}
    print("Límites del contrato (uso / límite):")
    for k in LIMITES:
        h = hoy.get(k) or {}
        lim_txt = lambda x: "sin límite" if x is None else str(x)
        linea = "  %-11s %s / %s" % (k, h.get("uso", "?"), lim_txt(h.get("limite")))
        if k in lims:
            linea += "  ->  %s" % lim_txt(lims[k].get("nuevo"))
            if lims[k].get("aviso"):
                linea += "   (" + lims[k]["aviso"] + ")"
        print(linea)
    errores = v.get("errores") or []
    for e in errores:
        print("  PROBLEMA: " + e)
    if not v.get("hay_cambios"):
        print("No hay cambios: la base ya está como dice la ficha.")


def tabla():
    filas = []
    for linea in sys.stdin.read().splitlines():
        if not linea.strip():
            continue
        partes = linea.split("\x1f")
        n = json.loads(partes[0])
        b = json.loads(partes[1]) if len(partes) > 1 and partes[1].strip() else None
        cerca = []
        if b:
            mods = b.get("modulos") or ""
            vence = b.get("vence") or "(sin licencia)"
            nucleo = b.get("nucleo") or "?"
            usos = []
            for k in LIMITES:
                d = (b.get("limites") or {}).get(k)
                if d is None:
                    continue
                lim = d.get("limite")
                usos.append("%s %s/%s" % (k[:3], d.get("uso"), "-" if lim is None else lim))
                if lim is not None and (lim == 0 or d.get("uso", 0) * 100 >= lim * 80):
                    cerca.append(k)
            uso = ", ".join(usos) or "-"
            fuente = "base"
            if b.get("solicitudes"):
                fuente += " (%d solicitud(es))" % b["solicitudes"]
        else:
            c = n.get("cambios") or {}
            mods = ",".join(sorted(k for k, x in (c.get("modulos") or {}).items() if x)) or "-"
            vence = (n.get("licencia") or {}).get("vence_el") or "-"
            nucleo = "?"
            lims = n.get("limites") or {}
            uso = ", ".join("%s ?/%s" % (k[:3], "-" if lims.get(k) is None else lims[k]) for k in LIMITES if k in lims) or "-"
            fuente = "ficha (sin acceso a la base)"
        filas.append([("(!) " if cerca else "") + (n.get("cliente") or "?"), n.get("paquete") or "-", mods, vence, nucleo, uso, fuente])
    enc = ["CLIENTE", "PAQUETE", "MÓDULOS", "VENCE", "NÚCLEO", "USO/LÍMITE", "FUENTE"]
    anchos = [max(len(str(x[i])) for x in filas + [enc]) for i in range(len(enc))]
    print("  ".join(enc[i].ljust(anchos[i]) for i in range(len(enc))))
    for x in filas:
        print("  ".join(str(x[i]).ljust(anchos[i]) for i in range(len(enc))))
    if any(x[0].startswith("(!)") for x in filas):
        print("(!) = usa el 80 %% o más de algún límite: ofrézcale una ampliación.")
    print("Clientes: %d" % len(filas))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        error("uso: ficha.py validar|normalizar ARCHIVO  |  ficha.py vista_previa|tabla")
    accion = sys.argv[1]
    if accion == "validar" and len(sys.argv) == 3:
        validar(sys.argv[2])
    elif accion == "normalizar" and len(sys.argv) == 3:
        normalizar(sys.argv[2])
    elif accion == "vista_previa":
        vista_previa()
    elif accion == "tabla":
        tabla()
    else:
        error("uso: ficha.py validar|normalizar ARCHIVO  |  ficha.py vista_previa|tabla")
