# Verificador IAIP — Fase 1

Revisa el **portal público** de una institución y te deja un **Excel con la propuesta** de verificación.
**No inicia sesión, no abre PDF y no envía nada.** Tú revisas y decides.

## Instalar (una sola vez)
1. Instala Python desde https://www.python.org/downloads/ — marca **"Add python.exe to PATH"**.
2. Doble clic en **`instalar.bat`**.

## Usar
1. Doble clic en **`ejecutar.bat`**.
2. Responde: número de la institución (el de la dirección, ej. `28` en `portalunico.iaip.gob.hn/28/7/`),
   Municipalidad o Institución, año, mes y cuántos apartados revisar.
   **Para las primeras pruebas pon `3`** para no cargar el portal.
3. Se abre Chrome solo y va despacio (10 a 20 segundos entre páginas).
4. Al terminar, abre el Excel en la carpeta **`resultados`**:
   - **Propuesta:** un renglón por apartado con Cumple / No cumple / Revisar, casillas a quitar y la observación ya escrita.
   - **Alertas:** lo que debes mirar tú (repetidos, nota aclaratoria, mes que no coincide, NO APLICA, etc.).
   - **Documentos:** la lista de todos los documentos encontrados.

## Si el portal bloquea (Error 1015)
El programa **se detiene solo** y guarda lo avanzado. Espera una hora y vuelve a correrlo: sigue donde se quedó.

## Archivos
- `reglas.json` — tus checklists convertidos en reglas (periodicidad y qué publicar por apartado).
- `crear_reglas.py` — vuelve a crear `reglas.json` si cambias los Excel.
- `comun.py` — las frases y la lógica de decisión.
- `fase1.py` — el programa principal.
- `pruebas/servidor_prueba.py` — portal falso para probar sin tocar el real.
