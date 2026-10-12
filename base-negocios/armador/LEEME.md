# El Armador (solo para el proveedor)

Pantalla con clics para armar el programa de cada cliente: rubro, cuestionario de la visita,
módulos, límites, licencia, palabras del rubro y vista previa del menú. **Nunca se entrega al
cliente ni se publica en internet**: corre solo en su computadora (127.0.0.1).

## Abrirlo (un comando)

La primera vez, ponga su clave (10 letras o más; se guarda solo su huella en
`~/.config/base-negocios/armador.clave`, fuera de git):

```bash
node herramientas/servidor_armador.js --poner-clave
```

Cada vez que lo use:

```bash
node herramientas/servidor_armador.js
```

Abra http://127.0.0.1:8095 y escriba su clave. La primera vez prepara la base local de
demostración (`demo_armador`, tarda unos segundos). Ctrl+C para cerrarlo.

## En la visita, paso a paso

1. **Demostración** (opcional, para vender): toque "Crear demo de <rubro>". Sale un enlace y los
   correos (clave de todos: `demo1234`). Ábralo y enséñele al cliente un negocio como el suyo.
2. **Armar cliente > Rubro:** toque el rubro (ferretería, salón, taller, tienda, restaurante).
3. **Cuestionario:** haga las preguntas al dueño y marque sus respuestas. Toque **Sugerir
   módulos**: verá qué conviene y **por qué**. Toque **Usar esta sugerencia**.
4. **Datos del negocio:** nombre, RTN, correo y nombre del dueño, colores y logo.
5. **Módulos:** encienda o apague lo que usted decida. Si falta un módulo que otro necesita,
   sale en rojo explicado (ej.: "Comisiones necesita Ventas") y no deja seguir hasta corregirlo.
6. **Límites y licencia:** usuarios, cajas, sucursales, bodegas; fecha de vencimiento y gracia.
7. **Palabras del rubro:** cómo se llaman las cosas en ese negocio (taller: "Órdenes de trabajo").
8. Mire a la derecha **"Así verá el menú"** con los botones Dueño / Cajero / Vendedor.
9. **Crear** (base local de demostración, por defecto). Sale el enlace de la app y los datos de
   entrada del dueño. Queda `clientes/<cliente>/ficha.json`, `app.json` y `config.js`.

## Cambiar un cliente después (agregar un módulo, ampliar un límite, renovar)

**Clientes > Cambiar** → cambie lo que necesite → **Ver cambios** (vista previa: no cambia nada) →
escriba el identificador del cliente → **Aplicar cambios**. La ficha anterior queda en
`clientes/<cliente>/historial/`. Nunca se borran datos: apagar un módulo solo impide operaciones nuevas.

## Lista de clientes

Paquete, rubro, módulos, uso / límite (en rojo con "(!)" si usa el 80 % o más: ofrézcale una
ampliación), vencimiento de la licencia, versión del núcleo y solicitudes pendientes del cliente.

## Cliente con su propia base (Supabase real)

1. Registre antes al dueño en Supabase (Authentication > Users) con el correo de la ficha.
2. Ponga la clave de la base en `~/.pgpass` de esta computadora (permisos 600). Nunca en el Armador.
3. En "¿Dónde se crea?" elija **Base real del cliente**, pegue la cadena SIN clave y escriba la
   referencia del proyecto para confirmar.
4. Para **aplicar cambios** a una base real hace falta el respaldo cifrado sin preguntar: arranque
   el Armador con `RESPALDO_AGE_DESTINATARIO` o `RESPALDO_CLAVE_ARCHIVO` (ver P-03). Sin eso, no aplica nada.
5. Publique la app con `bash herramientas/armar_app.sh <cliente> <URL> <anon key>` (ver app/LEEME.md).

**Sin terminal hacia la base** (lo normal con el plan gratis): **Clientes > Exportar para Supabase** → pegue el
User UID del dueño → **Descargar SQL** y péguelo en el SQL Editor del proyecto (guía: `docs/SUPABASE.md`, paso 8).

Esto último **no está probado contra Supabase real** (solo contra la base local).

## Cómo funciona por dentro

- `herramientas/servidor_armador.js` (Node 22, sin dependencias) escucha solo en 127.0.0.1, rechaza
  otro "Host", sesión con galleta HttpOnly de 8 horas, 5 claves malas = espera de un minuto.
- Usa las herramientas de siempre: `ficha.py` (validar), `nuevo_cliente.sh` (crear),
  `aplicar_ficha.sh --solo-mostrar` y `aplicar_ficha.sh` (cambiar), `lista_clientes.sh --json`
  (lista) y `conexion.sh` (por `armador_sql.sh`). Ninguna clave de base llega al navegador.
- Marca, categorías, unidades y campos extra de la plantilla se crean **como el dueño** (en la bitácora
  salen con el dueño y el motivo "Armador").
- Plantillas por rubro = datos en `armador/plantillas/*.json` (módulos, perfil, límites, categorías,
  unidades, campos extra, palabras, reportes típicos, colores y datos de la demo). Para un rubro nuevo,
  copie una y cámbiela; no hay que tocar código.
- Reglas del cuestionario: `armador/js/reglas.js`. Vista previa del menú: el mismo `app/js/menu_datos.js` de la app.
- Pruebas: `bash herramientas/probar_armador.sh` (clave y clientes temporales; no toca `clientes/`).

Variables: `PUERTO_ARMADOR` (8095), `PUERTO_APP_CLIENTE` (8096), `BASE_ARMADOR` (demo_armador),
`DIR_CLIENTES`, `ARMADOR_CLAVE_ARCHIVO`, `DEMO_CLAVE`.
