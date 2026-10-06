# Verificador IAIP — Fase 1

Revisa el **portal público** y te deja un **Excel con la propuesta** de verificación.
**No inicia sesión, no abre PDF y no envía nada.** Tú revisas y decides.

## Instalar (una sola vez)
1. Instala Python desde https://www.python.org/downloads/ — marca **"Add python.exe to PATH"**.
2. Doble clic en **`instalar.bat`**.

## Usar
1. Doble clic en **`ejecutar.bat`**.
2. Elige **1** (una institución) o **2** (todas las de `instituciones.txt`, una tras otra).
3. Responde año, mes y cuántos apartados revisar (**para probar pon `3`**). El programa recuerda tus últimas respuestas: Enter = la misma.
4. Si es una institución: escribe su número (el de la dirección, ej. `28` en `portalunico.iaip.gob.hn/28/7/`).
   "¿Desde qué mes?" ya viene lleno con el mes siguiente a tu verificación anterior.
5. Se abre Chrome solo y va despacio (10 a 20 s entre páginas; 1 a 2 minutos entre instituciones).
6. Al terminar se abre el Excel de la carpeta **`resultados`**.

## El Excel
- **Propuesta:** un renglón por apartado.
  - PROPUESTA, casillas a quitar y observación ya escrita.
  - **Docs nuevos:** cuántos documentos aparecieron desde tu verificación anterior.
  - Columnas azules **DECISIÓN FINAL / QUITAR FINAL / OBSERVACIÓN FINAL**: corrígelas tú. La Fase 2 llenará el formulario con eso.
    Si la propuesta es "Revisar", la decisión final queda vacía para que la pongas tú.
- **Alertas:** lo que debes mirar (repetidos, nota aclaratoria, mes que no coincide, NO APLICA, tabla incompleta...).
- **Documentos:** todos los documentos; "Nuevo = Sí" si no estaban la vez anterior.
- **Sin regla:** apartados del menú que no están en tu checklist.
- El Excel **nunca se reemplaza**: si ya existe, se crea otro con la fecha y hora.

## Varias instituciones
Escribe en **`instituciones.txt`** una por línea:  `número ; M o I ; desde` (lo último es opcional).
Al final sale un **resumen_….xlsx** con el conteo de cada institución.

## Si el portal bloquea (Error 1015)
El programa **se detiene solo** y guarda lo leído. Espera una hora y vuelve a correrlo: sigue donde se quedó.

## Volver a revisar lo mismo
Si la institución y el mes ya se leyeron, pregunta si **leer de nuevo** (por si corrigieron) o **usar lo guardado** (no toca el portal, solo recalcula).

## Archivos
- `reglas.json` — tus checklists convertidos en reglas. Si cambias los Excel: `py crear_reglas.py Municipalidades.xlsx Instituciones.xlsx`.
- `comun.py` — las frases y la lógica de decisión.
- `fase1.py` — el programa principal.
- `resultados/` — Excel, lo leído (`lectura_…json`) y el historial para comparar (`historial_…json`).
- `pruebas/servidor_prueba.py` — portal falso para probar sin tocar el real.
