"""UN SOLO PASO: revisa el portal público y llena el sistema de evaluación (GVT). Sin Excel.

Parte 1 (sola): lee todos los apartados del portal y baja los documentos según la regla:
  - Estructura Orgánica, Regulación y Participación Ciudadana: solo el documento más reciente.
  - Finanzas y Planeación y Rendición de Cuentas: todos los del periodo (anuales: el más reciente).
  - Compras y Contrataciones: se saltan siempre (las revisa el verificador a mano).
Parte 2 (contigo): por cada apartado llena el formulario del GVT, suena y espera a que
  el verificador revise y pulse Enviar. Los "Sin calificar" se saltan.
Al final muestra la lista de los apartados saltados y su motivo.

Igual que antes: nunca pulsa Enviar, nunca marca "Soy humano" y no guarda la contraseña.
"""
import json
import sys
from datetime import date, datetime

from playwright.sync_api import Error as ErrorNavegador
from playwright.sync_api import sync_playwright

import documentos
import ia
from comun import MESES, es_no_aplica, normalizar
from documentos import Bloqueado, sonar
from fase1 import (CARPETA, PAUSA, PAUSA_INSTITUCION, PERFIL_PORTAL, PORTAL, RESPUESTAS, RESULTADOS, abrir,
                   buscar_regla, calcular, desde_sugerido, detectar_sector, esperar, guardar_historial,
                   guardar_json, leer_institucion, leer_json, leer_lista, listar_apartados,
                   nombre_institucion, pedir_numero, preguntar, preparar_lectura, reunir_documentos,
                   ruta_docs, sector_de, usar_ia, verificacion_anterior)
from fase2 import (CASILLAS, PERFIL, PRUEBA, Detener, abrir_formulario, esperar_envio,
                   institucion_en_pagina, llenar, permitir_portapapeles, revisar_formulario,
                   revisar_mensaje, ya_verificados)
from navegador import Chrome

SALTAR = {"compras", "contrataciones"}  # se hacen a mano
SOLO_RECIENTE = {"estructura organica", "regulacion", "participacion ciudadana"}  # ponderación baja
documentos.MAX_POR_APARTADO = 40  # Finanzas y Planeación: todos los del periodo


# ---------- Parte 1: portal ----------

def se_salta(reglas, sector, nombre):
    regla = buscar_regla(reglas, sector, nombre)
    return normalizar(regla["apartado"] if regla else nombre) in SALTAR


def elegir_documentos(filas, regla, cfg, anteriores):
    """Documentos a bajar de un apartado según su componente. Devuelve (filas, excedió)."""
    con_enlace = [f for f in filas if f.get("enlace")]
    if not con_enlace:
        return [], False
    if not regla or normalizar(regla["componente"]) in SOLO_RECIENTE:
        return [max(con_enlace, key=documentos.fecha_orden)], False
    return documentos.seleccionar(filas, regla["periodicidad"], cfg["anio"], cfg["desde"],
                                  cfg["mes"], anteriores)


def bajar_documentos(page, reglas, cfg, lectura, sector, previa):
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
        datos = lectura["leido"][ap["url"]]["datos"]
        if es_no_aplica(regla, datos):
            continue
        anteriores = set(previa["enlaces"].get(ap["url"], [])) if previa else None
        filas, excedio = elegir_documentos(datos["filas"], regla, cfg, anteriores)
        elegidos[ap["url"]] = {"enlaces": [f["enlace"] for f in filas], "excedio": excedio}
        pendientes += [f for f in filas if not registro.get(f["enlace"], {}).get("archivo")]
    lectura["documentos"] = elegidos
    print(f"\nDocumentos a revisar: {sum(len(e['enlaces']) for e in elegidos.values())} "
          f"({len(pendientes)} por descargar).")
    documentos.descargar_pendientes(page, pendientes, carpeta, registro,
                                    lambda: guardar_json(ruta_registro, registro))


def leer_portal(page, reglas, cfg, presupuesto, preguntar_si_existe):
    """Lee el portal de una institución y calcula la propuesta.
    Devuelve (trabajo para la Parte 2 o None, bloqueo si lo hubo)."""
    lectura, ruta_lectura, leer = preparar_lectura(cfg, preguntar_si_existe)
    bloqueado, a_mano = None, []
    try:
        if leer and not lectura["apartados"]:
            print("\nAbriendo la portada de la institución...")
            for url in (f"{PORTAL}/{cfg['id']}/", f"{PORTAL}/{cfg['id']}/7/"):
                abrir(page, url)
                lectura["apartados"] = listar_apartados(page, cfg["id"])
                if lectura["apartados"]:
                    break
                esperar(PAUSA)
            lectura["institucion"] = nombre_institucion(page, cfg["id"]) or lectura["institucion"]
        sector, _ = detectar_sector(cfg, lectura)
        nuevos = [a["nombre"] for a in lectura["apartados"] if se_salta(reglas, sector, a["nombre"])]
        lectura["apartados"] = [a for a in lectura["apartados"] if a["nombre"] not in nuevos]
        lectura["a_mano"] = a_mano = list(dict.fromkeys(lectura.get("a_mano", []) + nuevos))
        guardar_json(ruta_lectura, lectura)
        if a_mano:
            print(f"Se saltan (a mano): {', '.join(a_mano)}")
        if leer:
            lectura["completa"] = leer_institucion(page, cfg, lectura, ruta_lectura)
    except Bloqueado as e:
        bloqueado = e
    except Exception as e:  # por ejemplo, la portada no cargó
        print(f"   No se pudo leer el portal: {str(e).splitlines()[0]}")
    guardar_json(ruta_lectura, lectura)
    if not lectura["apartados"]:
        return None, bloqueado
    sector, supuesto = detectar_sector(cfg, lectura)
    previa = verificacion_anterior(cfg["id"], cfg["anio"], cfg["mes"])
    if not bloqueado:
        try:
            bajar_documentos(page, reglas, cfg, lectura, sector, previa)
        except Bloqueado as e:
            bloqueado = e
        guardar_json(ruta_lectura, lectura)
    docs = reunir_documentos(reglas, cfg, lectura, sector)
    aviso_ia = "Firma y sello NO revisados (IA apagada)." if not docs else ""
    if docs:
        _, aviso_ia = usar_ia(cfg, docs, lectura, sector, reglas, presupuesto)
    resultados = calcular(reglas, cfg, lectura, sector, supuesto, previa, docs)
    if lectura.get("completa"):
        guardar_historial(cfg["id"], cfg["anio"], cfg["mes"], lectura)
    return {"cfg": cfg, "institucion": lectura["institucion"], "resultados": resultados,
            "a_mano": a_mano, "aviso_ia": aviso_ia}, bloqueado


# ---------- Parte 2: sistema de evaluación ----------

def preparar(r):
    """Devuelve (fila, decisión, casillas a quitar) o lanza ValueError con el motivo para saltarlo."""
    if r["propuesta"] == "Sin calificar":
        raise ValueError("Sin calificar: " + ("; ".join(r["dudas"]) or "no hubo certeza"))
    captura_mal = [a for a in r["alertas"] if a.startswith("La captura no muestra")]
    if captura_mal:
        raise ValueError(captura_mal[0])
    if not r.get("captura") or not (RESULTADOS / r["captura"]).exists():
        raise ValueError("No hay captura del portal de este apartado")
    quitar = list(r["quitar"]) if r["propuesta"] == "Cumple" else []
    if any(c not in CASILLAS for c in quitar):
        raise ValueError(f"Casilla desconocida en la propuesta: {quitar}")
    fila = {"numero": r["numero"], "apartado": r["apartado"], "observacion": r["observacion"] or "",
            "captura": RESULTADOS / r["captura"]}
    return fila, r["propuesta"], quitar


def llenar_institucion(chrome, page, reporte, trabajo, saltados):
    """Llena el GVT apartado por apartado. Lanza Detener o KeyboardInterrupt para parar todo."""
    cfg, institucion = trabajo["cfg"], trabajo["institucion"]
    id_inst, anio, mes = str(cfg["id"]), cfg["anio"], cfg["mes"]
    carpeta_fotos = RESULTADOS / "envios" / f"{id_inst}_{anio}_{mes:02d}"
    carpeta_fotos.mkdir(parents=True, exist_ok=True)
    ruta_log = RESULTADOS / f"envios_{id_inst}_{anio}_{mes:02d}.json"
    historial = leer_json(ruta_log, [])
    ya_enviados = {normalizar(h.get("apartado")) for h in historial if h.get("estado") == "Enviado"}

    actual = {}

    def anotar(registro, estado, saltar=True):
        actual["r"]["procesado"] = True
        registro["estado"] = estado
        print(f"   -> {estado}")
        historial.append({k: str(v) for k, v in registro.items()})
        guardar_json(ruta_log, historial)
        if saltar:
            saltados.append((institucion, registro["apartado"], estado))

    print(f"\n===== GVT: {institucion} — {MESES[mes - 1]} {anio} =====")
    if trabajo.get("aviso_ia"):
        print(f"Aviso: {trabajo['aviso_ia']}")
    resultados = trabajo["resultados"]
    for i, r in enumerate(resultados, 1):
        registro = {"numero": r["numero"], "apartado": r["apartado"], "propuesta": r["propuesta"],
                    "quitar": ", ".join(r["quitar"]), "observacion": r["observacion"],
                    "hora": datetime.now().strftime("%d/%m/%Y %H:%M")}
        print(f"\n[{i}/{len(resultados)}] {r['apartado']}: {r['propuesta']}"
              + (f" (quitar {', '.join(r['quitar'])})" if r["quitar"] and r["propuesta"] == "Cumple" else ""))
        actual["r"] = r
        if r["propuesta"] != "Sin calificar":
            for aviso in r["alertas"]:
                print(f"   Aviso: {aviso}")
        try:
            fila, decision, quitar = preparar(r)
        except ValueError as e:
            anotar(registro, str(e))
            continue
        nombre = normalizar(r["apartado"])
        if nombre in ya_enviados:
            anotar(registro, "Ya enviado antes por este programa", saltar=False)
            continue
        avisos = []

        def al_aviso(d, avisos=avisos):  # aviso del sistema mientras se llena: no se acepta
            avisos.append(d.message)
            d.dismiss()
        page.on("dialog", al_aviso)
        try:
            abrir_formulario(page, id_inst)
            en_sistema = institucion_en_pagina(page)
            if normalizar(en_sistema) != normalizar(institucion):
                raise Detener(f"El GVT dice '{en_sistema or '¿?'}' y el portal '{institucion}'.")
            hechos, vistos = ya_verificados(reporte, id_inst, institucion, anio, mes)
            if nombre not in vistos:
                anotar(registro, "El apartado no aparece en el reporte del GVT (nombre distinto)")
                continue
            if nombre in hechos:
                anotar(registro, "Ya verificado este mes en el GVT", saltar=False)
                continue
            page.bring_to_front()
            llenar(page, fila, decision, quitar, anio, mes)
            revisar_formulario(page, fila, decision, quitar, anio, mes)
            if avisos:
                raise ValueError(f"el sistema mostró un aviso: {avisos[0]}")
        except (ValueError, ErrorNavegador) as e:
            anotar(registro, f"No se llenó: {str(e).splitlines()[0]}")
            continue
        finally:
            page.remove_listener("dialog", al_aviso)
        foto = carpeta_fotos / f"{int(r['numero'] or 0):03d}_propuesta.png"
        page.screenshot(path=str(foto), full_page=True)
        estado, mensaje = esperar_envio(page)
        registro.update(mensaje=mensaje, hora=datetime.now().strftime("%d/%m/%Y %H:%M"))
        if estado == "Enviado":
            try:  # lo que de verdad se envió (por si cambiaste algo en el formulario)
                enviado = carpeta_fotos / f"{int(r['numero'] or 0):03d}_enviado.png"
                page.screenshot(path=str(enviado), full_page=True)
                registro["foto_enviado"] = enviado.relative_to(RESULTADOS).as_posix()
            except ErrorNavegador:
                pass
            problemas = revisar_mensaje(mensaje, institucion, r["apartado"], anio, mes)
            if problemas:
                anotar(registro, "¡REVISAR EN EL GVT! No coincide: " + ", ".join(problemas))
                sonar()
                raise Detener(f"Lo guardado no coincide ({', '.join(problemas)}). Mensaje: {mensaje}")
            ya_enviados.add(nombre)
            anotar(registro, "Enviado", saltar=False)
            boton_ok = page.get_by_role("button", name="OK")
            if boton_ok.count():
                boton_ok.first.click()
        elif estado.startswith("Sin enviar"):
            anotar(registro, "Dudoso: no se vio el mensaje de guardado. Revisar en el GVT")
        else:
            anotar(registro, estado)


# ---------- programa ----------

def main():
    RESULTADOS.mkdir(exist_ok=True)
    reglas = json.loads((CARPETA / "reglas.json").read_text(encoding="utf-8"))
    ultimas = leer_json(RESPUESTAS, {})
    hoy = date.today()
    anterior = (hoy.year, hoy.month - 1) if hoy.month > 1 else (hoy.year - 1, 12)

    print("=== Verificador IAIP: revisa el portal y llena el GVT (tú pulsas Enviar) ===\n")
    modo = preguntar("¿Una institución (1) o la lista de instituciones.txt (2)?", ultimas.get("modo", "1"))
    anio = pedir_numero("Año a verificar", ultimas.get("anio", anterior[0]), 2015, 2100)
    mes = pedir_numero("Mes a verificar (1-12)", ultimas.get("mes", anterior[1]), 1, 12)
    limite = preguntar("¿Cuántos apartados revisar por institución? (Enter = todos)", "")
    limite = int(limite) if limite.isdigit() and int(limite) > 0 else None

    trabajos = []
    if modo == "2":
        lista = leer_lista()
        if not lista:
            sys.exit("instituciones.txt está vacío. Escribe una institución por línea, ej.:  28 ; I")
        for f in lista:
            desde = f["desde"] or desde_sugerido(f["id"], anio, mes)
            trabajos.append({"id": f["id"], "sector": f["sector"], "anio": anio, "mes": mes,
                             "desde": min(desde, mes), "limite": limite, "releer": "N"})
        print(f"Se revisarán {len(trabajos)} instituciones.")
    else:
        id_inst = preguntar("Número de la institución en el portal (ej. 28 para FONAC)", ultimas.get("id", ""))
        if not id_inst.isdigit():
            sys.exit("Debe ser un número.")
        sector = sector_de(preguntar("¿Municipalidad (M), Institución (I) o Enter = automático?"))
        desde = pedir_numero("¿Desde qué mes revisar? (tu última verificación)",
                             desde_sugerido(id_inst, anio, mes), 1, mes)
        trabajos.append({"id": id_inst, "sector": sector, "anio": anio, "mes": mes,
                         "desde": desde, "limite": limite, "releer": "S"})
        ultimas.update(id=id_inst)
    ultimas.update(modo=modo, anio=anio, mes=mes)
    guardar_json(RESPUESTAS, ultimas)

    conf_ia = ia.cargar_config()
    presupuesto = {"usado": 0.0, "tope": float(conf_ia["tope_usd_por_corrida"]),
                   "preguntar": False, "permitido": False}
    if ia.disponible(conf_ia)[0]:  # se pregunta ahora para no dejar la Parte 1 esperando
        presupuesto["permitido"] = preguntar(
            f"¿Usar la IA para firma y sello? Tope US${presupuesto['tope']:.2f} (S/N)",
            "S").upper().startswith("S")

    # Parte 1: el portal (sin ti)
    listos, no_leidas = [], []
    print("\n##### PARTE 1: revisando el portal (puedes hacer otra cosa) #####")
    with sync_playwright() as p, Chrome(p, PERFIL_PORTAL) as chrome:
        for i, cfg in enumerate(trabajos, 1):
            if i > 1:
                esperar(PAUSA_INSTITUCION, "\nPausa antes de la siguiente institución")
            print(f"\n===== Institución {cfg['id']} ({i}/{len(trabajos)}) =====")
            trabajo, bloqueado = leer_portal(chrome.pagina, reglas, cfg, presupuesto,
                                             preguntar_si_existe=(modo != "2"))
            if trabajo:
                listos.append(trabajo)
            else:
                no_leidas.append((cfg["id"], "no se pudo leer el portal"))
            if bloqueado:
                print(f"\n*** ALTO en el portal: {bloqueado}\n*** Se llena el GVT con lo ya leído. "
                      "Espera al menos 1 hora antes de volver a correrlo.")
                no_leidas += [(c["id"], "no se leyó (el portal bloqueó)") for c in trabajos[i:]]
                break

    saltados = []
    if listos:
        # Parte 2: el GVT (contigo)
        print("\n##### PARTE 2: llenar el GVT #####")
        sonar()
        if not PRUEBA:
            input(">>> El portal ya se revisó. Pulsa Enter para empezar a llenar el GVT... ")
        with sync_playwright() as p, Chrome(p, PERFIL) as chrome:
            permitir_portapapeles(chrome.contexto)
            page, reporte = chrome.pagina, chrome.nueva_pagina()
            try:
                for trabajo in listos:
                    llenar_institucion(chrome, page, reporte, trabajo, saltados)
            except Detener as e:
                print(f"\n*** ALTO: {e}\n*** No se siguió llenando para no guardar algo equivocado.")
            except KeyboardInterrupt:
                print("\nTerminado por el verificador.")
            except Exception as e:  # cualquier otro problema: se para, lo enviado ya quedó anotado
                print(f"\n*** ALTO por un error inesperado: {str(e).splitlines()[0]}")

    for trabajo in listos:  # lo que no se llegó a llenar (alto, Q o error)
        saltados += [(trabajo["institucion"], r["apartado"], "no se llegó a llenar (el programa se detuvo)")
                     for r in trabajo["resultados"] if not r.get("procesado")]
    saltados += [(f"Institución {id_inst}", "(todos)", motivo) for id_inst, motivo in no_leidas]
    print("\n##### APARTADOS QUE QUEDAN PARA TI (hazlos a mano) #####")
    if not saltados and not any(t["a_mano"] for t in listos):
        print("Ninguno.")
    for institucion, apartado, motivo in saltados:
        print(f"- {institucion} | {apartado} | {motivo}")
    for trabajo in listos:
        for apartado in trabajo["a_mano"]:
            print(f"- {trabajo['institucion']} | {apartado} | se hace a mano (no lo revisa el programa)")


if __name__ == "__main__":
    main()
