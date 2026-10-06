"""Funciones que no usan el navegador: meses, frases y la propuesta de decisión."""
import re
import unicodedata

MESES = ["ENERO", "FEBRERO", "MARZO", "ABRIL", "MAYO", "JUNIO", "JULIO",
         "AGOSTO", "SEPTIEMBRE", "OCTUBRE", "NOVIEMBRE", "DICIEMBRE"]

# Frases que el verificador ya usa en sus macros del Stream Deck.
FRASES = {
    "descrip": "hagamos buen uso del apartado de descripción al momento de cargar el "
               "documento PDF y describamos brevemente lo que encontraremos dentro del documento.",
    "txt_edit": "Actualizar Texto de fecha editable a la fecha más reciente",
    "no_nota": "al ser un apartado de carácter mensual y no se generó información o hubo algún "
               "tipo de actualización por favor NO utilizar \"NOTA ACLARATORIA\", solo actualizar "
               "el texto de fecha editable, ya que ustedes como figura de OIP dan FÉ y son "
               "RESPONSABLES de TODA información cargada y no cargada al portal.",
    "planillas": "sin importar de que las planillas no se paguen en el mes deben de generar las "
                 "planillas ya que estas generan distintos montos cada mes por distintos motivos, "
                 "desde ausencia, horas extras, decimocuartos y tercero ETC. ETC. así que pone la "
                 "nota aclaratoria y abajo la planilla del mes",
    "info_rep": "solicite la eliminación de documento repetidos, que tengan mala orientación, "
                "que no pertenezcan al apartado y que no contengan firmados",
}


def normalizar(texto):
    """Minúsculas, sin tildes y sin espacios de más."""
    t = unicodedata.normalize("NFKD", str(texto or ""))
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", t).strip().lower()


def clasificar_periodicidad(texto):
    """'Mensual', 'Registros son mensuales', 'Cada 6 meses'... -> mensual/trimestral/..."""
    t = normalizar(texto)
    # Palabras completas: "manual" o "anualmente" no deben contar como "anual".
    if re.search(r"\bmensual(es)?\b", t):
        return "mensual"
    if re.search(r"\btrimestral(es)?\b", t):
        return "trimestral"
    if "6 meses" in t or re.search(r"\bsemestral(es)?\b", t):
        return "semestral"
    if re.search(r"\banual(es)?\b", t):
        return "anual"
    return "cuando_cambie"


def mes_a_numero(texto):
    """'Agosto' -> 8, '08' -> 8, texto sin mes -> None."""
    t = normalizar(texto)
    if t.isdigit() and 1 <= int(t) <= 12:
        return int(t)
    for i, m in enumerate(MESES):
        if normalizar(m) in t:
            return i + 1
    if "setiembre" in t:
        return 9
    return None


def meses_en_texto(texto):
    t = normalizar(texto).replace("setiembre", "septiembre")
    return {i + 1 for i, m in enumerate(MESES) if re.search(r"\b" + normalizar(m) + r"\b", t)}


def lista_con_ni(items):
    """['ENERO','FEBRERO','MARZO'] -> 'ENERO, FEBRERO ni MARZO'."""
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " ni " + items[-1]


def frase_meses_faltantes(meses, anio):
    nombres = [MESES[m - 1] for m in sorted(meses)]
    if len(nombres) == 1:
        return f"No hay información para el mes de: {nombres[0]} del {anio}."
    return f"No hay información para los meses de: {lista_con_ni(nombres)} del {anio}."


def periodos_esperados(periodicidad, mes, desde=1):
    """Qué meses (o grupos de meses) deben estar publicados hasta el mes verificado."""
    if periodicidad == "mensual":
        return [[m] for m in range(desde, mes + 1)]
    if periodicidad == "trimestral":
        return [list(range(f - 2, f + 1)) for f in (3, 6, 9, 12) if f <= mes]
    if periodicidad == "semestral":
        return [list(range(f - 5, f + 1)) for f in (6, 12) if f <= mes]
    return []


def nombre_periodo(grupo, periodicidad):
    if periodicidad == "trimestral":
        return ["PRIMER", "SEGUNDO", "TERCER", "CUARTO"][grupo[-1] // 3 - 1] + " TRIMESTRE"
    if periodicidad == "semestral":
        return ("PRIMER" if grupo[-1] == 6 else "SEGUNDO") + " SEMESTRE"
    return MESES[grupo[0] - 1]


def leer_fecha(texto):
    """'Agosto 2026', '31/08/2026', '08/2026' o '2026-08-31' -> (2026, 8). Si no se entiende: None."""
    t = str(texto or "")
    m = re.search(r"(\d{1,2})[/-](\d{1,2})[/-](20\d\d)", t)
    if m and 1 <= int(m.group(2)) <= 12:
        return int(m.group(3)), int(m.group(2))
    m = re.search(r"(20\d\d)-(\d{1,2})-\d{1,2}", t)
    if m and 1 <= int(m.group(2)) <= 12:
        return int(m.group(1)), int(m.group(2))
    m = re.search(r"\b(\d{1,2})[/-](20\d\d)", t)
    if m and 1 <= int(m.group(1)) <= 12:
        return int(m.group(2)), int(m.group(1))
    anio = re.search(r"(20\d\d)", t)
    meses = meses_en_texto(t)
    if anio and meses:
        return int(anio.group(1)), max(meses)
    return None


def evaluar(regla, pagina, anio, mes, desde=None):
    """Propone una decisión para un apartado, con los criterios del verificador:

    - Mensual: si faltan meses (desde la última verificación) -> Cumple y se quita Completa.
    - Trimestral, semestral, anual y "cuando existan cambios": no se quitan puntos
      por documentos faltantes, solo se avisa.
    - Todos: el texto de fecha editable debe estar al día; si no -> se quita Oportuna.
    """
    desde = desde or mes
    perio = regla["periodicidad"] if regla else "cuando_cambie"
    filas = pagina["filas"]
    quitar, obs, alertas = set(), [], []

    if regla and regla.get("siempre_no_aplica"):
        return _resultado("No aplica", quitar, obs, alertas, perio, [], [])
    texto_area = normalizar(pagina.get("texto_area", ""))
    if "no aplica" in texto_area and not (regla and regla.get("nunca_no_aplica")):
        alertas.append("El texto del apartado dice NO APLICA: confirmar.")
        return _resultado("Revisar", quitar, obs, alertas, perio, [], [])

    # Meses publicados en el año verificado.
    del_anio = [f for f in filas if str(f.get("anio", "")).strip() == str(anio)]
    publicados = set()
    for f in del_anio:
        m = mes_a_numero(f.get("mes", ""))
        if m:
            publicados.add(m)
        else:  # el mes no viene en la columna: se busca en la descripción
            publicados |= meses_en_texto(f.get("descripcion", ""))

    encontrados, faltantes = [], []
    for grupo in periodos_esperados(perio, mes, desde):
        nombre = nombre_periodo(grupo, perio)
        (encontrados if publicados & set(grupo) else faltantes).append((grupo, nombre))

    if perio == "mensual" and faltantes:
        obs.append(frase_meses_faltantes([g[0] for g, _ in faltantes], anio))
        quitar.add("Completa")
    elif faltantes:
        alertas.append(f"No se encontró el {lista_con_ni([n for _, n in faltantes])} del {anio} "
                       "(no se quitan puntos).")
    if perio == "anual" and filas and not del_anio:
        alertas.append(f"No se encontró documento del año {anio} (no se quitan puntos).")
    if perio == "cuando_cambie" and filas:
        alertas.append("Apartado 'cuando existan cambios': revisar el contenido a mano.")

    # Texto de fecha editable: obligatorio y al día en todos los apartados.
    fa = pagina.get("fecha_actualizacion", "")
    fecha = leer_fecha(fa)
    if not fa.strip():
        quitar.add("Oportuna")
        obs.append(FRASES["txt_edit"])
        alertas.append("No se encontró el texto de fecha editable.")
    elif not fecha:
        alertas.append(f"No se entiende la fecha editable '{fa}': revisar Oportuna a mano.")
    elif fecha < (anio, mes):
        quitar.add("Oportuna")
        obs.append(FRASES["txt_edit"])

    # Tabla incompleta: el portal dice que hay más documentos de los leídos.
    total = pagina.get("total_portal")
    if total and total > len(filas):
        alertas.append(f"Solo se leyeron {len(filas)} de {total} documentos: revisar a mano.")

    # Duplicados y descripciones.
    vistos, repetidos = set(), []
    for f in filas:
        if not normalizar(f.get("descripcion")):
            continue  # sin descripción no se puede saber si es el mismo documento
        clave = (str(f.get("anio")), normalizar(f.get("mes")), normalizar(f.get("nombre")),
                 normalizar(f.get("descripcion")))
        if clave in vistos:
            repetidos.append(f"{f.get('mes')} {f.get('anio')}")
        vistos.add(clave)
    if repetidos:
        alertas.append("Posibles documentos repetidos: " + ", ".join(sorted(set(repetidos))))
        obs.append(FRASES["info_rep"])
    if any(not normalizar(f.get("descripcion")) for f in filas):
        obs.append(FRASES["descrip"])
    for f in del_anio:
        m_col = mes_a_numero(f.get("mes", ""))
        m_desc = meses_en_texto(f.get("descripcion", ""))
        if m_col and m_desc and m_col not in m_desc:
            alertas.append(f"La descripción no coincide con el mes {f.get('mes')}: "
                           f"'{f.get('descripcion')}'")

    # "Nota aclaratoria" como palabra completa (no "Notas a los estados financieros").
    notas = [f for f in del_anio if re.search(
        r"\bnota aclaratoria\b|\bnota\b(?! a los)",
        normalizar(f.get("nombre")) + " " + normalizar(f.get("descripcion")))]
    if notas:
        if regla and regla.get("nota_no_valida"):
            obs.append(FRASES["planillas"])
            alertas.append("Tiene nota aclaratoria en un apartado donde no es válida.")
        else:
            alertas.append(f"Tiene {len(notas)} nota(s) aclaratoria(s): revisar si es válida.")

    pp = pagina.get("periodo_portal", "")
    if regla and pp and perio != "cuando_cambie" and clasificar_periodicidad(pp) != perio:
        alertas.append(f"El portal dice periodo '{pp}' y el checklist '{regla['periodicidad_texto']}'.")
    if not regla:
        alertas.append("Este apartado no está en el checklist: revisar a mano.")
    # "No cumple" solo cuando no hay nada publicado; si falta algo se marca Cumple y
    # se quitan casillas, igual que en las macros.
    sin_nada = not del_anio if perio == "mensual" else not filas
    if sin_nada:
        propuesta = "No cumple"
        if not filas:
            obs.append("No hay documentos publicados en este apartado.")
    elif alertas:
        propuesta = "Revisar"
    else:
        propuesta = "Cumple"
    return _resultado(propuesta, quitar, obs, alertas, perio,
                      [n for _, n in encontrados], [n for _, n in faltantes])


def _resultado(propuesta, quitar, obs, alertas, perio, encontrados, faltantes):
    return {
        "propuesta": propuesta,
        "periodicidad": perio,
        "encontrados": encontrados,
        "faltantes": faltantes,
        "quitar": sorted(quitar),
        "observacion": " ".join(dict.fromkeys(obs)),  # sin frases repetidas
        "alertas": alertas,
    }
