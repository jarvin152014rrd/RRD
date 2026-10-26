# Vender sin internet — diseño (todavía NO programado)

Estado: **diseño para que el dueño decida**, versión 2 (con la revisión del revisor). No hay código de esto en el núcleo
0.19.0 ni en la app 0.13.0. Cuando el dueño apruebe las decisiones del final, se programa en etapas, cada una con sus
pruebas.

Los cambios de la revisión van marcados con su código para poder seguirlos: **G1-G6** (graves, obligatorios antes de
programar), **M1-M7** (medios), **m** (menores) y **CAI** (numeración fiscal). Lista completa en el punto 16.

Regla de siempre (REQUISITOS, "Reglas generales"): *un solo cerebro* (el dinero lo decide el servidor) y *sin
internet: solo venta rápida y cobro, con cola local, id_operacion y rango CAI por caja; todo lo demás requiere
conexión*. Aquí **"cobro" significa cobrar la venta en la caja, no abonos de clientes** (decisión 3). Este diseño respeta
eso: el equipo **anota** la venta y la **sube** después; el servidor la vuelve a revisar toda y es quien la registra en
los libros.

---

## 1. En palabras sencillas

Cuando se va el internet, la caja sigue vendiendo de contado. Cada venta se guarda primero en el equipo (la computadora
o el celular), después se imprime su comprobante con su número de verdad (original y copia) y queda en una lista "por
subir". Arriba sale siempre una barra: **"Sin conexión: 3 ventas guardadas en este equipo"**. Cuando vuelve el
internet, el equipo las sube solas, en orden. El servidor revisa cada una otra vez (precio, existencias, usuario, turno,
fecha y número). Si todo está bien, queda registrada igual que una venta normal. Si algo no cuadra, **no se pierde**:
queda en "Ventas sin internet por resolver" para que el supervisor decida.

La app **abre sin internet** en un "modo sin internet" si ese usuario ya se preparó en ese equipo (G1).

## 2. Qué se puede hacer sin internet (recomendación: lo mínimo seguro)

| Acción | ¿Sin internet? | Recomendación |
|---|---|---|
| Vender de contado en **efectivo** | Sí | Etapa 1. Es lo que más se necesita. |
| Vender con **tarjeta** (POS del banco que funciona solo) | Sí, con el número de voucher | Etapa 1, si el POS imprime voucher sin internet. |
| Ver productos, precios y existencias (de la última vez que hubo internet) | Sí (solo mirar) | Etapa 1, con la hora de la última actualización a la vista. |
| Reimprimir el comprobante de una venta hecha sin internet | Sí | Etapa 1. |
| Abrir o cerrar el turno de caja | **No** | Se abre y se cierra con internet. Sin internet se vende dentro del turno ya abierto. Si al final del día no hay internet: ver M4. |
| Cobrar abonos de clientes | **No (etapa 2)** | El saldo del cliente puede estar viejo (otro cajero ya cobró). |
| Gastos de caja | **No (etapa 2)** | Piden comprobante (foto) y a veces aprobación. |

**M4. Cerrar el turno sin internet:** la app no cierra el turno sin internet. El cajero cuenta el efectivo, lo anota en
papel (la app muestra una hoja "Arqueo pendiente" para imprimir con lo contado por denominación) y el turno se cierra
cuando vuelve el internet, después de subir todas las ventas, con lo anotado. Etapa 1.5 (después): guardar el arqueo en
la cola, **después de las ventas**, y que se suba solo.

## 3. Qué NO se puede hacer sin internet, y por qué

- **Ventas al crédito:** hay que revisar el límite y lo que el cliente debe HOY; eso solo lo sabe el servidor.
- **Transferencias, cheques, saldo a favor y vales:** se confirman contra el banco o contra un saldo que puede gastarse
  dos veces en dos equipos a la vez.
- **Descuentos manuales y todo lo que pide aprobación:** quien aprueba está en el servidor. Sin internet solo se aplican
  las promociones vigentes y el precio mayorista que ya se bajaron.
- **Devoluciones, cambios, anulaciones y garantías:** mueven dinero ya registrado y piden ver la venta en el servidor.
- **Cotizaciones, apartados, compras, inventario, cierres, reportes, Ajustes:** no son urgentes y usan datos de todos.
- **Entrar por primera vez en un equipo** (o un usuario que nunca se preparó en él): la contraseña la revisa el servidor.
- **"Ticket ahora y factura después" (CAI): NO** para un negocio que solo da factura. La factura se entrega en el momento.

## 4. Cómo se guarda en el equipo

### 4.1 Dos bases (G6)
- **Base del EQUIPO** `negocio-equipo-<empresa>` (no es de un usuario y **nunca se borra al salir**): el registro del
  equipo, sus **bloques de números con su contador** y la **cola de ventas por subir** (cada venta dice qué usuario la
  hizo). Así, si cambia el usuario, el contador del bloque no vuelve a empezar y no se repiten números.
- **Base del USUARIO** `negocio-<empresa>-<usuario>`: el **perfil sin internet** (G1) y el **catálogo**. El catálogo se
  borra al salir; el perfil sin internet se borra al salir si no quedan ventas suyas por subir.

### 4.2 Guardar la venta: una sola transacción (G6)
En **una sola transacción de IndexedDB** sobre la base del equipo: tomar el siguiente número del bloque, avanzar el
contador y guardar la venta completa en la cola. **Solo después** se imprime. Si la transacción falla, **no hay venta**
(no se imprime nada y el número no se usa). Nunca se imprime un número que no quedó guardado.

### 4.3 Que el navegador no borre nada (M1)
- Al preparar el equipo se pide `navigator.storage.persist()` y se muestra si el navegador lo concedió ("Este equipo
  guarda las ventas de forma segura" / "Este navegador puede borrar datos: no se puede vender sin internet aquí").
- **No se vende sin internet** en modo incógnito (o privado) ni si `persist()` fue negado.
- En **iPhone/iPad** se exige la **app instalada** en la pantalla de inicio (Safari borra los datos de los sitios no
  instalados después de unos días sin uso).
- Las versiones nuevas de la base **solo agregan** estructura (almacenes o índices); **nunca** borran ni vacían la
  cola. Si otra pestaña tiene abierta una versión vieja (`onversionchange` / `onblocked`), se avisa "Cierre las otras
  pestañas de la app" y no se sigue hasta que se cierren.
- Prueba automática: la lista del cascarón de `sw.js` se compara con los archivos reales de `app/` (en 0.13.0 faltaban
  dos; no debe volver a pasar).

### 4.4 Salir, otro usuario y respaldo
- **Salir con ventas sin subir:** sin internet la app no deja salir si hay ventas de ese usuario en la cola ("Conéctese
  para subir las 3 ventas antes de salir").
- **Otro usuario entra en el mismo equipo** (con internet): ve solo lo suyo. Las ventas del primero siguen en la cola
  del equipo y se suben cuando él vuelve a entrar. **M2:** si el que entra es el **dueño** (permiso nuevo
  `ventas.subir_ajenas`), ve "**Ventas de otros usuarios guardadas en este equipo**" y las sube desde ahí, sin archivo;
  quedan a nombre del cajero que las hizo y "subidas por" el dueño, con motivo.
- **Respaldo en archivo:** botón "Guardar respaldo de las ventas por subir" solo para un equipo que se va a dañar o
  formatear; el archivo lo sube el dueño en otro equipo con `ventas.subir_ajenas`.

### 4.5 ¿Cifrado?
Recomiendo **no** cifrar con una clave propia en la etapa 1: una clave guardada en el mismo navegador protege poco y
complica recuperar ventas si algo falla. Se protege así: se guardan solo los datos necesarios (sin costos, sin saldos de
clientes), el catálogo se borra al salir, el equipo debe tener bloqueo de pantalla y la cola no tiene contraseñas ni
tokens. Si más adelante se quiere cifrar: WebCrypto (AES-GCM) con una llave que no se puede sacar del navegador.

## 5. Qué se baja antes para poder vender sin internet

Con internet, la app baja y guarda (botón "Preparar para trabajar sin internet", al abrir el turno y cada 15 minutos).
**m:** desde la segunda vez se baja **solo lo que cambió** (por versión de la foto).

| Dato | Detalle |
|---|---|
| Productos activos | código, código de barras, nombre, unidad, si acepta decimales, impuesto y "precio incluye ISV", precio de la sucursal de la caja, precio mayorista y "desde cantidad", servicio o bien |
| Existencias | de la bodega de la caja, solo para mirar (con la hora) |
| Clientes | nombre, RTN y si es mayorista (sin saldos ni límites) |
| Promociones vigentes | con sus fechas (una venta fuera de fechas no la usa) |
| Impuestos | código y tasa |
| Reglas de la empresa | documento de venta (factura o ticket), turnos, quién cobra, topes sin internet |
| Turno y caja | el turno abierto del usuario y su caja |
| Bloque de números | facturas (CAI) y tickets reservados para ese equipo (punto 6) |
| Hora del servidor | para comparar con el reloj del equipo |
| Perfil sin internet (G1) | usuario, empresa, rol y si tiene `ventas.sin_internet`, caja, turno, si hay token de renovación, fin de la licencia |

**G5. Foto versionada del catálogo:** cada vez que `preparar_sin_internet` entrega un catálogo, el servidor guarda una
**foto** con su número de versión (precios, mayorista, promociones e impuestos tal como se entregaron, a nombre de ese
equipo). Cada venta sin internet dice con qué versión se hizo. Al subir, el servidor **calcula con los datos de esa
foto** (no con los de hoy); el precio debe ser igual al de la foto o al de hoy; cualquier otro va a "por resolver".
Esto también resuelve **M6** (promociones o impuestos que cambiaron mientras no había internet).

**M4. Validez:** el catálogo sirve para vender sin internet **24 horas** después de bajarlo (**configurable** por el
dueño). Pasado ese tiempo la app no deja vender sin internet ("Los precios tienen más de 24 horas: conéctese").

## 6. Cómo se numeran las ventas sin internet

### 6.1 Tickets internos
Con internet el servidor da el número (T-001-001-00000012). Sin internet el equipo usa un **bloque de tickets reservado**
para él. El número impreso es el definitivo.

### 6.2 Facturas con CAI
La ley exige que las facturas de un rango CAI salgan **correlativas** (sin saltos ni repetidos) y en orden de fecha.
Hoy el servidor numera cada caja (`interno.asignar_numero_fiscal`). Propuesta:

1. **Reservar un bloque por caja y equipo mientras hay internet** (`reservar_bloque_numeros`). **m:** el tamaño es
   **configurable** y se sugiere según el promedio de ventas de esa caja (por ejemplo, 1.5 veces las ventas de un día).
2. **Mientras el bloque está activo, esa caja numera SOLO desde el bloque**, con o sin internet: el número lo pone el
   equipo y el servidor lo revisa (ver G2: en esa caja toda venta de contado pasa por la cola).
3. **No se repiten entre equipos:** cada caja (punto de emisión) es de un solo equipo a la vez y los bloques no se cruzan.
4. **CAI - Duración:** el bloque dura **hasta cerrar el turno** o hasta la **fecha límite del CAI** (lo que llegue
   primero). Las **48 horas** solo cuentan para un equipo que **no vuelve** (después de 48 h sin noticias, el bloque pasa
   a "por conciliar" y se avisa al dueño).
5. **G4 - Devolver números:** el servidor **solo recibe números de vuelta cuando el MISMO equipo los devuelve, después
   de subir todo** (al cerrar el turno). Un bloque **vencido sin devolver sigue apartado** hasta que se concilie (nadie
   más usa esos números). La **numeración en línea de esa caja sigue DESPUÉS del final del bloque**; los números que el
   equipo devolvió se usan primero por el servidor solo si todavía no se emitió nada después del bloque (así sigue
   correlativo); si ya se emitió, se reportan como no usados (6.4).
6. **Alerta "por agotarse":** si al bloque le quedan pocos números, la app avisa; sin bloque o con el bloque agotado,
   **no factura** sin internet.
7. **CAI - Plan B:** si se agota el bloque o falla el equipo, **talonario de facturas a mano con CAI de imprenta**
   (que lo confirme el contador); esas facturas se registran después en el programa como facturas manuales.
8. **G3 - Copia:** cada factura se imprime siempre con **original y "Copia: obligado tributario emisor"**. La copia se
   guarda en la caja; sirve si el equipo se pierde.

### 6.3 G4 - Cómo se adapta el candado de `cai_rango` (027, líneas 104-109)
Hoy `interno.proteger_cai_rango` exige que `ultimo_numero` avance **de uno en uno** y que `ultima_fecha_emision` nunca
vaya hacia atrás. Con bloques:
- Al **reservar**, `ultimo_numero` salta al **final del bloque** de una vez (los números quedan apartados). El trigger
  acepta ese salto solo si lo marca `reservar_bloque_numeros` (`app.reserva_bloque`, local a la transacción) y el bloque
  queda guardado en `numero_bloque` en la misma transacción.
- Cada número del bloque se controla en `numero_bloque.siguiente` (de uno en uno, nunca hacia atrás) y cada número
  emitido queda en una tabla de números usados con **única** (rango, número): nunca se repite.
- El orden de fecha se revisa **dentro del bloque** (cada venta del equipo con fecha igual o posterior a la anterior).
  `ultima_fecha_emision` del rango se actualiza con la venta más nueva que se registre.
- Las ventas **"por resolver" que ya tienen número impreso** también avanzan `siguiente` y quedan en números usados con
  estado "emitido, por resolver": el número está gastado aunque la venta todavía no esté en los libros.
- Devolver el sobrante (G4) no mueve `ultimo_numero` hacia atrás: el servidor usa los números devueltos desde
  `numero_bloque` (de uno en uno) antes de seguir después del bloque.

### 6.4 G3 - Desactivar un equipo NO anula números
Si un equipo se pierde o se daña, el dueño lo **desactiva** (`desactivar_equipo`): ya no puede subir nada nuevo sin
revisión y su bloque queda **"por conciliar"** (no se anula). El supervisor registra las ventas que faltan **a partir de
las copias en papel** (con motivo y bitácora). **Solo se anulan los números que de verdad no se usaron**, y se reportan
a la SAR como diga el contador.

## 7. Cómo se sube al volver el internet

- **G2 - Un solo camino:** en una caja **con bloque**, **toda** venta de contado (con o sin internet) se guarda primero
  en el equipo (4.2) y se sube enseguida por la cola. Así una venta en línea que se corta a medio camino no se duplica:
  si no llegó, se reintenta con el mismo id_operacion; si llegó, el servidor contesta "ya estaba". Además
  `subir_ventas_sin_internet` **reconoce también los id_operacion que entraron por `registrar_venta`** (respuesta "ya
  estaba"). Cada llamada tiene un **tiempo máximo de unos 10 segundos**; si no contesta, la venta sigue en la cola.
- **M3 - La cola:**
  - Sube **en orden**, de la más vieja a la más nueva, en **tandas de 10 a 20 ventas** (Supabase corta las consultas de
    la app a unos 8 s).
  - Un **error de red DETIENE la cola** (se reintenta toda después); no se salta ninguna venta.
  - Una venta que el servidor deja **"por resolver" igual avanza** el número y la cola sigue con la siguiente.
  - **Una sola pestaña sube a la vez** (`navigator.locks`).
  - Un id_operacion repetido responde **"ya estaba"** (no es error).
- **Reintentos:** a los 5 s, 30 s, 2 min y luego cada 5 min mientras haya internet; también al volver la conexión y al
  abrir la app.
- **Qué revisa el servidor otra vez** (`subir_ventas_sin_internet`): que el usuario siga activo y con permiso **a la hora
  de la venta**; que el turno siga siendo el suyo; la fecha y hora (punto 11); el número (de su bloque, el siguiente que
  toca, sin repetir); el precio y el cálculo **con la foto del catálogo** (G5); la existencia; la sucursal; que el mes
  esté abierto; que el total cuadre al centavo con lo que se cobró.
- **M7:** `subir_ventas_sin_internet` funciona **aunque el usuario esté fuera de su horario** (la venta se hizo dentro
  del horario; subirla no es operar).

## 8. Qué pasa si algo es rechazado al subir

La venta **siempre queda guardada en el servidor** (tabla `venta_sin_internet`, con todo lo que mandó el equipo), aunque
no se pueda registrar todavía. Va a la lista **"Ventas sin internet por resolver"** del supervisor (con alerta):

| Problema | Propuesta |
|---|---|
| Precio distinto | Se registra si es **igual al de la foto (G5) o al de hoy**. Cualquier otro: por resolver. |
| Sin existencias (o existencia negativa) | Se registra igual (el producto ya salió) y se avisa "inventario negativo por venta sin internet". **m:** el aviso recuerda que una compra registrada después con fecha atrasada puede chocar (`ENTRADA_FECHA_ATRASADA`): primero se resuelve el negativo con un conteo. |
| Usuario desactivado | Si la venta es de antes de desactivarlo: se registra. Si es de después: por resolver (el dueño decide). |
| **M5 - Mes cerrado** | Por resolver. La opción normal es que **el dueño reabra el mes** (con motivo; el contador lo confirma), se registre con su fecha real y se cierre otra vez. **No** se registra con otra fecha. |
| Otra sucursal (usuario limitado) | Por resolver. |
| Número fuera de su bloque o repetido | Por resolver, **grave** (alerta al dueño). El número no se vuelve a usar nunca. |
| Turno cerrado desde otro equipo | No debe pasar (un turno con ventas por subir no se cierra); si pasa, por resolver. |

Resolver = **registrar** (con permiso, motivo y bitácora) o **anular** (el número queda ANULADO en los libros fiscales y
el dinero se trata como sobrante de caja hasta devolverlo). Nada se borra.

## 9. Existencias: dos equipos venden el último producto

Sin internet ningún equipo sabe lo que vendió el otro. Los dos venden; el cliente ya se llevó el producto. Al subir, el
servidor registra las dos y la existencia queda en -1 con la alerta "inventario negativo por venta sin internet". El
supervisor lo corrige (conteo o compra). **Recomiendo aceptar y avisar** (rechazar no sirve: la mercadería ya salió).

## 10. Señales en pantalla

- **Barra fija arriba**: "Sin conexión: **N ventas** guardadas en este equipo". Con internet y ventas subiendo:
  "Subiendo 2 de 5…". Al terminar: "Todo subido". **m:** en el celular la barra **no tapa el botón Cobrar** (se pone
  arriba y el contenido baja; se prueba a 390 px).
- **Contador** en el botón de Ventas del día.
- **Estado de cada venta** en "Ventas del día": **En el equipo** (gris), **Subida** (verde), **Con problema** (rojo, con
  la razón en palabras sencillas).
- **Aviso antes de cerrar la pestaña** si hay ventas sin subir (`beforeunload`). **m:** en el celular **no se cuenta**
  con ese aviso (los navegadores del celular casi nunca lo muestran); por eso la cola se sube sola apenas hay internet.
- **m:** "sin conexión" se detecta también cuando **el servidor no contesta** (tiempo máximo vencido), no solo con
  `navigator.onLine`.
- **m:** el comprobante impreso dice **"Emitida sin conexión"** (solo texto, sin íconos ni emojis).

## 11. Fecha y hora

- La venta lleva la **hora del equipo** (`hora_equipo`) y la hora en que llegó al servidor (`recibido_en`).
- **Controles:** en cada actualización la app guarda la diferencia entre el reloj del equipo y el del servidor. Si es
  mayor de 5 minutos, avisa "La hora de este equipo está mal" y **no deja vender sin internet** hasta corregirla.
  Mientras está sin internet usa la hora corregida y un contador que no depende del reloj (`performance.now()`).
- **El servidor revisa:** que la hora no esté en el futuro (más de 10 min), que no sea anterior a la reserva del bloque,
  y que cada venta del equipo sea posterior a la anterior. Si el reloj estaba mal: "por resolver" ("reloj del equipo").
- La **fecha contable** es la fecha de la venta (zona de la empresa). Si ese mes ya se cerró: M5.

## 12. Seguridad

- **G1 - Abrir sin internet:** hoy la app no abre sin internet: `app.js` (líneas 38-47) exige `api.restaurar()` y la
  sesión vive solo en memoria. Con el diseño, si no hay internet y existe el **perfil sin internet** del último usuario
  en ese equipo (con `ventas.sin_internet`, caja, turno y token de renovación guardado), la app abre en **"modo sin
  internet"**: solo Vender de contado, Ventas del día y la barra. Sin perfil, pide internet como hoy.
- **Sesión que vence sin internet:** el token de acceso dura 1 hora, pero sin internet no se usa. Al volver, la app
  renueva la sesión con el token de renovación y sube. Si la sesión fue cerrada a distancia o el usuario desactivado, no
  puede subir: las ventas quedan en la cola del equipo y el **dueño** las sube desde ese mismo equipo (M2).
- **Qué puede hacer alguien con el equipo:** vender de contado con los precios guardados (como en la caja). No ve costos
  ni saldos de clientes. Límites que pone el dueño: **solo los usuarios con el permiso `ventas.sin_internet`**, tope por
  venta (L 10,000) y **por turno** sin internet, 24 horas de validez del catálogo (configurable) y el bloque hasta cerrar
  el turno.
- **Licencia vencida:** el perfil guarda la fecha de fin de la licencia; pasada esa fecha no se vende sin internet.
- **Robo o pérdida del equipo:** el dueño lo desactiva (G3): sus bloques quedan "por conciliar" (no se anulan).

## 13. Plan de pruebas

Núcleo (`nucleo/pruebas`, una por función nueva, más la actualización como en Supabase):
- Reservar bloque: correlativo, salto de `ultimo_numero` solo con la marca, no se cruzan entre equipos ni con la
  numeración en línea (que sigue después del bloque), vence, solo el mismo equipo devuelve (G4), por conciliar al
  desactivar (G3); dos equipos reservando a la vez.
- Subir: misma venta dos veces y una venta que entró por `registrar_venta` (G2: "ya estaba"); orden; tandas de 20 en
  menos de 8 s; cada problema del punto 8; foto del catálogo (G5: precio de la foto, de hoy y otro); fuera de horario
  (M7); total al centavo; libros cuadran; "por resolver" con número impreso avanza el bloque; resolver con permiso,
  motivo y bitácora; anular deja el número ANULADO.
- La cuenta del equipo da lo mismo que `interno.calcular_venta` en 200 casos ("pruebas espejo").

App (Playwright, `context.setOffline(true)`):
- Preparar (con `persist()`), cortar internet, **recargar y abrir la app sin internet (G1)**, vender 3, ver la barra y el
  contador, imprimir (original y copia), volver internet y ver que suben solas.
- G6: falla a propósito la transacción de IndexedDB (no se imprime, el contador no avanza).
- G2: cortar a medio subir una venta en línea (no duplica). M3: error de red detiene la cola; dos pestañas (una sola sube).
- Dos usuarios en el mismo equipo (M2: el dueño sube las del otro). Salir con cola (no deja). Reloj mal. Catálogo
  vencido. Modo incógnito y `persist()` negado (no deja). Celular a 390 px (la barra no tapa Cobrar).
- M1: la lista del cascarón de `sw.js` es igual a los archivos de `app/`.

## 14. Riesgos y decisiones del dueño (con mi recomendación)

| # | Decisión | Recomendación |
|---|---|---|
| 1 | ¿Facturas con CAI sin internet? | **Sí, con bloque reservado por caja y equipo** (tamaño según el promedio de ventas), que dura hasta cerrar el turno o la fecha límite del CAI. Plan B: talonario a mano con CAI de imprenta (lo confirma el contador). |
| 2 | ¿Abrir y cerrar turno sin internet? | **No.** Sin internet al cerrar: contar y anotar en papel, cerrar al volver (M4). |
| 3 | ¿Cobros (abonos) y gastos de caja sin internet? | **No en la etapa 1.** En REQUISITOS, "cobro" sin internet significa **cobrar la venta** en la caja, no abonos de clientes. |
| 4 | Formas de pago sin internet | **Efectivo y tarjeta** (con voucher). Nada de crédito, transferencia, cheque, saldo a favor ni vales. |
| 5 | Descuentos sin internet | **Solo promociones y precio mayorista** ya bajados. Sin descuento manual. |
| 6 | Tiempo máximo sin internet y topes | **24 horas, configurable**; **L 10,000 por venta** y **un tope por turno** sin internet. |
| 7 | Producto sin existencias al subir | **Aceptar y avisar** (la mercadería ya salió). |
| 8 | Precio que cambió mientras no había internet | **Solo el precio de la foto (G5) o el de hoy**; cualquier otro, "por resolver". |
| 9 | ¿Cifrar los datos del equipo? | **No en la etapa 1** (datos mínimos, se borran al salir, equipo con bloqueo). |
| 10 | ¿Quién puede vender sin internet? | **Solo usuarios con el permiso nuevo**, que da el dueño. |
| 11 | Ventas de un usuario desactivado que quedaron en el equipo | **Las sube el dueño desde el mismo equipo** (M2), con motivo. |
| 12 | Mes cerrado con ventas sin internet (M5) | **El dueño reabre el mes** (el contador lo confirma); nunca con otra fecha. |
| 13 | Equipo perdido o dañado (G3) | Bloque **por conciliar** con las copias en papel; solo se anulan los números no usados. |

Riesgos que quedan aunque se haga bien:
- **Doble venta del último producto** (punto 9): se corrige después con un conteo.
- **Navegador que borra datos:** se reduce con `persist()`, app instalada, sin incógnito (M1) y subida automática.
- **Reloj manipulado:** se detecta en gran parte, no al 100 %.
- **Lógica de precios en dos lugares** (equipo y servidor): se cuida con las pruebas espejo; el servidor manda siempre y
  calcula con la foto (G5).
- **Supabase plan gratis:** si se "pausa" por falta de uso, al volver a encender las ventas suben; no se pierden.

---

## 15. Sección técnica

### 15.1 Lo que ya existe y sirve
- `app/sw.js` guarda el **cascarón**: la app carga sin internet (en 0.13.0 se agregaron `garantias.js` y
  `rep_antiguedad.js`, que faltaban). Los datos nunca pasan por el service worker; así se queda.
- `api.escribir` manda `p_id_operacion` y reintenta una vez con el mismo id; el núcleo reconoce reintentos por tipo.
- `registrar_venta` acepta `"fecha"` y `"equipo"`.
- CAI por caja (`registrar_cai`), sin cruces; `asignar_numero_fiscal` bloquea el rango.

### 15.2 Cambios en el núcleo (una migración nueva, con sus pruebas)
Tablas (RLS, `no_borrar`, `no_vaciar`, `auditar`, sucursal):
- `equipo` (id, empresa, caja, nombre, activo, `ultima_sincronizacion_en`, `desactivado_en`). **m:** registrar el
  equipo es un paso del asistente de instalación (y del de arranque).
- `numero_bloque` (empresa, caja, equipo, tipo `factura`|`ticket`, `cai_rango_id`?, prefijo, desde, hasta, `siguiente`,
  reservado_en, `vence_en`, estado `activo`|`devuelto`|`por_conciliar`|`conciliado`, id_operacion). Los bloques de una
  caja y tipo no se cruzan; uno solo activo por caja y tipo.
- `numero_emitido` (rango o bloque, número **único**, venta o venta_sin_internet, estado `registrado`|`por_resolver`|
  `anulado`|`no_usado`).
- `catalogo_foto` (G5: equipo, versión, contenido jsonb, entregado_en).
- `venta_sin_internet` (empresa, equipo, usuario, id_operacion **único**, versión de la foto, payload jsonb,
  numero_documento, `hora_equipo`, `recibido_en`, estado `registrada`|`por_resolver`|`resuelta`|`anulada`, problema,
  venta_id, subido_por, resuelto_por, motivo).

Funciones (`SECURITY DEFINER`, `search_path = ''`, permisos, errores del catálogo, bitácora):
- `registrar_equipo`, `desactivar_equipo` (G3: bloque por conciliar), `conciliar_bloque` (registrar desde las copias,
  marcar no usados).
- `preparar_sin_internet(empresa, equipo, version_que_tiene?)`: guarda la foto (G5), devuelve solo lo que cambió (m), el
  perfil sin internet (G1), la hora y la validez; paginado.
- `reservar_bloque_numeros` (salto marcado de `ultimo_numero`, 6.3) y `devolver_bloque` (solo el mismo equipo y con la
  cola vacía, G4).
- `interno.proteger_cai_rango`: acepta el salto solo con `app.reserva_bloque`. `interno.asignar_numero_fiscal`: si la
  caja tiene bloque activo no numera; si tiene números devueltos, usa esos primero; si no, sigue después del bloque.
- `subir_ventas_sin_internet(empresa, equipo, ventas jsonb[])`: tandas de hasta 20 (M3); por venta, un SAVEPOINT;
  idempotente por id_operacion y reconoce los de `registrar_venta` (G2); calcula con la foto (G5); sin revisar el
  horario (M7); registra o deja "por resolver" con el número gastado (6.3).
- `ventas_sin_internet_por_resolver`, `resolver_venta_sin_internet`. `cerrar_turno`: no cierra con ventas por subir ni
  con un bloque activo sin devolver.
- Permisos: `ventas.sin_internet`, `ventas.resolver_sin_internet` (dueño y admin), `ventas.subir_ajenas` (solo el dueño).
  Alertas: venta por resolver, inventario negativo por venta sin internet, bloque por agotarse o por conciliar, reloj.

### 15.3 Cambios en la app
- **G1 - Arranque:** `iniciar()` en `app.js` (38-47): si `api.restaurar()` falla por falta de conexión y existe el perfil
  sin internet del último usuario en ese equipo (con `ventas.sin_internet`, caja, turno y token de renovación), abre el
  **modo sin internet** (menú reducido: Vender de contado y Ventas del día). `sesion.js` guarda el perfil sin internet al
  preparar y lo borra al salir si no quedan ventas suyas en la cola. Al volver el internet: renovar sesión, cargar el
  perfil completo y subir la cola.
- `js/sin_internet.js`: las dos bases (4.1), la transacción única número+contador+venta (G6), `persist()` y los avisos
  de versión (M1), la cola con `navigator.locks`, tandas, alto ante error de red y tiempo máximo de 10 s (G2, M3),
  detección de "sin conexión" por tiempo sin respuesta (m).
- `js/calculo_local.js`: la cuenta de la venta (ISV por línea con `precio_con_tasa`, promociones, mayorista) con las
  pruebas espejo.
- Vender: en una caja con bloque, **toda venta de contado pasa por la cola** (G2), con o sin internet.
- Barra fija (sin tapar Cobrar), contador, estado por venta, pantalla "Ventas sin internet por resolver" y "Ventas de
  otros usuarios guardadas en este equipo" (M2). Comprobante "Emitida sin conexión", con original y copia (G3).
- `salir()` no borra la base del equipo ni la cola; borra el catálogo.

### 15.4 Lo que la Parte A (0.19.0) cambia para este diseño
- **Devoluciones, cambio exacto, garantías y estado de cuenta del socio** son solo con internet: no chocan.
- **Precio mayorista:** la cuenta local debe repetir la regla "lo mejor para el cliente entre la promoción y el
  mayorista". Para la etapa 1 conviene: mayorista por cantidad o por cliente, y una sola promoción; con varias, el cajero
  elige (como en línea). El servidor calcula con la foto (G5).
- **`venta_linea.mayorista_por` y `mayorista_desde`** se llenan al INSERTAR la línea: en una venta sin internet sería la
  hora de SUBIR. La venta sin internet debe mandar `precio_tipo` y el "desde cantidad" de la foto, y
  `subir_ventas_sin_internet` los guarda tal cual (para que una devolución posterior calcule bien el ajuste mayorista).
- **Numeración:** `interno.asignar_numero_fiscal` y `interno.proteger_cai_rango` cambian como dice 6.3.

## 16. Seguimiento de la revisión

| Código | Qué | Dónde |
|---|---|---|
| G1 | La app abre sin internet con el perfil sin internet | 1, 5, 12, 15.3 |
| G2 | Venta en línea cortada no se duplica: toda venta de la caja con bloque por la cola; reconoce ids de `registrar_venta`; 10 s | 6.2, 7, 15.2, 15.3 |
| G3 | Desactivar no anula números; copia impresa; bloque por conciliar | 6.2, 6.4, 12, 14 |
| G4 | Solo el mismo equipo devuelve números; vencido sigue apartado; en línea sigue después; candado de `cai_rango` | 6.2, 6.3, 15.2 |
| G5 | Foto versionada del catálogo; precio de la foto o de hoy | 5, 7, 8, 15.2 |
| G6 | Número + contador + venta en una transacción; base del equipo que no se borra | 4.1, 4.2, 15.3 |
| M1 | `persist()`, sin incógnito, iPhone instalada, versiones de IndexedDB, prueba del cascarón | 4.3, 13 |
| M2 | El dueño sube ventas de otros desde el mismo equipo | 4.4, 12, 14 |
| M3 | Error de red detiene la cola; por resolver avanza; tandas; una pestaña; "ya estaba" | 7 |
| M4 | 24 h configurable; cerrar turno sin internet en papel; arqueo en cola = etapa 1.5 | 2, 5, 14 |
| M5 | Mes cerrado: reabrir; nunca otra fecha | 8, 11, 14 |
| M6 | Promociones o impuestos que cambiaron: resuelto con la foto (G5) | 5 |
| M7 | Subir funciona fuera del horario | 7 |
| m | Barra y Cobrar; beforeunload en celular; servidor que no contesta; "Emitida sin conexión"; solo lo que cambió; fecha atrasada; tamaño de bloque; equipo en el asistente | 5, 6.2, 8, 10, 15.2 |
| CAI | Dura hasta cerrar turno o fecha límite (48 h solo si no vuelve); talonario de imprenta; nada de "ticket ahora y factura después" | 3, 6.2, 14 |
