# Prompt maestro — base-negocios (núcleo 0.21.0, app 0.15.0)

> Copie este texto completo al empezar una conversación nueva con Claude (o con otro
> programador). Explica qué es el proyecto, cómo se trabaja y qué falta.

---

## 1. Quién soy y cómo quiero que me ayudes

- Soy Jarvin, de Honduras. **No soy programador de profesión.**
- Respóndeme siempre **en español, con palabras sencillas y solo lo necesario**.
- **Explícame cada cambio antes de hacerlo.**
- En decisiones técnicas importantes, consulta a los agentes **constructor-maestro** (construye)
  y **revisor** (busca errores) y resume sus opiniones antes de decidir. El **asesor-negocio**
  solo para decisiones de negocio o de dinero.
- Forma de trabajo que me funciona: el maestro construye por partes (commit y push al terminar
  cada parte), el revisor revisa al final de cada tanda, se corrige y recién ahí se me entrega.
- Tengo límites de uso: trabaja por partes guardadas para no dejar nada a medias.
- Guíame **paso a paso** cuando tenga que hacer algo yo (Supabase, Netlify), un paso a la vez,
  con amabilidad.

## 2. Reglas que NO se rompen

- **No tocar RRD** (mi negocio de repuestos en uso diario): `index.html`, `VR.html`,
  `BODEGA.html` en la raíz del repositorio. Todo el producto nuevo vive en `base-negocios/`.
- Repositorio `jarvin152014rrd/RRD`, rama de trabajo `claude/hopeful-maxwell-bctd4o` (antes `claude/awesome-albattani-co033f`).
- **Nunca** pedir ni aceptar la clave de la base de datos, la llave `service_role` ni la
  `sb_secret_`. Solo se comparten la URL del proyecto y la llave pública (publishable/anon).
- **Nunca** instalar ni cambiar nada en el proyecto de Supabase "Repuestos-ruta-directa"
  (producción de RRD). El de pruebas es **SistemaAdmin-Pruebas** (organización
  SistemaAdmin-Integral): `https://xkdmkejujqoayjyvrqcs.supabase.co`.
- `clientes/`, `dist/`, `.pgdata` y cualquier secreto van fuera de git.
- Sin emojis ni íconos en lo impreso (facturas, comprobantes, PDF). Sin botón "?" ni videos.
- Las migraciones ya entregadas al dueño **no se editan**: lo nuevo va en una migración nueva
  con su archivo `dist/actualizar_supabase_<versión>.sql`.

## 3. El objetivo

Un programa de administración **sólido y reutilizable** para vender a pequeños y medianos
negocios de Honduras que empiezan y no controlan bien su dinero (tiendas, ferreterías, ropa,
salones, talleres, restaurantes). El centro es **el rastro del dinero**: de dónde viene y a dónde
va cada lempira, control, operación legal (SAR, CAI, ISV, NIIF PYMES) y crecimiento.

- **"Pared con hoyitos":** el **núcleo** es una pared fija y probada donde los números siempre
  cuadran, con cualquier combinación de módulos (no negociable). Los "hoyitos" editables son la
  ficha, los módulos, los impuestos, los catálogos, las palabras y los límites. La "cartulina"
  son los datos de cada negocio.
- **El Armador:** herramienta solo del proveedor (yo) para armar el programa de cada cliente:
  cuestionario, plantillas por rubro, módulos, límites, vista previa, crear/aplicar, demo.
- **Cobro mensual.** Límites (usuarios, cajas, sucursales, bodegas) los pone el proveedor; el
  cliente pide ampliación. Si deja de pagar: solo lectura, nunca bloqueo.
- **Los datos son del cliente:** siempre puede descargarlos. Dentro del programa no se muestran
  versiones ni "desbloqueos".
- El **precio** del producto se decide al final.

## 4. Cómo está hecho

- **Núcleo:** Supabase (Postgres + Auth + RLS). Toda la lógica de dinero en funciones SQL
  todo-o-nada (`SECURITY DEFINER`, `search_path=''`); la app solo llama funciones. Partida doble
  NIIF PYMES, nada se borra (contrapartidas con motivo), montos en centavos (bigint), zona
  America/Tegucigalpa, `id_operacion` por operación (no se duplica), bitácora encadenada a prueba
  de alteraciones, errores con clave (`CLAVE: mensaje`), filtros por sucursal, licencia y límites.
  57 migraciones en `nucleo/sql/migraciones`, **161 pruebas** (`bash herramientas/probar.sh`,
  también `--paquete`).
- **App:** PWA en `app/` (HTML + JavaScript con módulos, sin compilador ni librerías nuevas,
  sin `innerHTML` con datos), íconos propios, funciona sin internet. Pruebas con Playwright
  (`bash herramientas/probar_app.sh`).
- **Armador:** `armador/` (`bash herramientas/probar_armador.sh`).
- **Herramientas:** `herramientas/armar_instalacion.sh` (instalación y actualizaciones en
  `dist/`), `armar_app.sh <cliente> <URL> <llave pública>` (app para Netlify),
  `exportar_supabase.sh` (primer cliente), respaldo y restauración.
- **Documentos clave:** `docs/REQUISITOS.md` (todas mis decisiones), `docs/PENDIENTES.md`,
  `docs/SUPABASE.md` (instalar y actualizar), `docs/SIN_INTERNET.md` y `SIN_INTERNET_GUIA.md`,
  `CHANGELOG.md`, `app/CHANGELOG.md`, `app/PENDIENTES.md`, `nucleo/docs/*.md`.

## 5. Lo que ya hace

- **Inventario (núcleo 0.21.0):** ¿Qué comprar? (lo que más sale, para cuántos días alcanza y cuánto pedir) y Capital
  muerto (lo que no se vende y el dinero parado).
- **Aspecto (app 0.15.0, lo mejor de RRD):** modo oscuro (luna/sol), "Al día" siempre a la vista, buscador general
  (lupa, Ctrl+K: pantallas, productos y clientes), Vender con total grande y Cobrar verde, pagos en tarjetas, listas
  compactas con filtros rápidos (Agotados, Bajo el mínimo, Contado, Crédito...), teclas F2/F9/Esc en Vender,
  Cotizaciones con cifras y WhatsApp, "¿Dónde está mi dinero?" con el total
  grande y "¿Gané o perdí?" como una resta. RRD solo se usó de ejemplo.

- **Inicio:** tablero del dueño (saludo, botones rápidos, cifras con color, gráfica de 7 días,
  lo más vendido con foto, Primeros pasos, Pendientes y campanita). Diseño con íconos y colores
  con significado (verde entra, rojo sale, dorado importante, azul información).
- **Vender:** venta rápida con código de barras o cámara, cotizaciones que pasan a venta,
  apartados, devoluciones y cambio de producto exacto, garantías con reclamos, precio mayorista
  (por cantidad o por cliente), promociones (nunca se suman), facturas con CAI e ISV/RTN.
- **Caja:** turnos con arqueo (faltante/sobrante), cobros (efectivo, tarjeta, transferencia,
  cheque solo en abonos), gastos de caja chica, meter o sacar efectivo.
- **Clientes:** crédito, quién me debe, estados de cuenta, antigüedad de saldos.
- **Inventario:** productos con foto liviana, existencias por bodega, conteo físico, movimientos,
  traslados, Excel de ida y vuelta.
- **Compras:** de contado o al crédito, proveedores, pagos.
- **Dinero:** dónde está mi dinero, todos los gastos (con aprobación y topes), depósitos y
  traslados, cheques por depositar, pagos fijos, fondos y socios (aportes, reparto de utilidad,
  estado de cuenta por socio), cuadrar con el banco, proyección.
- **Reportes:** ¿gané o perdí? (y formato NIIF), ventas, inventario valorizado, empleados y
  comisiones (solo sobre lo cobrado), quién hizo qué (bitácora), antigüedad de saldos, cierre de
  mes (pre-cierre, cerrar, reabrir con motivo). Todo con Excel e Imprimir.
- **Ajustes:** mi negocio (logo y colores con contraste automático), usuarios y permisos, cajas y
  bancos, impuestos, reglas y topes, Excel y copia de mis datos, mi cuenta, alertas que recibo.
- **Sin internet (etapa 1):** barra visible, ventas de contado con efectivo o transferencia
  (por confirmar), se guardan en el equipo y suben solas sin duplicarse, bloques de números CAI
  por caja y equipo, lista "por resolver", facturas de emergencia (talonario de imprenta).
- **Sucursales:** cada empleado solo ve y toca lo de su sucursal.

## 6. Dónde estamos con la instalación real (2 de noviembre de 2026)

- **Supabase de pruebas (SistemaAdmin-Pruebas) ya está en 0.21.0.** Se pegaron en orden las
  actualizaciones 0.16.0 a 0.21.0 y `verificar_instalacion` dijo **TODO BIEN | 0.21.0 | 57 | 57 | LISTO**.
  Empresa de prueba: "Tienda de Ropa Prueba" (dueño: jarvin152014@gmail.com). Registro abierto de usuarios **apagado**.
- **App 0.15.0 publicada en Netlify** (2 de noviembre, "Published", 77 archivos):
  `https://dapper-tarsier-fbd098.netlify.app`. Se armó con `herramientas/armar_app.sh tienda-ropa-prueba
  https://xkdmkejujqoayjyvrqcs.supabase.co <llave pública>` y se subió un .zip con los archivos en la raíz
  (arrastrar a Deploys > "Need to update your project?").
- **Ojo:** como 0.16.0 a 0.21.0 ya están en un Supabase real, **ya no se editan** (056 y 057 incluidas): todo
  cambio nuevo va en una migración nueva (058 en adelante) con su `actualizar_supabase_<versión>.sql`.
- Falta confirmar que la app nueva abre bien y probarla (ver 7, "Siguiente paso").

## 7. Lo que está pendiente

**Siguiente paso (empezar por aquí)**
1. Abrir la app nueva (Ctrl + Shift + R si se ve la vieja; en el celular cerrarla y abrirla) y entrar.
   Se reconoce por la lupa "Buscar… Ctrl K", el punto "Al día" y la luna del modo oscuro.
2. Prueba guiada corta: vender (F2, F9), cobrar, cerrar el turno, modo oscuro, buscador, Inventario >
   ¿Qué comprar? y Capital muerto, Cotizaciones con WhatsApp.
3. Publicar las 2 Edge Functions (crear usuarios y cerrar sesión a distancia): `docs/SUPABASE.md`, paso 9.
4. Probar vender sin internet: preparar el equipo (Ajustes > Sin internet), cortar el internet, vender y volver.
5. Respaldo semanal (`docs/SUPABASE.md`, "Respaldos"; el plan gratis no los deja descargar).

**Seguridad de mis cuentas (lo más importante, lo hago yo)**
- Activar la verificación en dos pasos en Gmail, Supabase, Netlify y GitHub.

**Decisiones mías ya tomadas en la revisión de 0.20.0** (hechas)
- Al resolver una venta sin internet, el efectivo entra al turno abierto de esa caja; si ya se cerró, al turno
  de quien la resuelve, en su caja (la pantalla lo avisa).
- Talonario de emergencia: el dueño o el administrador pueden escribir el precio de la copia en papel, con motivo.

**Decisiones mías por confirmar (tienen respuesta razonable; se ajustan al probar)**
- Tope por turno sin internet: L 50,000.
- Transferencia sin internet marcada "no llegó": queda como deuda y ya no se anula.
- Mientras un equipo tiene números apartados de una caja, esa caja solo vende de contado.
- En garantía no se cobra el ajuste mayorista; el precio normal del ajuste es el de la venta.
- Unas 20 menores: "Decisiones del dueño pendientes de confirmar" en `docs/PENDIENTES.md`.

**Para el contador**
- Revisar SAR, CAI, ISV, libros y NIIF; cuentas de aportes de socios.
- Cómo pedir el CAI del talonario de emergencia y cómo reportar números no usados o anulados.

**Por programar (cuando yo diga)**
- Pequeño: los datos de demostración de "cuadrar con el banco" hacen fallar una prueba los primeros días del mes
  (no es de la app). "¿Gané o perdí?" falla el último día del mes por lo mismo.
- Tanda de seguridad (gratis): verificación en dos pasos en la app para dueño y admin, claves fuertes, "no soy un
  robot" (Cloudflare Turnstile), bloqueo por inactividad con PIN del cajero, aviso de entrada desde equipo nuevo,
  respaldo automático semanal con prueba de recuperación.
- Sin internet, etapa 2: pasar ventas desde las copias en papel de un equipo perdido, hoja de arqueo sin internet,
  catálogo por partes, cifrar los datos del equipo.
- Mejoras propuestas (ideas de RRD): meta de ventas del mes con barra de avance; clientes que dejaron de comprar
  (para volver a llamarlos, con WhatsApp); botón "revisar que todo cuadra"; precio sugerido al crear un producto
  (costo + margen); cotización en PDF; vista para tableta.
- Detalles: bodega de "dañados" para garantías, separar cheques en el resumen de hoy, quitar precio mayorista
  desde Excel, columna "tiene foto" en Excel, limpieza de fotos sueltas.
- Más adelante, solo si los clientes lo piden: rutas de vendedores, mapa de clientes, pedidos a bodega, despacho.

**Después**
- Prueba con muchos datos.
- Prueba real con Repuestos Ruta Directa, en paralelo con mi index, 2 a 4 semanas.
- Para vender: dirección propia, Supabase Pro (respaldos diarios), contrato, soporte y precio.

## 8. Cómo seguir en una conversación nueva

- Pegue este texto completo. El código está en la rama `claude/hopeful-maxwell-bctd4o` del repositorio
  `jarvin152014rrd/RRD`, carpeta `base-negocios/`.
- Lo primero que debe leer Claude: este archivo, `docs/PENDIENTES.md`, `CHANGELOG.md` (núcleo) y `app/CHANGELOG.md`.
- Pruebas antes de entregar algo: `bash herramientas/probar.sh` (núcleo), `bash herramientas/probar.sh --paquete`
  (como en Supabase real), `bash herramientas/probar_app.sh` (app; incluye `probar_0150.cjs` de la 0.15.0).
  `SOLO_PRUEBAS='prueba_(158|161)'` corre solo algunas.
- Paquete para el dueño: `herramientas/armar_instalacion.sh` (instalación y la actualización de la última versión en
  `dist/`); `herramientas/armar_app.sh` (app para Netlify; subir un .zip con los archivos en la raíz).
- En esta rama no están `CLAUDE.md` ni `.claude/agents/` (sí en `claude/awesome-albattani-co033f`): las reglas de
  este prompt los reemplazan; el "revisor" se puede lanzar como un agente general con las instrucciones de revisión.
- Historial de esta etapa: app 0.15.0 (lo mejor de RRD en lo visual, modo oscuro, buscador, filtros, cotizaciones,
  teclas rápidas), núcleo 0.21.0 (¿Qué comprar? y capital muerto) y la revisión de 0.20.0 en tres vueltas.
