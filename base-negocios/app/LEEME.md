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

Copie `config.ejemplo.js` como `app/config.js` con la URL y la clave ANÓNIMA del
Supabase del cliente (sale de `personal/`; `app/config.js` no va a git). Nunca la
llave service_role. Suba la carpeta `app/` a cualquier hosting estático con HTTPS.

## Archivos

| Archivo | Para qué |
|---|---|
| `index.html` | Página única. Carga tema → base → controles y `js/app.js`. |
| `manifest.webmanifest`, `iconos/` | Instalar como app (PWA). |
| `sw.js` | Guarda solo el cascarón (HTML/CSS/JS). Los datos siempre del servidor. Suba `VERSION` al cambiar archivos y agregue los nuevos a `CASCARON`. |
| `config.ejemplo.js` | Modelo de la configuración por cliente. |
| `css/tema.css` | Solo colores y letras (ficha del cliente). |
| `css/base.css` | Acomodo: encabezado, pestañas, tarjetas, barra del celular (< 700 px). |
| `css/controles.css` | Botones, campos, diálogos (44 px, letra 15-16 px). Va al final: el tema no lo rompe. |
| `js/app.js` | Arranque, entrar/salir, menú y rutas `#/pestana/subpestana`, aviso "Sin conexión". |
| `js/api.js` | Cliente de datos: `entrar`, `salir`, `rpc`, `escribir` (con id_operacion), `leer`. |
| `js/sesion.js` | Perfil (`mi_perfil`) en memoria, `puede()`, `tieneModulo()`, revisión periódica de `mi_estado_sesion`. |
| `js/menu.js` | Lista de pestañas y subpestañas con módulo y permiso de cada una. |
| `js/errores.js` | Traduce errores con `error_catalogo` (mensaje sencillo + qué hacer). |
| `js/formato.js` | `dinero(centavos)` → "L 1,234.56", fechas locales. |
| `js/ui.js` | `h()` para armar pantallas sin innerHTML, avisos, diálogo de motivo, íconos. |
| `js/datos.js` | Listas compartidas en memoria un minuto: productos, clientes, cajas, cuentas de dinero, mi turno; `filtrar()` sin tildes. |
| `js/comprobante.js` | Comprobante de venta (`documento_venta`), impresión de 80 mm y texto para WhatsApp. |
| `js/marca.js` | Nombre comercial, logo y colores del negocio (`marca_empresa`); cambia solo variables de color. |
| `js/excel.js` | Arma y lee el `.xlsx` (columnas azules/grises, hoja Instrucciones) para `exportar_plantilla` / `importar_*`. |
| `vendor/xlsx.bundle.js` | SheetJS (`xlsx-js-style` 1.2.0, licencia Apache 2.0 en `vendor/`), copia local: funciona sin internet. Se carga solo al usar Excel. |
| `js/pantallas/*.js` | Una pantalla por archivo: `inicio`, `alertas`, `aprobaciones`, `mas`, `entrar`, `en_construccion`, `vender` (carrito; también lo usa `cotizaciones`), `ventas_dia`, `cotizaciones`, `devoluciones`, `caja_turno`, `caja_dinero`, `caja_gasto`, `clientes`, `me_deben`; Inventario: `inv_productos`, `inv_existencias`, `inv_conteo`, `inv_movimientos`, `inv_traslados`, `inv_excel`; Ajustes: `aj_negocio`, `aj_usuarios`, `aj_cajas`, `aj_impuestos`, `aj_reglas`, `aj_datos`. |

## Agregar una pantalla

1. Cree `js/pantallas/mi_pantalla.js` con `export async function mostrar(vista, ctx) { ... }`
   (arme con `h()`; lea con `rpc()`; escriba con `escribir()`; muestre errores con `cajaError(err)`).
2. En `js/menu.js`, en la subpestaña que corresponda, ponga `pantalla: 'mi_pantalla'`
   (y `modulos` / `permisos` si hace falta: basta uno de cada lista).
3. Agregue el archivo a `CASCARON` en `sw.js` y suba `VERSION`.
4. Agregue su prueba en `app-pruebas/probar_app.cjs`.

## Cómo se usa (0.3.0)

- **Inventario > Productos:** busque, toque **Ver**. **Nuevo producto** pide código, nombre, precio y si incluye
  ISV. **Cambiar precio** pide el precio nuevo y el motivo (queda en el historial). **Desactivar** no borra nada.
- **Inventario > Conteo físico:** elija la bodega, escriba lo que contó (no se ve lo del sistema), toque **Enviar
  conteo a aprobación**. La existencia cambia cuando el admin o el dueño aprueba en Inicio > Aprobaciones.
- **Inventario > Excel:** 1) **Descargar Excel**, 2) cambie las columnas azules y súbalo: verá qué pasará fila por
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
