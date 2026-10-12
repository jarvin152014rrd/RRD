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
(ventas, clientes con deuda vencida, cajas, bancos, depósito en tránsito y dos
gastos esperando aprobación). Cada vez que se corre, la demo empieza de cero.

Pruebas en el navegador: `bash herramientas/probar_app.sh` (capturas en
`app-pruebas/capturas/`, no van a git).

## Cómo funciona la demo local

`herramientas/servidor_app.js` (Node 22, sin dependencias) sirve esta carpeta e
imita lo mínimo de Supabase contra la base local: entrar (`/auth/v1/token`, emite
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
| `js/pantallas/*.js` | Una pantalla por archivo: `inicio`, `alertas`, `aprobaciones`, `mas`, `entrar`, `en_construccion`. |

## Agregar una pantalla

1. Cree `js/pantallas/mi_pantalla.js` con `export async function mostrar(vista, ctx) { ... }`
   (arme con `h()`; lea con `rpc()`; escriba con `escribir()`; muestre errores con `cajaError(err)`).
2. En `js/menu.js`, en la subpestaña que corresponda, ponga `pantalla: 'mi_pantalla'`
   (y `modulos` / `permisos` si hace falta: basta uno de cada lista).
3. Agregue el archivo a `CASCARON` en `sw.js` y suba `VERSION`.
4. Agregue su prueba en `app-pruebas/probar_app.cjs`.

Reglas: palabras sencillas; nada gris ni bloqueado (lo que no se puede, no sale);
montos siempre desde centavos con `dinero()`; nunca mostrar el código de error crudo.
