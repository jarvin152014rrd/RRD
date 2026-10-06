"""FASE 1: revisa el portal público y propone la verificación.

No inicia sesión, no abre PDF y no envía nada. Solo lee las tablas, con pausas
largas para que el portal no bloquee, y deja un Excel en la carpeta resultados.
Puede revisar una institución o varias seguidas (lista en instituciones.txt).
"""
import json
import os
import random
import re
import sys
import time
from datetime import date, datetime
from pathlib import Path

import openpyxl
from openpyxl.cell.cell import ILLEGAL_CHARACTERS_RE
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.worksheet.datavalidation import DataValidation
from playwright.sync_api import sync_playwright

import analisis
import documentos
import ia
from comun import MESES, aplicar_documentos, evaluar, mes_a_numero, normalizar
from documentos import Bloqueado

PRUEBA = "PORTAL_PRUEBA" in os.environ  # solo para pruebas locales
PORTAL = os.environ.get("PORTAL_PRUEBA", "https://portalunico.iaip.gob.hn")
PAUSA = (0, 0) if PRUEBA else (10, 20)  # segundos entre páginas
PAUSA_INSTITUCION = (0, 0) if PRUEBA else (60, 120)  # segundos entre instituciones
CARPETA = Path(__file__).parent
RESULTADOS = CARPETA / "resultados"
LISTA = CARPETA / "instituciones.txt"
RESPUESTAS = RESULTADOS / "ultimas_respuestas.json"
DECISIONES = ["Cumple", "No cumple", "No aplica"]
DOCUMENTOS = RESULTADOS / "documentos"


# ---------- preguntas ----------

def preguntar(texto, defecto=""):
    r = input(f"{texto}{f' [{defecto}]' if defecto != '' else ''}: ").strip()
    return r or str(defecto)


def pedir_numero(texto, defecto, minimo, maximo):
    while True:
        r = preguntar(texto, defecto)
        if r.isdigit() and minimo <= int(r) <= maximo:
            return int(r)
        print(f"   Escribe un número entre {minimo} y {maximo}.")


def sector_de(texto):
    t = (texto or "").strip().upper()
    if t.startswith("M"):
        return "municipalidad"
    if t.startswith("I"):
        return "institucion"
    return ""  # se detecta por el nombre de la institución


def leer_json(ruta, defecto):
    if not ruta.exists():
        return defecto
    try:
        return json.loads(ruta.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # Archivo dañado (por ejemplo, un corte de luz): se guarda aparte, no se borra.
        copia = ruta.with_name(ruta.stem + datetime.now().strftime("_danado_%Y%m%d_%H%M%S.json"))
        ruta.replace(copia)
        print(f"   Aviso: {ruta.name} estaba dañado; se guardó como {copia.name}.")
        return defecto


def guardar_json(ruta, datos):
    """Escribe primero un archivo temporal y luego lo cambia de nombre (no queda a medias)."""
    tmp = ruta.with_suffix(".tmp")
    tmp.write_text(json.dumps(datos, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(ruta)


def leer_lista():
    """instituciones.txt: una línea por institución -> número ; M o I ; desde (opcional)."""
    filas = []
    if not LISTA.exists():
        return filas
    for linea in LISTA.read_text(encoding="utf-8").splitlines():
        linea = linea.split("#")[0].strip()
        if not linea:
            continue
        partes = [p.strip() for p in linea.split(";")]
        if not partes[0].isdigit():
            print(f"   Línea ignorada en instituciones.txt: '{linea}'")
            continue
        desde = partes[2] if len(partes) > 2 and partes[2].isdigit() else ""
        filas.append({"id": partes[0], "sector": sector_de(partes[1] if len(partes) > 1 else ""),
                      "desde": int(desde) if desde else None})
    return filas


# ---------- historial (para comparar con la verificación anterior) ----------

def ruta_historial(id_inst):
    return RESULTADOS / f"historial_{id_inst}.json"


def verificacion_anterior(id_inst, anio, mes):
    """La última verificación completa antes de (anio, mes)."""
    previas = [h for h in leer_json(ruta_historial(id_inst), [])
               if (h["anio"], h["mes"]) < (anio, mes)]
    return max(previas, key=lambda h: (h["anio"], h["mes"])) if previas else None


def desde_sugerido(id_inst, anio, mes):
    previa = verificacion_anterior(id_inst, anio, mes)
    if previa and previa["anio"] < anio:
        return 1  # la anterior fue de otro año: se revisa desde enero
    if previa and previa["mes"] < mes:
        return previa["mes"] + 1
    return mes


def guardar_historial(id_inst, anio, mes, lectura):
    hist = [h for h in leer_json(ruta_historial(id_inst), [])
            if (h["anio"], h["mes"]) != (anio, mes)]
    hist.append({"anio": anio, "mes": mes, "fecha": datetime.now().isoformat(timespec="minutes"),
                 "enlaces": {url: [f["enlace"] for f in d["datos"]["filas"]]
                             for url, d in lectura["leido"].items()}})
    guardar_json(ruta_historial(id_inst), hist)


# ---------- navegador ----------

def revisar_bloqueo(page):
    """Para todo si el portal muestra el bloqueo; espera si pide verificar que es humano."""
    for _ in range(60):
        titulo = normalizar(page.title())
        cuerpo = normalizar(page.inner_text("body")[:2000])
        if "error 1015" in cuerpo or "rate limited" in cuerpo or "access denied" in titulo:
            raise Bloqueado("El portal está limitando el acceso (Error 1015).")
        if "just a moment" in titulo or "un momento" in titulo or "verify you are human" in cuerpo:
            print("   El portal pide verificar que eres humano. Resuélvelo en la ventana de Chrome...")
            time.sleep(5)
            continue
        return
    raise Bloqueado("No se pasó la verificación de Cloudflare.")


def abrir(page, url):
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    revisar_bloqueo(page)
    try:
        page.wait_for_load_state("networkidle", timeout=15000)
    except Exception:
        pass  # algunas páginas nunca quedan quietas; seguimos con lo cargado


def esperar(rango, texto=""):
    segundos = random.uniform(*rango)
    if texto:
        print(f"{texto} (esperando {segundos:.0f} s)")
    time.sleep(segundos)


def listar_apartados(page, id_inst):
    """Lee el menú de la izquierda: nombre del apartado, su número y su enlace."""
    enlaces = page.eval_on_selector_all(
        "a[href]", "els => els.map(e => [e.innerText.trim(), e.href])")
    patron = re.compile(rf"/{id_inst}/(\d+)/?$")
    vistos, apartados = set(), []
    for texto, href in enlaces:
        m = patron.search(href.split("?")[0])
        if m and texto and href not in vistos:
            vistos.add(href)
            apartados.append({"nombre": " ".join(texto.split()), "numero": int(m.group(1)),
                              "url": href})
    return apartados


MOSTRAR_TODO = """() => {
  // Si la tabla usa DataTables, se piden todas las filas en una sola página.
  try {
    if (window.jQuery && jQuery.fn.dataTable) {
      jQuery('table').each(function () {
        if (jQuery.fn.dataTable.isDataTable(this)) jQuery(this).DataTable().page.len(-1).draw();
      });
    }
  } catch (e) {}
}"""

LEER_TABLA = """() => {
  for (const t of document.querySelectorAll('table')) {
    const cab = [...t.querySelectorAll('thead th, tr:first-child th')].map(th => th.innerText.trim().toLowerCase());
    if (!cab.some(c => c.startsWith('mes')) || !cab.some(c => c.startsWith('a'))) continue;
    const filas = [];
    for (const tr of t.querySelectorAll('tbody tr')) {
      const td = [...tr.querySelectorAll('td')];
      if (td.length < 3) continue;
      const fila = {};
      cab.forEach((c, i) => { fila[c] = td[i] ? td[i].innerText.trim() : ''; });
      const a = tr.querySelector('a[href]');
      fila._enlace = a ? a.href : '';
      filas.push(fila);
    }
    if (filas.length) return filas;
  }
  return [];
}"""


def total_portal(texto):
    """Lee 'Mostrando 1 a 10 de 25 registros' para saber cuántos documentos hay en total."""
    m = re.search(r"de\s+([\d.,]+)\s+(registros|entradas|resultados)", texto, re.I)
    return int(re.sub(r"[.,]", "", m.group(1))) if m else None


def leer_apartado(page):
    page.evaluate(MOSTRAR_TODO)
    time.sleep(2)
    filas = []
    for f in page.evaluate(LEER_TABLA):
        def col(*inicios):
            for k, v in f.items():
                if any(normalizar(k).startswith(i) for i in inicios):
                    return v
            return ""
        filas.append({"nombre": col("nombre"), "descripcion": col("descrip"),
                      "subido": col("subido"), "anio": col("ano", "año"),
                      "mes": col("mes"), "enlace": f.get("_enlace", "")})
    texto = page.inner_text("body")
    fa = re.search(r"Fecha de Actualizaci[oó]n:[ \t]*([^\n]+)", texto)
    pe = re.search(r"Periodo de Actualizaci[oó]n:[ \t]*([^\n]+)", texto)
    # Texto editable: lo que está entre el título y la tabla (por ejemplo "FONAC NO APLICA").
    area = texto.split("Fecha de Actualizaci")[0][-300:] if fa else ""
    return {"filas": filas,
            "fecha_actualizacion": fa.group(1).strip() if fa else "",
            "periodo_portal": pe.group(1).strip().rstrip(".") if pe else "",
            "texto_area": area,
            "total_portal": total_portal(texto)}


def nombre_institucion(page, id_inst):
    """El nombre sale del enlace de la ruta 'Inicio / Nombre' o de un título con siglas."""
    enlaces = page.eval_on_selector_all(
        "a[href]", "els => els.map(e => [e.innerText.trim(), e.href])")
    for texto, href in enlaces:
        texto = " ".join(texto.split())
        if re.search(rf"/{id_inst}/?$", href.split("?")[0]) and texto and \
                normalizar(texto) not in ("inicio", "") and len(texto) > 5:
            return texto
    titulo = re.search(r"^\s*(.+\([A-Z]{2,}\))\s*$", page.inner_text("body"), re.M)
    return titulo.group(1).strip() if titulo else ""


def leer_institucion(page, cfg, lectura, ruta_lectura):
    """Lee del portal lo que falte y lo va guardando. Devuelve True si quedó completa."""
    id_inst = cfg["id"]
    if not lectura.get("apartados"):
        print("\nAbriendo la portada de la institución...")
        for url in (f"{PORTAL}/{id_inst}/", f"{PORTAL}/{id_inst}/7/"):
            abrir(page, url)
            lectura["apartados"] = listar_apartados(page, id_inst)
            if lectura["apartados"]:
                break
            esperar(PAUSA)
        nombre = nombre_institucion(page, id_inst)
        if nombre:
            lectura["institucion"] = nombre
        guardar_json(ruta_lectura, lectura)
    print(f"{lectura['institucion']}: {len(lectura['apartados'])} apartados en el menú.")
    if not lectura["apartados"]:
        print("No se encontró el menú de apartados. Revisa el número de institución.")
        return False

    apartados = lectura["apartados"][:cfg["limite"]] if cfg["limite"] else lectura["apartados"]
    for i, ap in enumerate(apartados, 1):
        if ap["url"] in lectura["leido"]:
            continue
        esperar(PAUSA, f"[{i}/{len(apartados)}] {ap['nombre']}")
        try:
            abrir(page, ap["url"])
            datos = leer_apartado(page)
        except Bloqueado:
            raise
        except Exception as e:  # un apartado con problema no detiene a los demás
            lectura.setdefault("errores", {})[ap["url"]] = str(e)
            print(f"     -> No se pudo leer: {e}")
            continue
        lectura.get("errores", {}).pop(ap["url"], None)
        lectura["leido"][ap["url"]] = {"datos": datos,
                                       "leido_en": datetime.now().isoformat(timespec="minutes")}
        guardar_json(ruta_lectura, lectura)
        print(f"     -> {len(datos['filas'])} documentos leídos")
    guardar_json(ruta_lectura, lectura)
    return not cfg["limite"] and len(lectura["leido"]) == len(lectura["apartados"])


# ---------- propuesta ----------

def buscar_regla(reglas, sector, nombre):
    n = normalizar(nombre)
    for r in reglas:
        if r["sector"] == sector and n in r["alias"]:
            return r
    return None


def detectar_sector(cfg, lectura):
    """Devuelve (sector, supuesto). 'supuesto' = no se pudo leer el nombre."""
    if cfg["sector"]:
        return cfg["sector"], False
    nombre = normalizar(lectura["institucion"])
    if "municipal" in nombre or "alcaldia" in nombre:
        return "municipalidad", False
    return "institucion", nombre.startswith("institucion ")


def calcular(reglas, cfg, lectura, sector, supuesto, previa, docs=None):
    """Vuelve a calcular la propuesta con lo guardado (sin abrir el portal)."""
    docs = docs or {}
    resultados = []
    apartados = lectura["apartados"][:cfg["limite"]] if cfg["limite"] else lectura["apartados"]
    for ap in apartados:
        base = {"apartado": ap["nombre"], "numero": ap["numero"], "url": ap["url"],
                "regla": None, "nuevos": None, "filas": []}
        if ap["url"] not in lectura["leido"]:
            error = lectura.get("errores", {}).get(ap["url"], "No se llegó a leer (bloqueo o pausa).")
            base.update({"propuesta": "No se pudo revisar", "periodicidad": "", "encontrados": [],
                         "faltantes": [], "quitar": [], "observacion": "",
                         "alertas": [f"No se pudo leer la página: {error}"],
                         "fecha_actualizacion": ""})
            resultados.append(base)
            continue
        datos = lectura["leido"][ap["url"]]["datos"]
        regla = buscar_regla(reglas, sector, ap["nombre"])
        res = evaluar(regla, datos, cfg["anio"], cfg["mes"], cfg["desde"])
        anteriores = set(previa["enlaces"].get(ap["url"], [])) if previa else None
        filas = [dict(f, nuevo=(f["enlace"] not in anteriores) if anteriores is not None else None)
                 for f in datos["filas"]]
        if ap["url"] in docs:
            res = aplicar_documentos(res, docs[ap["url"]]["docs"], ap["nombre"], sector,
                                     docs[ap["url"]]["comparacion"])
            if docs[ap["url"]]["excedio"]:
                res["alertas"].append(f"Hay más de {documentos.MAX_POR_APARTADO} documentos para "
                                      "revisar; se revisaron los primeros. Mirar el resto a mano.")
        base.update(res, regla=regla["apartado"] if regla else None,
                    fecha_actualizacion=datos["fecha_actualizacion"], filas=filas,
                    nuevos=sum(1 for f in filas if f["nuevo"]) if previa else None)
        resultados.append(base)
    if supuesto:
        print("   Aviso: no se leyó el nombre; se usan reglas de Institución. Si es "
              "Municipalidad, vuelve a correrlo y responde M.")
        for r in resultados:
            r["alertas"].append("No se leyó el nombre de la institución: se usaron reglas de "
                                "Institución. Si es Municipalidad, vuelve a correrlo con M.")
    return resultados


# ---------- documentos (Fase 3) ----------

def ruta_docs(cfg):
    return DOCUMENTOS / str(cfg["id"])


def bajar_documentos(page, reglas, cfg, lectura, sector, previa):
    """Elige los documentos nuevos y del periodo de cada apartado y los descarga."""
    carpeta = ruta_docs(cfg)
    carpeta.mkdir(parents=True, exist_ok=True)
    ruta_registro = carpeta / "registro.json"
    registro = leer_json(ruta_registro, {})
    elegidos, pendientes = {}, []
    apartados = lectura["apartados"][:cfg["limite"]] if cfg["limite"] else lectura["apartados"]
    for ap in apartados:
        if ap["url"] not in lectura["leido"]:
            continue
        regla = buscar_regla(reglas, sector, ap["nombre"])
        perio = regla["periodicidad"] if regla else "cuando_cambie"
        anteriores = set(previa["enlaces"].get(ap["url"], [])) if previa else None
        filas, excedio = documentos.seleccionar(lectura["leido"][ap["url"]]["datos"]["filas"], perio,
                                                cfg["anio"], cfg["desde"], cfg["mes"], anteriores)
        elegidos[ap["url"]] = {"enlaces": [f["enlace"] for f in filas], "excedio": excedio}
        pendientes += [f for f in filas if not registro.get(f["enlace"], {}).get("archivo")]
    lectura["documentos"] = elegidos
    print(f"\nDocumentos a revisar: {sum(len(e['enlaces']) for e in elegidos.values())} "
          f"({len(pendientes)} por descargar).")
    documentos.descargar_pendientes(page, pendientes, carpeta, registro,
                                    lambda: guardar_json(ruta_registro, registro))


def reunir_documentos(reglas, cfg, lectura, sector):
    """Junta, por apartado, cada documento con su descarga, su lectura local y lo de la IA."""
    elegidos = lectura.get("documentos") or {}
    if not elegidos:
        return {}
    carpeta = ruta_docs(cfg)
    registro = leer_json(carpeta / "registro.json", {})
    cache_ia = leer_json(carpeta / "ia.json", {})
    salida = {}
    for ap in lectura["apartados"]:
        if ap["url"] not in elegidos or ap["url"] not in lectura["leido"]:
            continue
        por_enlace = {f["enlace"]: f for f in lectura["leido"][ap["url"]]["datos"]["filas"]}
        docs = []
        for enlace in elegidos[ap["url"]]["enlaces"]:
            fila = por_enlace.get(enlace, {"enlace": enlace})
            descarga = registro.get(enlace) or {"pendiente": True}
            local = None
            if descarga.get("archivo"):
                local = analisis.analizar(carpeta / descarga["archivo"], descarga["tipo"], fila,
                                          sector, ap["nombre"])
            docs.append({"fila": fila, "descarga": descarga, "local": local,
                         "ia": cache_ia.get(descarga.get("sha", ""))})
        salida[ap["url"]] = {"docs": docs, "comparacion": comparar_en_apartado(docs),
                             "excedio": elegidos[ap["url"]].get("excedio")}
    return salida


def comparar_en_apartado(docs):
    """Si en el mismo mes hay un Excel y un PDF, revisa que vayan en el mismo orden."""
    por_mes = {}
    for d in docs:
        local = d.get("local") or {}
        if local.get("error") or not local.get("tipo"):
            continue
        clave = (str(d["fila"].get("anio")), mes_a_numero(d["fila"].get("mes", "")))
        por_mes.setdefault(clave, {}).setdefault("excel" if local["tipo"] in ("xlsx", "xls") else "pdf", local)
    for grupo in por_mes.values():
        if "excel" in grupo and "pdf" in grupo:
            return analisis.comparar_excel_pdf(grupo["excel"], grupo["pdf"])
    return None


def usar_ia(cfg, docs, lectura, sector, reglas, preguntar_si_existe):
    """Manda a la IA los PDF que aún no tiene revisados, con confirmación y tope de gasto."""
    conf = ia.cargar_config()
    ok, motivo = ia.disponible(conf)
    if not ok:
        print(f"IA: no se usa ({motivo}).")
        return 0.0
    carpeta = ruta_docs(cfg)
    ruta_cache = carpeta / "ia.json"
    cache = leer_json(ruta_cache, {})
    pendientes = []
    for url, info in docs.items():
        nombre_ap = next(a["nombre"] for a in lectura["apartados"] if a["url"] == url)
        for d in info["docs"]:
            local, sha = d.get("local") or {}, d["descarga"].get("sha")
            if sha and local.get("tipo") == "pdf" and not local.get("error") and \
                    not (cache.get(sha) or {}).get("resultado"):
                pendientes.append((nombre_ap, d))
    if not pendientes:
        return 0.0
    estimado = sum(ia.estimar_usd(conf, d["local"]["paginas"]) for _, d in pendientes)
    tope = float(conf["tope_usd_por_corrida"])
    print(f"\nIA: {len(pendientes)} PDF por revisar. Costo aproximado US${estimado:.2f} "
          f"(tope por corrida US${tope:.2f}).")
    if preguntar_si_existe and not preguntar("¿Enviarlos a la IA? (S/N)", "S").upper().startswith("S"):
        return 0.0
    cliente = ia.crear_cliente()
    gastado = 0.0
    for i, (nombre_ap, d) in enumerate(pendientes, 1):
        if gastado + ia.estimar_usd(conf, d["local"]["paginas"]) > tope:
            print(f"   Se llegó al tope de gasto (US${tope:.2f}). Los demás quedan pendientes.")
            break
        fila = d["fila"]
        print(f"   IA {i}/{len(pendientes)}: {fila.get('descripcion') or fila.get('nombre')}")
        ctx = {"institucion": lectura["institucion"], "sector": sector, "apartado": nombre_ap,
               "regla": buscar_regla(reglas, sector, nombre_ap), "fila": fila,
               "anio": cfg["anio"], "mes": cfg["mes"]}
        salida = ia.revisar(cliente, conf, ruta_docs(cfg) / d["descarga"]["archivo"], d["local"], ctx)
        gastado += salida["costo_usd"]
        d["ia"] = salida
        if salida["resultado"]:  # los errores se reintentan la próxima vez
            cache[d["descarga"]["sha"]] = salida
            guardar_json(ruta_cache, cache)
        print(f"     -> {'error: ' + salida['error'] if salida['error'] else 'revisado'} "
              f"(US${salida['costo_usd']:.3f})")
    print(f"IA: gasto de esta corrida US${gastado:.2f}.")
    return gastado


# ---------- Excel ----------

def limpiar(valor):
    """Quita caracteres que Excel no acepta y evita que un texto se vuelva fórmula."""
    if not isinstance(valor, str):
        return valor
    valor = ILLEGAL_CHARACTERS_RE.sub("", valor)
    return " " + valor if valor.startswith("=") else valor


def agregar(ws, fila):
    ws.append([limpiar(v) for v in fila])


def encabezado(ws, fila=1, color="2E7D32"):
    for c in ws[fila]:
        c.font = Font(bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor=color)
        c.alignment = Alignment(wrap_text=True, vertical="center")


def ruta_libre(ruta):
    """Nunca reemplaza un Excel que ya existe (puede tener tus notas)."""
    if not ruta.exists():
        return ruta
    return ruta.with_name(ruta.stem + datetime.now().strftime("_%Y%m%d_%H%M%S") + ruta.suffix)


def guardar_excel(cfg, lectura, sector, previa, resultados, docs=None):
    anio, mes = cfg["anio"], cfg["mes"]
    institucion = lectura["institucion"]
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Propuesta"
    comparacion = (f"comparado con la verificación de {MESES[previa['mes'] - 1]} {previa['anio']}"
                   if previa else "sin verificación anterior para comparar")
    agregar(ws, [f"{institucion} — verificación de {MESES[mes - 1]} {anio} "
                 f"(desde {MESES[cfg['desde'] - 1]}) — {sector} — {comparacion}"])
    ws["A1"].font = Font(bold=True, size=13)
    agregar(ws, ["N°", "Apartado", "Periodicidad", "Fecha editable (portal)", "Encontrados",
                 "Faltantes", "Docs nuevos", "PROPUESTA", "Quitar casillas",
                 "Observación propuesta", "Alertas", "DECISIÓN FINAL", "QUITAR FINAL",
                 "OBSERVACIÓN FINAL (para Recomendaciones)", "Enlace"])
    encabezado(ws, 2)
    for col in ("L", "M", "N"):  # las columnas que corrige el verificador
        ws[f"{col}2"].fill = PatternFill("solid", fgColor="1565C0")
    colores = {"Cumple": "C8E6C9", "No cumple": "FFCDD2", "Revisar": "FFF59D",
               "No aplica": "E0E0E0", "No se pudo revisar": "FFAB91", "Sin calificar": "FFAB91"}
    lista = DataValidation(type="list", formula1='"' + ",".join(DECISIONES) + '"', allow_blank=True)
    ws.add_data_validation(lista)
    for r in resultados:
        final = r["propuesta"] if r["propuesta"] in DECISIONES else ""
        agregar(ws, [r["numero"], r["apartado"], r["periodicidad"], r["fecha_actualizacion"],
                     ", ".join(r["encontrados"]), ", ".join(r["faltantes"]),
                     "" if r["nuevos"] is None else r["nuevos"], r["propuesta"],
                     ", ".join(r["quitar"]), r["observacion"], "\n".join(r["alertas"]),
                     final, ", ".join(r["quitar"]) if final else "",
                     r["observacion"] if final else "", r["url"]])
        fila = ws.max_row
        ws.cell(fila, 8).fill = PatternFill("solid", fgColor=colores.get(r["propuesta"], "FFFFFF"))
        lista.add(f"L{fila}")
    for col, ancho in zip("ABCDEFGHIJKLMNO",
                          (6, 32, 14, 18, 26, 26, 10, 16, 18, 60, 45, 16, 18, 60, 35)):
        ws.column_dimensions[col].width = ancho
    for fila in ws.iter_rows(min_row=3):
        for c in fila:
            c.alignment = Alignment(wrap_text=True, vertical="top")
    ws.freeze_panes = "C3"

    wa = wb.create_sheet("Alertas")
    agregar(wa, ["Institución", "N°", "Apartado", "Motivo"])
    encabezado(wa)
    for r in resultados:
        for a in r["alertas"]:
            agregar(wa, [institucion, r["numero"], r["apartado"], a])
    for col, ancho in zip("ABCD", (30, 6, 32, 90)):
        wa.column_dimensions[col].width = ancho

    wd = wb.create_sheet("Documentos")
    agregar(wd, ["N°", "Apartado", "Nuevo", "Nombre", "Descripción", "Subido", "Año", "Mes", "Enlace"])
    encabezado(wd)
    for r in resultados:
        for f in r["filas"]:
            nuevo = "" if f.get("nuevo") is None else ("Sí" if f["nuevo"] else "")
            agregar(wd, [r["numero"], r["apartado"], nuevo, f["nombre"], f["descripcion"],
                         f["subido"], f["anio"], f["mes"], f["enlace"]])
    for col, ancho in zip("ABCDEFGHI", (6, 30, 7, 28, 60, 12, 7, 12, 40)):
        wd.column_dimensions[col].width = ancho

    hoja_documentos(wb, resultados, docs or {})

    wsr = wb.create_sheet("Sin regla")
    agregar(wsr, ["N°", "Apartado del menú que no está en el checklist", "Enlace"])
    encabezado(wsr)
    for r in resultados:
        if r["regla"] is None and r["propuesta"] != "No se pudo revisar":
            agregar(wsr, [r["numero"], r["apartado"], r["url"]])
    wsr.column_dimensions["B"].width = 50
    wsr.column_dimensions["C"].width = 40

    # Datos para la Fase 2 (llenar el formulario).
    wdat = wb.create_sheet("Datos")
    for fila in (["id_portal", cfg["id"]], ["institucion", institucion], ["sector", sector],
                 ["anio", anio], ["mes", mes], ["desde", cfg["desde"]]):
        agregar(wdat, fila)
    wdat.sheet_state = "hidden"

    ruta = ruta_libre(RESULTADOS / f"verificacion_{cfg['id']}_{anio}_{mes:02d}.xlsx")
    try:
        wb.save(ruta)
    except PermissionError:  # justo ese nombre está abierto
        ruta = ruta.with_name(ruta.stem + datetime.now().strftime("_%H%M%S") + ".xlsx")
        wb.save(ruta)
    return ruta


def _ia_valor(r, clave):
    v = r.get(clave) or {}
    return f"{v.get('valor', '')}" + (f" (pág. {v['pagina']})" if v.get("pagina") else "")


def hoja_documentos(wb, resultados, docs):
    ws = wb.create_sheet("Análisis documentos")
    agregar(ws, ["N°", "Apartado", "Documento", "Mes", "Año", "Tipo", "Páginas", "Texto",
                 "Meses en el texto", "Palabras que faltan", "IA legible", "IA firma", "IA sello",
                 "IA nombre y puesto", "IA hallazgos", "IA observación", "Costo IA (US$)",
                 "Estado", "Archivo"])
    encabezado(ws)
    for r in resultados:
        info = docs.get(r["url"])
        if not info:
            continue
        for d in info["docs"]:
            f, local, des = d["fila"], d.get("local") or {}, d["descarga"]
            sal = d.get("ia") or {}
            res = sal.get("resultado") or {}
            if des.get("pendiente"):
                estado = "Pendiente de descargar"
            elif des.get("error") or local.get("error"):
                estado = "Error: " + (des.get("error") or local.get("error"))
            elif sal.get("error"):
                estado = "IA: " + sal["error"]
            elif res:
                estado = "Revisado con IA"
            else:
                estado = "Leído sin IA"
            texto = "" if local.get("con_texto") is None else (
                "Sí" if local["con_texto"] and not local.get("paginas_escaneadas") else
                "Escaneado" if not local["con_texto"] else f"Parcial ({local['paginas_escaneadas']} escaneadas)")
            agregar(ws, [r["numero"], r["apartado"], f.get("descripcion") or f.get("nombre"),
                         f.get("mes"), f.get("anio"), (local.get("tipo") or des.get("tipo") or "").upper(),
                         local.get("paginas"), texto, ", ".join(local.get("meses_texto", [])),
                         ", ".join(local.get("faltan_palabras", [])), res.get("legible", ""),
                         _ia_valor(res, "firma"), _ia_valor(res, "sello"),
                         _ia_valor(res, "nombre_y_puesto"),
                         "\n".join(h["descripcion"] for h in res.get("hallazgos", [])),
                         res.get("observacion_sugerida", ""), round(sal.get("costo_usd", 0), 4),
                         estado, des.get("archivo", "")])
    for col, ancho in zip("ABCDEFGHIJKLMNOPQRS",
                          (6, 26, 40, 11, 6, 6, 8, 12, 22, 18, 10, 14, 14, 14, 45, 45, 10, 28, 22)):
        ws.column_dimensions[col].width = ancho
    for fila in ws.iter_rows(min_row=2):
        for c in fila:
            c.alignment = Alignment(wrap_text=True, vertical="top")


def guardar_resumen(filas):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Resumen"
    cab = ["N° portal", "Institución", "Estado", "Cumple", "No cumple", "Revisar", "No aplica",
           "Sin calificar", "No se pudo revisar", "Alertas", "Costo IA (US$)", "Archivo"]
    agregar(ws, cab)
    encabezado(ws)
    for f in filas:
        agregar(ws, [f.get(c, "") for c in cab])
    for col, ancho in zip("ABCDEFGHIJKL", (10, 40, 22, 9, 10, 9, 10, 12, 12, 9, 12, 55)):
        ws.column_dimensions[col].width = ancho
    ruta = ruta_libre(RESULTADOS / f"resumen_{datetime.now():%Y%m%d_%H%M}.xlsx")
    wb.save(ruta)
    return ruta


def abrir_archivo(ruta):
    if hasattr(os, "startfile") and not PRUEBA:  # solo existe en Windows
        try:
            os.startfile(ruta)
        except OSError:
            pass


# ---------- programa ----------

def preparar_lectura(cfg, preguntar_si_existe):
    """Carga lo ya leído de esta institución y mes, o empieza de cero."""
    ruta = RESULTADOS / f"lectura_{cfg['id']}_{cfg['anio']}_{cfg['mes']:02d}.json"
    nueva = {"institucion": f"Institución {cfg['id']}", "apartados": [], "leido": {}}
    lectura = leer_json(ruta, None)
    if not lectura:
        return nueva, ruta, True
    cuando = max((d["leido_en"] for d in lectura["leido"].values()), default="?")
    if lectura.get("completa"):
        r = preguntar(f"   Ya se leyó completa el {cuando}. ¿Leer de nuevo el portal (S) o "
                      "usar lo guardado (N)?", "S") if preguntar_si_existe else cfg["releer"]
        if not r.upper().startswith("S"):
            return lectura, ruta, False
    else:
        r = preguntar(f"   Hay una lectura a medias ({len(lectura['leido'])} apartados, {cuando}). "
                      "¿Retomar (R) o empezar de cero (N)?", "R") if preguntar_si_existe else "R"
        if not r.upper().startswith("N"):
            return lectura, ruta, True
    # Se empieza de cero. Si la lectura anterior estaba completa se guarda aparte por si
    # el portal bloquea; una lectura a medias no reemplaza esa copia.
    if lectura.get("completa"):
        ruta.replace(ruta.with_name(ruta.stem + "_anterior.json"))
    return nueva, ruta, True


def procesar(page, reglas, cfg, preguntar_si_existe=True):
    """Lee (si hace falta) y arma el Excel de una institución.

    Devuelve la fila de resumen y el bloqueo (si el portal bloqueó a medio camino).
    """
    lectura, ruta_lectura, leer = preparar_lectura(cfg, preguntar_si_existe)
    resumen = {"N° portal": cfg["id"]}
    bloqueado, error = None, None
    if leer:
        try:
            lectura["completa"] = leer_institucion(page, cfg, lectura, ruta_lectura)
        except Bloqueado as e:
            bloqueado = e
        except Exception as e:  # por ejemplo, la portada no cargó
            error = str(e).splitlines()[0]
            print(f"   No se pudo leer el portal: {error}")
        guardar_json(ruta_lectura, lectura)
    if not lectura["apartados"]:
        estado = ("Detenida por bloqueo" if bloqueado else
                  f"Error: {error}" if error else "Sin menú de apartados")
        resumen.update({"Institución": lectura["institucion"], "Estado": estado})
        return resumen, bloqueado
    sector, supuesto = detectar_sector(cfg, lectura)
    previa = verificacion_anterior(cfg["id"], cfg["anio"], cfg["mes"])
    costo_ia = 0.0
    if cfg.get("documentos") and not bloqueado:  # solo baja lo que falte
        try:
            bajar_documentos(page, reglas, cfg, lectura, sector, previa)
        except Bloqueado as e:
            bloqueado = e
        guardar_json(ruta_lectura, lectura)
    docs = reunir_documentos(reglas, cfg, lectura, sector)
    if cfg.get("documentos") and docs:
        costo_ia = usar_ia(cfg, docs, lectura, sector, reglas, preguntar_si_existe)
    resultados = calcular(reglas, cfg, lectura, sector, supuesto, previa, docs)
    ruta = guardar_excel(cfg, lectura, sector, previa, resultados, docs)
    if lectura.get("completa"):
        guardar_historial(cfg["id"], cfg["anio"], cfg["mes"], lectura)
    conteo = {}
    for r in resultados:
        conteo[r["propuesta"]] = conteo.get(r["propuesta"], 0) + 1
    resumen.update(conteo, **{"Institución": lectura["institucion"],
                              "Estado": "Completa" if lectura.get("completa") else
                              (f"Incompleta ({error})" if error else "Incompleta"),
                              "Alertas": sum(len(r["alertas"]) for r in resultados),
                              "Costo IA (US$)": round(costo_ia, 2),
                              "Archivo": ruta.name})
    print(f"\nExcel listo: {ruta}")
    if bloqueado:
        resumen["Estado"] = "Detenida por bloqueo"
    return resumen, bloqueado


def iniciar_navegador(p):
    try:
        return p.chromium.launch(channel="chrome", headless=PRUEBA)
    except Exception:  # si no encuentra Chrome usa el navegador de Playwright
        return p.chromium.launch(headless=PRUEBA,
                                 executable_path=os.environ.get("CHROME_RUTA") or None)


def main():
    RESULTADOS.mkdir(exist_ok=True)
    reglas = json.loads((CARPETA / "reglas.json").read_text(encoding="utf-8"))
    ultimas = leer_json(RESPUESTAS, {})
    hoy = date.today()
    anterior = (hoy.year, hoy.month - 1) if hoy.month > 1 else (hoy.year - 1, 12)

    print("=== Verificador IAIP: revisión del portal público (no envía nada al formulario) ===\n")
    modo = preguntar("¿Una institución (1) o la lista de instituciones.txt (2)?",
                     ultimas.get("modo", "1"))
    anio = pedir_numero("Año a verificar", ultimas.get("anio", anterior[0]), 2015, 2100)
    mes = pedir_numero("Mes a verificar (1-12)", ultimas.get("mes", anterior[1]), 1, 12)
    limite = preguntar("¿Cuántos apartados revisar por institución? (Enter = todos)", "")
    limite = int(limite) if limite.isdigit() and int(limite) > 0 else None
    con_docs = preguntar("¿Descargar y revisar los documentos nuevos y del periodo? (S/N)",
                         ultimas.get("documentos", "S")).upper().startswith("S")

    trabajos = []
    if modo == "2":
        lista = leer_lista()
        if not lista:
            sys.exit("instituciones.txt está vacío. Escribe una institución por línea, ej.:  28 ; I")
        releer = preguntar("Si una institución ya se leyó completa este mes: ¿leer de nuevo (S) o "
                           "usar lo guardado (N)?", "N")
        for f in lista:
            desde = f["desde"] or desde_sugerido(f["id"], anio, mes)
            trabajos.append({"id": f["id"], "sector": f["sector"], "anio": anio, "mes": mes,
                             "desde": min(desde, mes), "limite": limite, "releer": releer,
                             "documentos": con_docs})
        print(f"Se revisarán {len(trabajos)} instituciones.")
    else:
        id_inst = preguntar("Número de la institución en el portal (ej. 28 para FONAC)",
                            ultimas.get("id", ""))
        if not id_inst.isdigit():
            sys.exit("Debe ser un número.")
        sector = sector_de(preguntar("¿Municipalidad (M), Institución (I) o Enter = automático?"))
        sugerido = desde_sugerido(id_inst, anio, mes)
        desde = pedir_numero("¿Desde qué mes revisar? (tu última verificación)", sugerido, 1, mes)
        trabajos.append({"id": id_inst, "sector": sector, "anio": anio, "mes": mes,
                         "desde": desde, "limite": limite, "releer": "S",
                         "documentos": con_docs})
        ultimas.update(id=id_inst)
    ultimas.update(modo=modo, anio=anio, mes=mes, documentos="S" if con_docs else "N")
    guardar_json(RESPUESTAS, ultimas)

    resumen, ruta_excel = [], None
    with sync_playwright() as p:
        nav = iniciar_navegador(p)
        page = nav.new_page()
        try:
            for i, cfg in enumerate(trabajos, 1):
                if i > 1:
                    esperar(PAUSA_INSTITUCION, "\nPausa antes de la siguiente institución")
                print(f"\n===== Institución {cfg['id']} ({i}/{len(trabajos)}) =====")
                fila, bloqueado = procesar(page, reglas, cfg, preguntar_si_existe=(modo != "2"))
                resumen.append(fila)
                if fila.get("Archivo"):
                    ruta_excel = RESULTADOS / fila["Archivo"]
                if bloqueado:
                    print(f"\n*** ALTO: {bloqueado}")
                    print("*** Se guardó lo avanzado. Espera al menos 1 hora antes de volver a "
                          "correrlo: seguirá donde se quedó.")
                    break
        finally:
            nav.close()

    if modo == "2" and resumen:
        ruta_excel = guardar_resumen(resumen)
        print(f"\nResumen de todas las instituciones: {ruta_excel}")
    if ruta_excel:
        abrir_archivo(ruta_excel)


if __name__ == "__main__":
    main()
