"""FASE 3A: descarga segura de los documentos (PDF y Excel) del portal.

- Baja solo los documentos nuevos y los del periodo verificado.
- Va despacio y guarda un registro para seguir donde se quedó.
- Revisa que lo bajado sea de verdad un PDF o un Excel (no la página de bloqueo).
- Error 1015: espera 10 y 30 minutos; si sigue, se detiene.
- Casilla "Soy humano": NO se marca sola. Suena, pausa y espera a que la marques tú.
"""
import hashlib
import io
import os
import random
import re
import time
import zipfile
from datetime import datetime

from comun import mes_a_numero, normalizar

PRUEBA = "PORTAL_PRUEBA" in os.environ
PAUSA = (0, 0) if PRUEBA else (10, 20)  # segundos entre descargas
ESPERAS_BLOQUEO = (1, 2) if PRUEBA else (600, 1800)  # 10 y 30 minutos
ESPERA_HUMANO = 10 if PRUEBA else 300  # cuánto se espera a que marques la casilla
MAX_BYTES = 50 * 1024 * 1024  # 50 MB
MAX_POR_APARTADO = 15


class Bloqueado(Exception):
    pass


def sonar():
    try:
        import winsound  # solo existe en Windows
        for _ in range(3):
            winsound.Beep(1000, 400)
    except Exception:
        print("\a", end="", flush=True)


def tipo_archivo(datos):
    """Mira los primeros bytes: 'pdf', 'xlsx', 'xls', 'xlsm' o ''."""
    if datos[:5] == b"%PDF-":
        return "pdf"
    if datos[:4] == b"PK\x03\x04":
        try:
            nombres = zipfile.ZipFile(io.BytesIO(datos)).namelist()
        except zipfile.BadZipFile:
            return ""
        if any(n.lower().endswith("vbaproject.bin") for n in nombres):
            return "xlsm"  # Excel con macros: no se abre por seguridad
        if any(n.startswith("xl/") for n in nombres):
            return "xlsx"
        return ""
    if datos[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        return "xls"
    return ""


def es_bloqueo(texto):
    t = normalizar(texto[:3000])
    return "error 1015" in t or "rate limited" in t or "access denied" in t


def es_casilla_humano(texto):
    t = normalizar(texto[:3000])
    return "just a moment" in t or "verify you are human" in t or "un momento" in t \
        or "challenge-platform" in t or "cf-turnstile" in t


def seleccionar(filas, periodicidad, anio, desde, mes, enlaces_anteriores):
    """Documentos a revisar: los nuevos y los del periodo; en anuales o
    'cuando existan cambios', el más reciente."""
    elegidos = []
    for f in filas:
        if not f.get("enlace"):
            continue
        nuevo = enlaces_anteriores is not None and f["enlace"] not in enlaces_anteriores
        m = mes_a_numero(f.get("mes", ""))
        del_periodo = str(f.get("anio", "")).strip() == str(anio) and m and desde <= m <= mes
        if nuevo or del_periodo:
            elegidos.append(f)
    if periodicidad in ("anual", "cuando_cambie") and not elegidos and filas:
        con_enlace = [f for f in filas if f.get("enlace")]
        if con_enlace:
            elegidos.append(max(con_enlace, key=lambda f: f.get("subido", "")))
    vistos, unicos = set(), []
    for f in elegidos:
        if f["enlace"] not in vistos:
            vistos.add(f["enlace"])
            unicos.append(f)
    return unicos[:MAX_POR_APARTADO], len(unicos) > MAX_POR_APARTADO


def _bajar(page, url):
    r = page.request.get(url, timeout=90000)
    largo = int(r.headers.get("content-length", "0") or 0)
    if largo > MAX_BYTES:
        return None, f"Archivo muy grande ({largo // 1048576} MB)"
    return r.body(), ""


def _esperar_humano(page, url):
    """Abre el enlace en Chrome para que el verificador marque 'Soy humano' y, mientras
    espera, vuelve a intentar la descarga cada 15 segundos."""
    print("\n   >>> El portal pide marcar 'Soy humano'. Márcala tú en la ventana de Chrome. <<<")
    sonar()
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=60000)
    except Exception:
        pass  # si el archivo se descarga directo, Chrome no lo muestra: se sigue esperando
    limite = time.time() + ESPERA_HUMANO
    while time.time() < limite:
        time.sleep(1 if PRUEBA else 15)
        try:
            datos, _ = _bajar(page, url)
            if datos and tipo_archivo(datos):
                return True
        except Exception:
            pass
    return False


def descargar(page, url):
    """Devuelve (bytes, tipo, error). Lanza Bloqueado si el portal sigue bloqueando."""
    esperas = list(ESPERAS_BLOQUEO)
    humano_pedido = False
    intentos_lentos = 0
    while True:
        try:
            datos, error = _bajar(page, url)
        except Exception as e:  # tardó demasiado o falló la red
            intentos_lentos += 1
            if intentos_lentos > 2:
                return None, "", f"No cargó: {str(e).splitlines()[0]}"
            print("   La descarga tardó demasiado; se reintenta en 30 s...")
            time.sleep(1 if PRUEBA else 30)
            continue
        if error:
            return None, "", error
        if len(datos) > MAX_BYTES:
            return None, "", f"Archivo muy grande ({len(datos) // 1048576} MB)"
        tipo = tipo_archivo(datos)
        if tipo:
            return datos, tipo, ""
        texto = datos[:5000].decode("utf-8", "ignore")
        if es_bloqueo(texto):
            if not esperas:
                raise Bloqueado("El portal sigue bloqueando (Error 1015).")
            espera = esperas.pop(0)
            print(f"   Error 1015: el portal pide calma. Se espera {espera // 60 or espera} "
                  f"{'min' if espera >= 60 else 's'} antes de reintentar...")
            time.sleep(espera)
            continue
        if es_casilla_humano(texto) and not humano_pedido:
            humano_pedido = True
            if _esperar_humano(page, url):
                continue
            raise Bloqueado("Nadie marcó la casilla 'Soy humano'.")
        return None, "", "Lo descargado no es PDF ni Excel"


def descargar_pendientes(page, pendientes, carpeta, registro, guardar_registro):
    """pendientes: lista de filas (con 'enlace'). Guarda archivos y registro por enlace."""
    carpeta.mkdir(parents=True, exist_ok=True)
    total = len(pendientes)
    for i, f in enumerate(pendientes, 1):
        enlace = f["enlace"]
        if registro.get(enlace, {}).get("archivo"):
            continue
        espera = random.uniform(*PAUSA)
        texto = re.sub(r"[\x00-\x1f\x7f]", "", f.get("descripcion") or f.get("nombre") or "")
        print(f"   Documento {i}/{total}: {texto} "
              f"({f.get('mes')} {f.get('anio')}) (esperando {espera:.0f} s)")
        time.sleep(espera)
        datos, tipo, error = descargar(page, enlace)
        entrada = {"fecha": datetime.now().isoformat(timespec="minutes"), "error": error}
        if datos:
            if tipo == "xlsm":
                entrada["error"] = "Excel con macros: no se abre por seguridad"
            else:
                sha = hashlib.sha256(datos).hexdigest()
                ruta = carpeta / f"{sha[:16]}.{tipo}"
                ruta.write_bytes(datos)
                entrada.update(sha=sha, tipo=tipo, archivo=ruta.name, bytes=len(datos))
        registro[enlace] = entrada
        guardar_registro()
        print(f"     -> {'error: ' + entrada['error'] if entrada['error'] else entrada['tipo'].upper()}")
