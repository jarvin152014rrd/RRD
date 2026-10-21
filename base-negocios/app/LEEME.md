# app/ — el programa (PWA)

Un solo programa para computadora y celular. HTML + JavaScript en módulos ES,
sin compilador ni frameworks. La app solo muestra datos y llama funciones del
servidor (RPC de Supabase); nunca calcula ni guarda dinero por su cuenta y nunca
escribe tablas directo. Cada operación que escribe manda un `p_id_operacion` (uuid).

## Ver la demo (un comando)

```bash
bash herramientas/demo_app.sh
```

Abra http://127.0.0.1:8080 — usuarios `dueno@demo.hn`, `admin@demo.hn`,
`cajero@demo.hn`, `vendedor@demo.hn`, clave `demo1234`. Es una ferretería falsa
(ventas, clientes con deuda vencida, cajas, bancos, depósito en tránsito, dos
gastos esperando aprobación y dos promociones para la pintura). Cada vez que se corre, la demo empieza de cero.

Pruebas en el navegador: `bash herramientas/probar_app.sh` (capturas en
`app-pruebas/capturas/`, no van a git).

## Cómo funciona la demo local

`herramientas/servidor_app.js` (Node 22, sin dependencias) sirve esta carpeta e
imita lo mínimo de Supabase contra la base local (y la Edge Function `crear-usuario`, pendiente en Supabase
real: ver PENDIENTES): entrar (`/auth/v1/token`, emite
un JWT con `sub`, `role=authenticated` y `session_id`), salir, `POST /rest/v1/rpc/<fn>`
y lecturas simples `GET /rest/v1/<vista>?col=eq.valor`. Cada llamada corre con
`SET LOCAL ROLE authenticated` y `request.jwt.claims`, como el simulador de las
pruebas, así los permisos y RLS son los reales. El emulador SQL
(`herramientas/emulador_supabase.sql`) solo existe en la base de demo.

## Publicar para un cliente

Un comando arma la carpeta lista para Netlify (guía completa para el dueño: `docs/SUPABASE.md`):

```bash
bash herramientas/armar_app.sh <cliente> https://<ref>.supabase.co <anon key>
```

Deja `dist/app-<cliente>/` (no va a git) con `config.js` (`modo: 'supabase'`, URL, clave ANÓNIMA o
"publishable", rubro y palabras de `clientes/<cliente>/app.json`) y `_headers` (CSP que solo deja hablar
con ese Supabase, sin marcos, nosniff; `sw.js` y `config.js` sin caché para que las versiones nuevas
lleguen solas). Se arrastra la carpeta a Netlify (Deploy manually). No hace falta `_redirects`: la app
navega con `#/…`. La herramienta **rechaza** la llave service_role o `sb_secret_…` y revisa que no quede
ninguna llave secreta en la carpeta.

Con `modo: 'supabase'` la app usa las Edge Functions de `supabase/functions/` (publicarlas: paso 9 de
`docs/SUPABASE.md`): `crear-usuario` (Agregar usuario) y `cerrar-sesion-remota` (Cerrar sesión a distancia:
cierra en la base y además borra sus sesiones de Supabase Auth). Sin `modo` (la demo) todo sigue igual:
`servidor_app.js` imita `crear-usuario` y el cierre usa la RPC `cerrar_sesion_usuario`.

## Archivos

| Archivo | Para qué |
|---|---|
| `index.html` | Página única. Carga tema → base → controles y `js/app.js`. |
| `manifest.webmanifest`, `iconos/` | Instalar como app (PWA). |
| `sw.js` | Guarda solo el cascarón (HTML/CSS/JS). Los datos siempre del servidor. Suba `VERSION` al cambiar archivos y agregue los nuevos a `CASCARON`. |
| `config.ejemplo.js` | Modelo de la configuración por cliente. |
| `css/tema.css` | Solo colores y letras (ficha del cliente) y los colores con significado fijo: verde = entra dinero/bien, rojo = sale dinero/problema, dorado = importante/hoy, azul = información. |
| `css/base.css` | Acomodo: encabezado, pestañas, tarjetas, barra del celular (< 700 px). |
| `css/controles.css` | Botones, campos, diálogos (44 px, letra 15-16 px). Va al final: el tema no lo rompe. |
| `js/app.js` | Arranque, entrar/salir, menú y rutas `#/pestana/subpestana`, aviso "Sin conexión". |
| `js/api.js` | Cliente de datos: `entrar`, `salir`, `rpc`, `escribir` (con id_operacion), `leer`. |
| `js/sesion.js` | Perfil (`mi_perfil`) en memoria, `puede()`, `tieneModulo()`, revisión periódica de `mi_estado_sesion`. |
| `js/menu.js` | Menú del usuario (módulos + permisos) con las palabras del rubro (`config.palabras`). |
| `js/menu_datos.js` | Lista de pestañas y subpestañas (datos puros, sin importar nada): la usa también la vista previa del Armador. |
| `js/errores.js` | Traduce errores con `error_catalogo` (mensaje sencillo + qué hacer). |
| `js/formato.js` | `dinero(centavos)` → "L 1,234.56", fechas locales. |
| `js/ui.js` | `h()` para armar pantallas sin innerHTML, avisos, diálogo de motivo y las piezas visuales: `chip`, `chipEstado` (pagada, pendiente, vencida, anulada, en espera de aprobación…), `burbuja`, `titulo` (con ícono dorado), `monto` (verde entra, rojo sale), `tarjetaCifra`, `botonAccion`, `filaIcono`, `tabla` (en el celular se ve como tarjetas), `graficaBarras`, `estadoVacio` (con botones para empezar), `mensaje`, `cabezaPantalla` (título con las subpestañas al lado). |
| `js/iconos.js` | Íconos de línea propios (`icono('vender')`), dentro de la app: sin internet. Nunca en lo impreso. |
| `js/datos.js` | Listas compartidas en memoria un minuto: productos, clientes, proveedores, cajas, bodegas, cuentas de dinero, categorías de gasto, mi turno y si el usuario está limitado a su sucursal (`alcance`); `filtrar()` sin tildes. Se borran al salir. |
| `js/formularios.js` | Piezas de formulario de Compras y Dinero: elegir caja o banco con su saldo, monto, fecha, dato, cifra chica, "vence en N días". |
| `js/comprobante.js` | Comprobante de venta (`documento_venta`), impresión de 80 mm y texto para WhatsApp. Pasa por `imprimible.js`. |
| `js/imprimible.js` | Lo impreso solo lleva texto y líneas: quita emojis y dibujos de comprobantes, WhatsApp y del título al imprimir (los datos guardados no cambian). |
| `js/marca.js` | Nombre comercial, logo y colores del negocio (`marca_empresa`). Cambia solo el color principal y el de acento, con **contraste automático** (texto blanco u oscuro, AA); los colores con significado no cambian. Recuerda la marca en el equipo para la pantalla de entrar. |
| `js/excel.js` | Arma y lee el `.xlsx` (columnas azules/grises, hoja Instrucciones) para `exportar_plantilla` / `importar_*`. |
| `vendor/xlsx.bundle.js` | SheetJS (`xlsx-js-style` 1.2.0, licencia Apache 2.0 en `vendor/`), copia local: funciona sin internet. Se carga solo al usar Excel. |
| `js/pantallas/*.js` | Una pantalla por archivo: `inicio`, `pendientes` (usa `alertas` y `aprobaciones`), `dinero_donde`, `mas`, `entrar`, `en_construccion`, `vender` (carrito; también lo usa `cotizaciones`), `ventas_dia`, `cotizaciones`, `devoluciones`, `caja_turno`, `caja_dinero`, `caja_gasto`, `clientes`, `me_deben`; Compras: `compras`, `compras_proveedores`, `compras_pagos`; Dinero: `dinero_gastos`, `dinero_depositos`, `dinero_pagos_fijos`, `dinero_fondos`, `dinero_banco`, `dinero_proyeccion`; Inventario: `inv_productos`, `inv_existencias`, `inv_conteo`, `inv_movimientos`, `inv_traslados`, `inv_excel`; Ajustes: `aj_negocio`, `aj_usuarios`, `aj_cajas`, `aj_impuestos`, `aj_reglas`, `aj_datos`. |

## Agregar una pantalla

1. Cree `js/pantallas/mi_pantalla.js` con `export async function mostrar(vista, ctx) { ... }`
   (arme con `h()`; lea con `rpc()`; escriba con `escribir()`; muestre errores con `cajaError(err)`).
2. En `js/menu_datos.js`, en la subpestaña que corresponda, ponga `pantalla: 'mi_pantalla'`
   (y `modulos` / `permisos` si hace falta: basta uno de cada lista). Toda subpestaña lleva `icono`
   (un nombre de `js/iconos.js`); la prueba falla si falta. Si cambia una ruta, agregue la vieja a `RUTAS_VIEJAS`.
3. Agregue el archivo a `CASCARON` en `sw.js` y suba `VERSION`.
4. Agregue su prueba en `app-pruebas/probar_app.cjs` (Compras y Dinero: `app-pruebas/probar_compras_dinero.cjs`).

## Cómo se usa Compras (0.7.0)

- **Registrar una compra:** Compras > Compras > **Nueva compra**. Elija el proveedor, escriba el número de la
  factura, busque cada producto y escriba cuántos y cuánto costó cada uno **sin ISV**. Diga si es **al crédito**
  (sale cuándo vence) o **de contado** (elija de qué caja o banco sale). Toque **Guardar compra** y confirme.
  Revise que el subtotal, el ISV y el total cuadren con la factura de papel.
- **Pagar a un proveedor:** Compras > Pagar a proveedores. Lo rojo ya venció. Toque **Pagar**, escriba cuánto
  paga (todo o una parte), elija de qué caja o banco sale y confirme.
- **Anular:** abra la compra (**Ver**) y toque **Anular compra**; escriba el motivo. Si ya tenía pagos, anule
  primero los pagos (abajo, en la misma compra).
- **Proveedores:** **Nuevo proveedor** con su RTN y los días de plazo que le da. En **Ver** está lo que le debe
  y todo lo que le ha comprado y pagado.

## Cómo se usa Dinero (0.7.0)

- **Un gasto pagado del banco u otra caja:** Dinero > Todos los gastos > **Registrar un gasto**. Elija de dónde
  sale, en qué se gastó y el monto. Si pasa su tope, queda esperando que el dueño lo apruebe.
- **Llevar efectivo al banco:** Dinero > Depósitos y traslados > **Mover dinero** > Depositar al banco. Cuando lo
  vea en el banco, toque **Confirmar depósito**.
- **Pagos fijos:** anote una vez el alquiler, la luz o la planilla. Cuando pague, toque **Pagar ahora** y escriba
  el monto real.
- **Cuadrar con el banco:** elija el banco y el mes, suba el CSV del estado de cuenta y el saldo final. Lo que
  coincide se marca solo; elija uno del banco y uno del programa y toque **Marcar como el mismo**; las comisiones
  e intereses se crean con un botón. Cuando dice "Cuadra", toque **Cerrar este mes**.
- **Proyección:** cuánto dinero tendrá cada semana. Si una semana sale en rojo, cobre antes o mueva pagos.

## Cómo se usa (0.6.0)

- **Todas las pantallas** tienen el estilo de Inicio: títulos con ícono, montos en verde (entra dinero) o rojo
  (sale o falta) y chips de estado (pagada, pendiente, vencida, anulada, en espera de aprobación).
- **Pantallas vacías que enseñan:** si todavía no hay productos, clientes, ventas o cajas, sale un dibujo, una
  frase y el botón para empezar (por ejemplo "Agregar el primero" y "Subir mi Excel"), solo si usted puede.
- **Después de cada acción** sale un mensaje con lo que pasó: "Venta T-… guardada · L 850.00 en efectivo",
  "Gasto de L 150.00 guardado · sale de Caja chica", "Turno #3 cerrado · faltante L 50.00" (en rojo).
- **En el celular** las tablas se ven como tarjetas, con lo principal arriba y los botones grandes.
- **Ajustes > Mi cuenta > Alertas que recibo:** marque o desmarque qué avisos le llegan y toque
  **Guardar mis alertas**. Solo cambia lo que usted ve.
- **Ajustes > Mi negocio:** al cambiar logo o colores, la vista previa muestra el encabezado tal como quedará.
  Si elige un color claro, las letras de encima se ponen oscuras solas para que se lean.
- **Entrar:** muestra el logo y el nombre del negocio que se usó la última vez en ese equipo.

## Cómo se usa Inicio (0.5.0)

- Arriba: saludo, la fecha y cómo está su caja. Los botones grandes hacen lo de todos los días: **Vender**,
  **Cobrar a un cliente**, **Registrar un gasto** y **Abrir/Cerrar mi caja** (cada quien ve solo los suyos).
- Las cifras: verde es dinero que entra, rojo lo que sale o está vencido, dorado lo importante.
- **Primeros pasos** (dueño y admin): toque **Hacerlo** en cada paso; la lista se va sola al terminar.
- La **campanita** dice cuántos pendientes hay; tóquela para ver alertas y aprobar o rechazar.

## Cómo se usa (0.3.0)

- **Inventario > Productos:** busque, toque **Ver**. **Nuevo producto** pide código, nombre, precio y si incluye
  ISV. **Cambiar precio** pide el precio nuevo y el motivo (queda en el historial). **Desactivar** no borra nada.
- **Inventario > Conteo físico:** elija la bodega, escriba lo que contó (no se ve lo del sistema), toque **Enviar
  conteo a aprobación**. La existencia cambia cuando el admin o el dueño aprueba en Inicio > Pendientes.
- **Ajustes > Excel y copia de mis datos** (antes Inventario > Excel; Productos tiene el botón "Subir Excel"): 1) **Descargar Excel**, 2) cambie las columnas azules y súbalo: verá qué pasará fila por
  fila, 3) **Guardar cambios** (solo se habilita sin errores; pide motivo; se guarda todo o nada).
- **Inventario > Traslados:** elija de qué bodega a cuál, agregue productos y cantidades, **Trasladar**. Lo que
  llega de otra sucursal se confirma con **Confirmar recepción**.
- **Ajustes > Usuarios y permisos:** **Agregar usuario** (correo, nombre, puesto, clave temporal). Si llegó al
  límite del plan, toque **Solicitar ampliación**. El dueño marca qué puede hacer cada puesto (pide motivo).
- **Ajustes > Mi negocio:** nombre comercial, logo y colores; vea la vista previa, **Guardar**; si no le gustó,
  **Volver al anterior**.
- **Caja > Cobrar a clientes** (también el cajero): **Cobrar**, escriba el monto y la forma de pago.

### 0.2.0

- **Vender:** escriba o escanee el código (lector USB o botón Cámara) y Enter. Cambie cantidad o descuento; si
  hay varias promociones, viene marcada la que más descuenta y puede elegir otra. Elija cliente si es al
  crédito, la forma de pago, escriba lo recibido (sale el vuelto) y toque **Cobrar**. Imprima o mande el
  comprobante por WhatsApp. Si el descuento pasa su tope, la venta queda esperando aprobación.
- **Caja > Mi turno:** abra el turno contando el fondo; al final toque **Cerrar turno**, cuente el dinero (total o
  billetes) y después verá lo que debía haber y la diferencia.
- **Clientes:** busque, abra la ficha y toque **Cobrar abono**. "Quién me debe" ordena por lo vencido y tiene
  "Cobrar por WhatsApp".

El total, el ISV y si el descuento pide aprobación los calcula el servidor (`calcular_venta_previa`, núcleo
0.13.2; desde 0.14.0 también el subtotal y el descuento con ISV: Subtotal − Descuento = Total) con la misma regla de la venta; la app solo muestra. El vuelto mientras se escribe es solo una ayuda: el
que vale es el que devuelve el servidor.

Reglas: palabras sencillas; nada gris ni bloqueado (lo que no se puede, no sale);
montos siempre desde centavos con `dinero()`; nunca mostrar el código de error crudo.
