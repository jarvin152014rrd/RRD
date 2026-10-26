# Vender sin internet — diseño (todavía NO programado)

Estado: **diseño para que el dueño decida**. No hay código de esto en el núcleo 0.19.0 ni en la app 0.13.0. Cuando el
dueño apruebe las decisiones del final, se programa en etapas, cada una con sus pruebas.

Regla de siempre (REQUISITOS, "Reglas generales"): *un solo cerebro* (el dinero lo decide el servidor) y *sin
internet: solo venta rápida y cobro, con cola local, id_operacion y rango CAI por caja; todo lo demás requiere
conexión*. Este diseño respeta eso: el equipo **anota** la venta y la **sube** después; el servidor la vuelve a revisar
toda y es quien la registra en los libros.

---

## 1. En palabras sencillas

Cuando se va el internet, la caja sigue vendiendo de contado. Cada venta se guarda en el equipo (la computadora o el
celular), se imprime su comprobante con su número de verdad y queda en una lista "por subir". Arriba sale siempre una
barra: **"Sin conexión: 3 ventas guardadas en este equipo"**. Cuando vuelve el internet, el equipo las sube solas, en
orden. El servidor revisa cada una otra vez (precio, existencias, usuario, turno, fecha y número). Si todo está bien,
queda registrada igual que una venta normal. Si algo no cuadra, **no se pierde**: queda en "Pendientes por resolver"
para que el supervisor decida.

## 2. Qué se puede hacer sin internet (recomendación: lo mínimo seguro)

| Acción | ¿Sin internet? | Recomendación |
|---|---|---|
| Vender de contado en **efectivo** | Sí | Etapa 1. Es lo que más se necesita. |
| Vender con **tarjeta** (POS del banco que funciona solo) | Sí, con el número de voucher | Etapa 1, si el POS imprime voucher sin internet. |
| Ver productos, precios y existencias (de la última vez que hubo internet) | Sí (solo mirar) | Etapa 1, con la hora de la última actualización a la vista. |
| Reimprimir el comprobante de una venta hecha sin internet | Sí | Etapa 1. |
| Abrir o cerrar el turno de caja | **No** | El turno se abre y se cierra con internet. Sin internet se vende dentro del turno ya abierto. |
| Cobrar abonos de clientes | **No (etapa 2)** | El saldo del cliente puede estar viejo (otro cajero ya cobró). |
| Gastos de caja | **No (etapa 2)** | Piden comprobante (foto) y a veces aprobación. |

## 3. Qué NO se puede hacer sin internet, y por qué

- **Ventas al crédito:** hay que revisar el límite y lo que el cliente debe HOY; eso solo lo sabe el servidor.
- **Transferencias, cheques, saldo a favor y vales:** se confirman contra el banco o contra un saldo que puede gastarse
  dos veces en dos equipos a la vez.
- **Descuentos manuales y todo lo que pide aprobación:** quien aprueba está en el servidor. Sin internet solo se aplican
  las promociones vigentes y el precio mayorista que ya se bajaron.
- **Devoluciones, cambios, anulaciones y garantías:** mueven dinero ya registrado y piden ver la venta en el servidor.
- **Cotizaciones, apartados, compras, inventario, cierres, reportes, Ajustes:** no son urgentes y usan datos de todos.
- **Entrar por primera vez en un equipo:** la contraseña la revisa el servidor.

## 4. Cómo se guarda en el equipo

- En **IndexedDB** (la "bodega" del navegador), una base por **empresa y usuario**: `negocio-<empresa>-<usuario>`.
  Así, si otro usuario entra en el mismo equipo, no ve ni sube las ventas del primero.
- Dos partes:
  - **Catálogo** (productos, precios, clientes, promociones, impuestos, número de bloque): se puede volver a bajar; **se
    borra al salir**.
  - **Cola de ventas por subir**: **nunca se borra sola**. Una venta solo sale de la cola cuando el servidor contestó
    "registrada" o "pendiente por resolver" (ya está guardada allá).
- **Salir con ventas sin subir:** la app no deja salir sin internet si hay ventas en la cola ("Conéctese para subir las 3
  ventas antes de salir"). Si el navegador se va a borrar (equipo dañado, limpieza), hay un botón **"Guardar respaldo de
  las ventas por subir"** que baja un archivo; ese archivo lo sube después el mismo usuario o el dueño.
- **Otro usuario entra en el mismo equipo:** usa su propia base. Las ventas del primero quedan guardadas y se suben
  cuando él vuelve a entrar (o el dueño las sube con el archivo de respaldo, ver Seguridad).
- **¿Cifrado?** Recomiendo **no** cifrar con una clave propia en la etapa 1: una clave guardada en el mismo navegador
  protege poco y complica recuperar ventas si algo falla. Se protege así: se guardan solo los datos necesarios (sin
  costos, sin saldos de clientes), el catálogo se borra al salir, el equipo debe tener bloqueo de pantalla y la cola no
  tiene contraseñas ni tokens. Si más adelante se quiere cifrar, se usa WebCrypto (AES-GCM) con una llave que no se puede
  sacar del navegador.

## 5. Qué se baja antes para poder vender sin internet

Con internet, la app baja y guarda (botón "Preparar para trabajar sin internet", al abrir el turno y cada 15 minutos):

| Dato | Detalle |
|---|---|
| Productos activos | código, código de barras, nombre, unidad, si acepta decimales, impuesto y "precio incluye ISV", precio de la sucursal de la caja, precio mayorista y "desde cantidad", servicio o bien |
| Existencias | de la bodega de la caja, solo para mirar (con la hora) |
| Clientes | nombre, RTN y si es mayorista (sin saldos ni límites) |
| Promociones vigentes | con sus fechas (una venta fuera de fechas no la usa) |
| Impuestos | código y tasa |
| Reglas de la empresa | documento de venta (factura o ticket), turnos, quién cobra, topes sin internet |
| Turno y caja | el turno abierto del usuario y su caja |
| Bloque de números | facturas (CAI) y tickets reservados para ese equipo (ver punto 6) |
| Hora del servidor | para comparar con el reloj del equipo |

Validez: el catálogo sirve para vender sin internet **hasta 12 horas** después de bajarlo (lo decide el dueño). Pasado
ese tiempo la app no deja vender sin internet ("Los precios tienen más de 12 horas: conéctese").

## 6. Cómo se numeran las ventas sin internet

### Tickets internos
Con internet el servidor da el número (T-001-001-00000012). Sin internet el equipo usa un **bloque de tickets reservado**
para él (por ejemplo del 00000101 al 00000200). El número impreso es el definitivo.

### Facturas con CAI
La ley exige que las facturas de un rango CAI salgan **correlativas** (sin saltos ni repetidos) y en orden de fecha. Hoy
el servidor numera cada caja (`interno.asignar_numero_fiscal`). Propuesta:

1. **Reservar un bloque por caja y equipo mientras hay internet** (`reservar_bloque_numeros`): por ejemplo 100 números
   del rango CAI vigente de esa caja. El bloque queda a nombre de ese equipo.
2. **Mientras el bloque está activo, esa caja numera SOLO desde el bloque** (con o sin internet, el número lo pone el
   equipo y el servidor lo revisa). Así no se cruzan números de la misma caja ni salen fuera de orden.
3. **No se repiten entre equipos:** cada caja (punto de emisión) es de un solo equipo a la vez y los bloques no se
   cruzan (lo cuida el servidor con un candado y una regla de "no se cruzan rangos").
4. **Vencimiento:** el bloque vence a las 48 horas o en la fecha límite del CAI (lo que llegue primero). Vencido, el
   equipo ya no factura sin internet.
5. **Devolver el sobrante:** al volver el internet y subir todo, el equipo devuelve lo que no usó
   (`devolver_bloque`); el servidor sigue numerando desde el primer número sin usar (sigue siendo correlativo).
6. **Alerta "por agotarse":** si al bloque le quedan pocos números, la app avisa; sin bloque o con el bloque agotado,
   **no factura** sin internet (no hay número legal).

## 7. Cómo se sube al volver el internet

- **Cola en orden:** las ventas suben una por una, de la más vieja a la más nueva (el número y el kardex dependen del
  orden). Una que da error no detiene a las demás; queda marcada.
- **id_operacion:** cada venta lleva su id_operacion desde que se hizo. Si se sube dos veces (corte a medio camino), el
  servidor contesta "ya estaba" y no la duplica.
- **Reintentos:** a los 5 s, 30 s, 2 min y luego cada 5 min mientras haya internet; también al volver la conexión
  (`online`) y al abrir la app.
- **Qué revisa el servidor otra vez** (`subir_ventas_sin_internet`): que el usuario siga activo y con permiso **a la hora
  de la venta**; que el turno siga siendo el suyo; la fecha y hora (ver punto 10); el número (dentro de su bloque, el
  siguiente que toca, sin repetir); el precio (contra el precio vigente a esa hora, guardado en el historial); las
  promociones y el mayorista; los impuestos; la existencia; la sucursal; que el mes esté abierto; que el total cuadre al
  centavo con lo que se cobró.

## 8. Qué pasa si algo es rechazado al subir

La venta **siempre queda guardada en el servidor** (tabla `venta_sin_internet`, con todo lo que mandó el equipo), aunque
no se pueda registrar todavía. Va a la lista **"Ventas sin internet por resolver"** del supervisor (con alerta):

| Problema | Propuesta |
|---|---|
| El precio cambió (el equipo tenía el de antes) | Se registra con lo que pagó el cliente (ya se cobró) y queda la marca "precio anterior" en el reporte. Solo pasa a "por resolver" si el catálogo tenía más de 12 horas. |
| Sin existencias (o existencia negativa) | Se registra igual (el producto ya salió) y se avisa "inventario negativo por venta sin internet" para revisar con un conteo. |
| Usuario desactivado | Si la venta es de antes de desactivarlo: se registra. Si es de después: por resolver (el dueño decide). |
| Mes cerrado | Por resolver: el supervisor la registra con fecha de hoy (queda la fecha real anotada) o reabre el mes. |
| Otra sucursal (usuario limitado) | Por resolver. |
| Número fuera de su bloque o repetido | Por resolver, **grave** (alerta al dueño). El número no se vuelve a usar nunca. |
| Turno cerrado desde otro equipo | No debe pasar (un turno con ventas por subir no se cierra); si pasa, por resolver. |

Resolver = **registrar** (con permiso, motivo y bitácora) o **anular** (el número queda ANULADO en los libros fiscales y
el dinero se trata como sobrante de caja hasta devolverlo). Nada se borra.

## 9. Existencias: dos equipos venden el último producto

Sin internet ningún equipo sabe lo que vendió el otro. Los dos venden; el cliente ya se llevó el producto. Al subir, el
servidor registra las dos y la existencia queda en -1 con la alerta "inventario negativo por venta sin internet". El
supervisor lo corrige (conteo o compra). **Recomiendo aceptar y avisar** (rechazar no sirve: la mercadería ya salió).
Para el costo, la venta usa el costo promedio de ese momento (como cualquier venta con existencia negativa permitida).

## 10. Señales en pantalla

- **Barra fija arriba** (no se puede cerrar): "Sin conexión: **N ventas** guardadas en este equipo". Con internet y
  ventas subiendo: "Subiendo 2 de 5…". Al terminar: "Todo subido".
- **Contador** en el botón de Ventas del día.
- **Estado de cada venta** en "Ventas del día": **En el equipo** (gris), **Subida** (verde), **Con problema** (rojo, con
  la razón en palabras sencillas).
- **Aviso antes de cerrar la pestaña** si hay ventas sin subir (`beforeunload`): "Hay ventas sin subir. Si cierra, se
  suben la próxima vez que abra la app en este equipo".
- El comprobante impreso dice "Venta registrada sin conexión" (solo texto, sin íconos ni emojis).

## 11. Fecha y hora

- La venta lleva la **hora del equipo** (`hora_equipo`) y la hora en que llegó al servidor (`recibido_en`).
- **Controles:** en cada actualización la app guarda la diferencia entre el reloj del equipo y el del servidor. Si es
  mayor de 5 minutos, avisa "La hora de este equipo está mal" y **no deja vender sin internet** hasta corregirla.
  Mientras está sin internet usa la hora corregida y un contador que no depende del reloj (`performance.now()`), así un
  cambio de hora a mano se nota.
- **El servidor revisa:** que la hora no esté en el futuro (más de 10 min), que no sea anterior a la reserva del bloque,
  y que cada venta del equipo sea posterior a la anterior (los números y las fechas van juntos). Si el reloj estaba mal:
  "por resolver" ("reloj del equipo").
- La **fecha contable** es la fecha de la venta (zona de la empresa), si ese mes está abierto.

## 12. Seguridad

- **Sesión que vence sin internet:** el token de acceso dura 1 hora, pero sin internet no se necesita (no se habla con el
  servidor). Al volver, la app renueva la sesión con el token de renovación y sube. Si la sesión fue cerrada a distancia
  o el usuario desactivado, no puede subir: las ventas quedan en el equipo y el **dueño** las sube con el archivo de
  respaldo (`subir_ventas_sin_internet` con permiso `ventas.subir_ajenas`, solo el dueño, con motivo); quedan a nombre
  del cajero que las hizo y "subidas por" el dueño.
- **Qué puede hacer alguien con el equipo:** vender de contado con los precios guardados (como en la caja). No ve costos
  ni saldos de clientes. Límites que pone el dueño: **solo los usuarios con el permiso nuevo `ventas.sin_internet`**,
  tope por venta (ej. L 10,000) y por turno sin internet, 12 horas de validez del catálogo y el bloque de 48 horas.
- **Licencia vencida:** el catálogo guarda la fecha de fin de la licencia; pasada esa fecha no se vende sin internet.
- **Robo o pérdida del equipo:** el dueño "desconecta el equipo" (`desactivar_equipo`): sus bloques de números se
  anulan, y lo que suba ese equipo después queda "por resolver".

## 13. Plan de pruebas

Núcleo (`nucleo/pruebas`, una por función nueva, más la actualización como en Supabase):
- Reservar bloque: correlativo, no se cruzan entre equipos ni con la numeración en línea, vence, se devuelve el
  sobrante y la caja sigue correlativa; dos equipos reservando a la vez (concurrencia).
- Subir: misma venta dos veces (un solo registro); orden; cada problema de la tabla del punto 8 (precio viejo,
  existencia negativa, usuario desactivado antes y después, mes cerrado, otra sucursal, número fuera de bloque, reloj
  adelantado y atrasado); total al centavo; libros cuadran (debe = haber, dinero = cuentas, kardex = inventario, ISV);
  resolver con permiso, motivo y bitácora; anular deja el número ANULADO.
- La cuenta del equipo (precios, ISV, promociones, mayorista) da lo mismo que `interno.calcular_venta` en 200 casos
  (mismos casos en SQL y en JavaScript: "pruebas espejo").

App (Playwright, `context.setOffline(true)`):
- Preparar, cortar internet, vender 3 (efectivo y tarjeta), recargar la página sin internet (abre del cascarón), ver
  la barra y el contador, imprimir, intentar cerrar la pestaña (aviso), volver internet y ver que suben solas.
- Cortar a medio subir (no duplica). Dos usuarios en el mismo equipo (cada uno ve lo suyo). Salir con cola (no deja).
  Reloj mal (no deja vender). Catálogo de más de 12 horas (no deja). Celular.
- Todo lo que no se puede sin internet muestra un mensaje claro y no se rompe.

## 14. Riesgos y decisiones del dueño (con mi recomendación)

| # | Decisión | Recomendación |
|---|---|---|
| 1 | ¿Facturas con CAI sin internet? | **Sí, con bloque reservado por caja y equipo** (100 números, vence en 48 h). Sin eso, un negocio que solo factura no puede vender sin internet. |
| 2 | ¿Abrir y cerrar turno sin internet? | **No.** Se abre y se cierra con internet; sin internet solo se vende en el turno abierto. |
| 3 | ¿Cobros (abonos) y gastos de caja sin internet? | **No en la etapa 1.** Riesgo de cobrar dos veces o gastar sin aprobación. |
| 4 | Formas de pago sin internet | **Efectivo y tarjeta** (con voucher). Nada de crédito, transferencia, cheque, saldo a favor ni vales. |
| 5 | Descuentos sin internet | **Solo promociones y precio mayorista** ya bajados. Sin descuento manual. |
| 6 | Tiempo máximo sin internet | **12 horas** de validez del catálogo; tope de **L 10,000 por venta**. |
| 7 | Producto sin existencias al subir | **Aceptar y avisar** (la mercadería ya salió). |
| 8 | Precio que cambió mientras no había internet | **Aceptar lo cobrado** y marcarlo en el reporte. |
| 9 | ¿Cifrar los datos del equipo? | **No en la etapa 1** (datos mínimos, se borran al salir, equipo con bloqueo). |
| 10 | ¿Quién puede vender sin internet? | **Solo usuarios con el permiso nuevo**, que da el dueño. |
| 11 | Ventas de un usuario desactivado que quedaron en el equipo | **Las sube el dueño** con el archivo de respaldo, con motivo. |

Riesgos que quedan aunque se haga bien:
- **Doble venta del último producto** (punto 9): se corrige después con un conteo.
- **Navegador borrado antes de subir:** se pierde la cola si no se guardó el respaldo. Por eso: aviso al cerrar, subida
  automática apenas hay internet y botón de respaldo.
- **Reloj manipulado:** se detecta en gran parte, no al 100 %.
- **Lógica de precios en dos lugares** (equipo y servidor): se cuida con las pruebas espejo; el servidor manda siempre.
- **Supabase plan gratis:** si se "pausa" por falta de uso, al volver a encender las ventas suben; no se pierden.

---

## 15. Sección técnica

### 15.1 Lo que ya existe y sirve
- `app/sw.js` guarda el **cascarón** (HTML, CSS, JS): la app abre sin internet. (Arreglo de 0.13.0: faltaban
  `garantias.js` y `rep_antiguedad.js` en la lista.) Los datos nunca pasan por el service worker; así se queda.
- `api.escribir` ya manda `p_id_operacion` y reintenta una vez con el mismo id; el núcleo reconoce reintentos por tipo
  (`interno.exigir_tipo_operacion` / `reservar_operacion`).
- `registrar_venta` acepta `"fecha"` y `"equipo"`; la venta guarda `equipo`.
- CAI por caja (`registrar_cai`), un rango por prefijo de caja, sin cruces; `asignar_numero_fiscal` bloquea el rango.

### 15.2 Cambios en el núcleo (una migración nueva, con sus pruebas)
Tablas (RLS, `no_borrar`, `no_vaciar`, `auditar`, sucursal):
- `equipo` (id, empresa, caja, nombre, usuario que lo registró, activo, `ultima_sincronizacion_en`, `desactivado_en`).
- `numero_bloque` (empresa, caja, equipo, tipo_documento `factura`|`ticket`, `cai_rango_id`?, prefijo, desde, hasta,
  siguiente, reservado_en, `vence_en`, estado `activo`|`devuelto`|`vencido`|`anulado`, id_operacion). Restricción: los
  bloques activos de una misma caja y tipo no se cruzan; un solo bloque activo por caja y tipo.
- `venta_sin_internet` (empresa, equipo, usuario, id_operacion **único**, payload jsonb tal como lo mandó el equipo,
  numero_documento, `hora_equipo`, `recibido_en`, estado `registrada`|`por_resolver`|`resuelta`|`anulada`, problema
  (clave del catálogo + texto), venta_id, subido_por, resuelto_por, motivo).

Funciones (`SECURITY DEFINER`, `search_path = ''`, permisos, errores del catálogo, bitácora):
- `registrar_equipo(empresa, caja, nombre)`, `desactivar_equipo(equipo, motivo)` (dueño o admin).
- `preparar_sin_internet(empresa, equipo)`: devuelve el catálogo del punto 5, la hora del servidor, la validez y los
  bloques activos (o reserva uno nuevo si hace falta). Lectura grande paginada (máx. 1000 por página).
- `reservar_bloque_numeros(empresa, caja, equipo, tipo, cantidad, id_operacion)` y `devolver_bloque(bloque, id_operacion)`.
- `interno.asignar_numero_fiscal` (y el de tickets): si la caja tiene un bloque activo, **no numera** (el número lo
  pone el equipo); `registrar_venta_base` acepta un número "del bloque" solo desde `subir_ventas_sin_internet`
  (`app.numero_de_bloque`, local a la transacción) y revisa que sea el `siguiente` del bloque.
- `subir_ventas_sin_internet(empresa, equipo, ventas jsonb[])`: por cada venta, en su propio SAVEPOINT: guarda el payload
  (idempotente por id_operacion), revisa todo (punto 7), registra con `registrar_venta_base` (fecha = la del equipo,
  número del bloque, `precio_tipo` y precios de esa hora) o la deja `por_resolver` con su problema. Devuelve el estado de
  cada una. Las reglas "aceptar y avisar" (existencia negativa, precio anterior) se aplican con marcas locales
  (`app.venta_sin_internet`) que solo esta función pone.
- `ventas_sin_internet_por_resolver(empresa)` y `resolver_venta_sin_internet(id, accion, motivo, id_operacion)`.
- `cerrar_turno`: no cierra si el equipo de esa caja tiene ventas por subir (según su último aviso) o un bloque activo con
  números usados sin subir.
- Permisos nuevos: `ventas.sin_internet` (cajero/vendedor que cobra, lo da el dueño), `ventas.resolver_sin_internet`
  (dueño y admin), `ventas.subir_ajenas` (solo el dueño). Alertas nuevas: venta por resolver, inventario negativo por
  venta sin internet, bloque por agotarse o vencido, reloj del equipo.

### 15.3 Cambios en la app
- `js/sin_internet.js`: IndexedDB por empresa y usuario (catálogo y cola), preparar, cola con reintentos y
  `navigator.onLine` + eventos de `api.js` ('sin-conexion' / 'con-conexion'), respaldo en archivo, `beforeunload`.
- `js/calculo_local.js`: la cuenta de la venta (ISV por línea con `precio_con_tasa`, promociones, mayorista) con las
  pruebas espejo.
- Vender: si no hay conexión y el usuario tiene el permiso, usa el catálogo y el bloque; si no, el aviso de hoy.
- Barra fija, contador, estado por venta en Ventas del día, pantalla "Ventas sin internet por resolver".
- `salir()` no borra la cola; borra el catálogo.

### 15.4 Lo que la Parte A (0.19.0) cambia para este diseño
- **Devoluciones, cambio exacto, garantías y estado de cuenta del socio** son solo con internet: no chocan.
- **Precio mayorista:** la cuenta local debe repetir la regla "lo mejor para el cliente entre la promoción y el
  mayorista" de `interno.calcular_venta`. Para la etapa 1 conviene simplificar sin internet: mayorista por cantidad o por
  cliente, y una sola promoción; con varias promociones, el cajero elige (como en línea).
- **`venta_linea.mayorista_por` y `mayorista_desde`** (0.19.0) se llenan al INSERTAR la línea, con el cliente y el producto
  de ese momento: en una venta sin internet sería la hora de SUBIR, no la de vender. Al programar esto, la venta sin
  internet debe mandar `precio_tipo` y el "desde cantidad" que usó, y `subir_ventas_sin_internet` los guarda tal cual
  (para que una devolución posterior calcule bien el ajuste mayorista).
- **Numeración:** `interno.asignar_numero_fiscal` hoy toma el rango vigente más antiguo de la caja y exige fechas en
  orden; con bloques hay que cambiarla (punto 15.2). No se tocó en 0.19.0.
