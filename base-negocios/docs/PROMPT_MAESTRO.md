# Prompt maestro — base-negocios (núcleo 0.20.0, app 0.15.0)

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
  56 migraciones en `nucleo/sql/migraciones`, **158 pruebas** (`bash herramientas/probar.sh`,
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

- **Aspecto (app 0.15.0, lo mejor de RRD):** modo oscuro (luna/sol), "Al día" siempre a la vista, buscador general
  (lupa, Ctrl+K: pantallas, productos y clientes), Vender con total grande y Cobrar verde, pagos en tarjetas, listas
  compactas con filtros rápidos (Agotados, Bajo el mínimo, Contado, Crédito...), "¿Dónde está mi dinero?" con el total
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

## 6. Dónde estamos con la instalación real

- Supabase de pruebas instalado en **0.15.0** con la "Tienda de Ropa Prueba" (dueño:
  jarvin152014@gmail.com). Registro abierto de usuarios **apagado**.
- App publicada en Netlify: `https://dapper-tarsier-fbd098.netlify.app` (versión vieja).
- **Falta pegar en orden** las actualizaciones 0.16.0, 0.17.0, 0.18.0, 0.19.0 y 0.20.0, luego
  `verificar` (debe decir TODO BIEN | 0.20.0 | 56 | 56) y subir la app 0.15.0 a Netlify (incluye todo lo de la 0.14.0).
  Nada de 0.16 a 0.20 se ha probado todavía en un Supabase real.

## 7. Lo que está pendiente

**Revisión**
- El revisor debe revisar la **0.20.0 (vender sin internet)**: su revisión se cortó por el límite
  de uso. Corregir lo que encuentre dentro de la misma migración 056 (aún no entregada al dueño).

**Decisiones mías por confirmar**
- Tope por turno sin internet: L 50,000.
- Transferencia sin internet marcada "no llegó": queda como deuda y ya no se anula.
- Mientras un equipo tiene números apartados de una caja, esa caja solo vende de contado.
- En garantía no se cobra el ajuste mayorista; el precio normal del ajuste es el de la venta.
- Unas 20 decisiones menores ya tienen respuesta razonable (ver "Decisiones del dueño
  pendientes de confirmar" en `docs/PENDIENTES.md`); se ajustan al probar.

**Para el contador**
- Revisar SAR, CAI, ISV, libros y NIIF; cuentas de aportes de socios.
- Cómo pedir el CAI del talonario de emergencia y cómo reportar números no usados o anulados.

**Por programar**
- Tanda de seguridad (gratis): verificación en dos pasos en la app para dueño y admin, claves
  fuertes, "no soy un robot" (Cloudflare Turnstile), bloqueo por inactividad con PIN del cajero,
  avisos de entrada desde equipo nuevo, respaldo automático semanal con prueba de recuperación.
- Sin internet, etapa 2: pantalla para pasar ventas desde copias en papel de un equipo perdido,
  hoja de arqueo sin internet, catálogo por partes, cifrar datos del equipo.
- Pequeños: bodega de "dañados" para garantías, separar cheques en el resumen de hoy, quitar
  precio mayorista desde Excel, columna "tiene foto" en Excel, limpieza de fotos sueltas.
- Más adelante, solo si los clientes lo piden: rutas de vendedores, mapa de clientes, pedidos a
  bodega, preparación y despacho.

**Para mí (paso a paso)**
- Activar la verificación en dos pasos en Gmail, Supabase, Netlify y GitHub (lo más importante).
- Pegar las actualizaciones y subir la app; publicar las 2 Edge Functions (crear usuarios y
  cerrar sesión a distancia); hacer el respaldo semanal.

**Después**
- Prueba con muchos datos.
- Prueba real con Repuestos Ruta Directa, en paralelo con mi index, 2 a 4 semanas.
- Para vender: dirección propia, Supabase Pro (respaldos diarios), contrato, soporte y precio.
