# Centro de control del dueño (047, núcleo 0.13.0)

Lecturas para el panel y control a distancia. Todo respeta los permisos.

## Vigilancia por empleado

`vigilancia_empleados(empresa, desde, hasta, usuario?)` (`bitacora.ver`: dueño y admin). Por empleado:

- `ventas`: cantidad y total con ISV de las ventas emitidas que registró (ventas.ver).
- `ganancia_centavos`: ventas sin ISV − costo (solo con inventario.costos; si no, null).
- `descuentos`: ventas con descuento manual y su total (las promociones no cuentan).
- `anulaciones_pedidas`: cuántas pidió, cuántas se aprobaron y el monto.
- `diferencias_caja`: turnos cerrados, cuántos con diferencia, faltante, sobrante y neto.
- `horario_uso`: por día, primera y última vez que guardó algo y cuántas acciones (de la bitácora;
  consultar no queda registrado).

Ventas y turnos solo de las sucursales que ve quien consulta.

## Bitácora legible

`bitacora_legible(empresa, filtros)` (`bitacora.ver`). Filtros: `usuario_id`, `desde`, `hasta`
(AAAA-MM-DD, hora de la empresa), `tipo` (ventas, dinero, inventario, productos, compras, usuarios,
configuracion, aprobaciones, contabilidad, otros), `detalle` (true = también renglones internos como
líneas de asiento y kardex), `limite` (100, máximo 500) y `antes_de` (para la página siguiente:
use `siguiente_antes_de`). Cada fila trae fecha, hora, persona, tipo, motivo y un texto sencillo:
"María Pérez creó una venta #15", "Ana anuló un gasto #3", "Luis desactivó un usuario".

## Control a distancia

- **Cerrar sesión:** `cerrar_sesion_usuario(empresa, usuario, motivo)` (`usuarios.administrar`, mismas
  reglas que desactivar: el admin solo a cajeros y vendedores; nadie a sí mismo). Desde ese momento el
  servidor rechaza todo lo que haga con su sesión anterior (`SESION_CERRADA`). La app consulta
  `mi_estado_sesion(empresa)` al abrir y cada pocos minutos: si `debe_salir` es true, cierra la sesión
  en el aparato. Al entrar de nuevo trabaja normal.
  **Cómo reconoce la sesión (0.13.1):** por el `session_id` del token de Supabase, que NO cambia al
  renovar el token. La base busca esa sesión en `auth.sessions` y la rechaza si se inició antes del
  cierre, si ya no existe o si es de otro usuario. Así, aunque el aparato perdido renueve su token
  (nuevo `iat`), sigue rechazado; solo entra quien inicia una sesión nueva con correo y contraseña.
  Si el token no trae `session_id` (o la base no puede leer `auth.sessions`) se usa la regla anterior:
  la hora del token `iat` contra la del cierre (en 0.13.0 esa regla se saltaba al renovar el token).
  **Qué cubre la base:** ningún dato se lee ni se guarda con la sesión cerrada (`SESION_CERRADA`).
  **Qué falta en Supabase (etapa de pantallas):** una Edge Function con la llave service_role llamará
  `auth.admin.signOut(usuario)` para revocar también los tokens de renovación (así el aparato ni
  siquiera obtiene tokens nuevos). Revisar en el proyecto real que el dueño de las funciones
  (`postgres`) pueda leer `auth.sessions` (en Supabase sí puede); si no, queda la regla del `iat`.
- **Desactivar al instante:** `desactivar_usuario_empresa` (ya existía): desde ese momento no lee ni
  escribe nada de la empresa (`NO_PERTENECE`). Confirmado en la prueba 128.
- **Horario por puesto:** `configurar_horario_acceso(empresa, rol, horario, motivo)` (solo dueño).
  `{"1":{"desde":"07:00","hasta":"18:00"}, ..., "6":{"desde":"08:00","hasta":"12:00"}}` (1 = lunes,
  7 = domingo; hora de la empresa; "hasta" puede ser "24:00"). Un día que no está = no trabaja ese día.
  NULL o {} = sin límite. Fuera de horario el servidor rechaza toda operación (`FUERA_DE_HORARIO`);
  consultar sí se puede. El dueño (y el proveedor) nunca tienen horario. No hay turnos que pasen la
  medianoche (use dos días).

`mi_estado_sesion(empresa)`: `debe_salir`, `sesion_cerrada_en`, `horario`, `horario_hoy`,
`dentro_de_horario`, `sucursales` (null = todas) y `todas_las_sucursales`.

## Rendimiento

`herramientas/prueba_volumen.sh` (no está en probar.sh porque tarda varios minutos): crea 20,000 ventas
reales y mide resumen_hoy, alertas_activas, estado_resultados, libro_ventas, reporte_sucursales y
vigilancia_empleados. Índices nuevos: bitácora por usuario y fecha, ventas por sucursal y por quien emitió.
