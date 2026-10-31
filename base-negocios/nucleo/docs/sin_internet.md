# Vender sin internet (056_sin_internet, núcleo 0.20.0) — módulo "ventas"

Diseño aprobado: `docs/SIN_INTERNET.md` (v2, códigos G1-G6, M1-M7). Guía para el cajero y el dueño:
`docs/SIN_INTERNET_GUIA.md`. El equipo ANOTA la venta y la SUBE; el servidor la revisa toda otra vez y la registra.

## Permisos (nuevos)

| permiso | por defecto | para qué |
|---|---|---|
| `ventas.sin_internet` | dueño, admin | preparar el equipo y vender sin internet (el dueño se lo da al cajero) |
| `ventas.resolver_sin_internet` | dueño, admin | lista "por resolver", registrar o anular con motivo |
| `ventas.subir_ajenas` | dueño | subir las ventas que otro usuario dejó en un equipo (M2) |
| `equipos.administrar` | dueño | desactivar un equipo perdido y conciliar sus números (G3) |

## Reglas de la empresa (`configurar_empresa`, solo el dueño, con motivo)

`sin_internet_horas` (24; de 1 a 168: validez de los precios bajados), `sin_internet_tope_venta_centavos` (L 10,000.00),
`sin_internet_tope_turno_centavos` (L 50,000.00; lo vendido sin internet por usuario en un bloque), `sin_internet_bloque`
(null = sugerido: 1.5 veces las ventas de un día de la caja en los últimos 30 días, entre 20 y 500).

**Formas de pago sin internet (decisión del dueño, 0.20.0):** efectivo y transferencia bancaria (con número de
referencia; queda "por confirmar"). Tarjeta NO sin internet (los POS necesitan conexión); con internet, una venta de la
cola puede ir con tarjeta. Nada de crédito, cheque, saldo a favor ni vales. (El interruptor "tarjeta sin internet" del
diseño se quitó.)

## Equipos y bloques

- `registrar_equipo(empresa, {"nombre"}, id_operacion)` -> `equipo_id` (la app lo guarda en su base del equipo).
- `reservar_bloque_numeros(empresa, equipo, id_operacion, {"caja_id"?, "tamano"?})`: para la caja del turno abierto (o la
  indicada si la empresa no exige turnos) reserva un bloque de **facturas** (del rango CAI vigente de esa caja) y/o de
  **tickets** según `documento_venta_modo`. Un solo bloque activo por caja y tipo; otro equipo: `BLOQUE_ACTIVO`.
  Factura: `cai_rango.ultimo_numero` salta al final del bloque (G4, solo con la marca `app.reserva_bloque` y el bloque
  ya guardado); ticket: el contador de tickets de la caja salta igual.
- **Mientras el bloque está activo, la caja numera SOLO desde el bloque** (`BLOQUE_ACTIVO` en `registrar_venta`,
  convertir cotización, completar apartado o el cambio de producto en esa caja). En esa caja la app manda toda venta de
  contado por la cola (G2), con o sin internet. Crédito, cotizaciones convertidas, apartados y cambios: en otra caja o
  después de devolver el bloque.
- `devolver_bloque(empresa, equipo, bloque, siguiente_del_equipo, id_operacion)`: SOLO el mismo equipo (G4) y solo si
  ya subió todo lo que numeró (`FALTAN_VENTAS_POR_SUBIR` dice cuántas faltan). Los números sin usar los usa primero la
  numeración en línea de esa caja (y un bloque nuevo empieza ahí), mientras nada se haya emitido después del bloque.
- **Turno:** no se cierra con un bloque activo de su caja (`BLOQUE_SIN_DEVOLVER`); la app sube, devuelve y cierra. Si el
  equipo no da noticias en 48 horas, el turno sí cierra y el bloque pasa a "por conciliar" (alerta al dueño).
- `desactivar_equipo(empresa, equipo, motivo)` (G3): sus bloques quedan "por conciliar" (no se anula ningún número).
  Las ventas de las copias en papel se suben (quedan por resolver: "equipo desactivado") y se registran con motivo;
  después `conciliar_bloque(empresa, bloque, motivo, id_operacion)`: los números que de verdad no se usaron quedan
  "no usados" (lista para reportarlos como diga el contador) y el bloque, "conciliado".

## Foto del catálogo (G5) — `preparar_sin_internet(empresa, equipo, {"version"?, "caja_id"?})`

Devuelve: `version` y `catalogo` (o `sin_cambios: true` si el equipo ya tiene esa versión), existencias de la bodega de
la caja (solo para mirar), clientes (nombre, RTN, mayorista), reglas, emisor, perfil sin internet (G1: usuario, rol,
permisos, si cobra, fin de la licencia), caja, turno, bloques activos del equipo, `hora_servidor` y `valido_hasta`.
La foto (`catalogo_foto`, por sucursal y huella; `catalogo_entrega` = a qué equipo se entregó) guarda precio de la
sucursal, "incluye ISV", impuesto, mayorista y "desde cantidad", promociones vigentes (y las que vienen) por producto,
tasas de impuestos y los clientes mayoristas. Sin costos ni saldos de clientes. Las existencias no son parte de la foto.

Al subir, `interno.calcular_venta` (LA MISMA regla de siempre) calcula con la foto: `app.foto_venta` hace que
`producto_de`, `impuesto_de`, `promociones_de`, `mayorista_de`, `cliente_venta_mayorista` y el trigger del mayorista
de la línea lean la foto en vez de los datos de hoy. Prueba 155: 200 carritos dan lo mismo con la foto de hoy.

## Subir — `subir_ventas_sin_internet(empresa, equipo, ventas jsonb (1 a 20), motivo?)`

Cada venta: `{"id_operacion","usuario_id","caja_id","bloque_id","numero","numero_documento","tipo_documento",
"foto_version","hora_equipo","cliente_id"?,"lineas":[{"producto_id","cantidad","precio_tipo","promocion_id"?,
"precio_unitario_centavos","total_centavos"}],"pagos":[{"forma","monto_centavos","recibido_centavos"?,"referencia"?,
"banco"?}],"total_centavos","en_linea","nota"?}`. Respuesta por venta: `registrada`, `por_resolver` (con `problema`,
`problema_texto`, `grave`), `ya_estaba` o `rechazada` (no se guardó: datos mal armados, o la venta es de otro usuario y
quien sube no tiene `ventas.subir_ajenas` o no dio motivo). Además `inventario_negativo` y `avisos` (referencia de
transferencia repetida).

- Idempotente por `id_operacion`, también si la venta entró por `registrar_venta` (G2: "ya estaba").
- Funciona fuera del horario del puesto (M7). Revisa la sesión cerrada y la licencia.
- Cada venta en su propio paso: una que falla no detiene a las demás. **Siempre** queda guardada en
  `venta_sin_internet` con todo lo que mandó el equipo.
- El número: de su bloque, de ese equipo y esa caja, sin repetir (`numero_emitido` es único por serie). Un hueco (una
  venta de otro usuario todavía en el equipo) no es error; se llena cuando sube.
- Por resolver (el número igual queda gastado, 6.3): `precio` (ni la foto ni hoy), `foto`, `numero_invalido` y
  `numero_repetido` (GRAVES), `bloque_por_conciliar`, `equipo_desactivado`, `usuario_desactivado` (venta posterior a
  desactivarlo; la hora sale de la bitácora), `sin_permiso`, `reloj` (más de 10 min en el futuro, antes de la reserva o
  antes que la venta anterior del bloque), `tope_venta`, `tope_turno`, `tarjeta`, `forma_pago`, `referencia`,
  `mes_cerrado` (M5), `sucursal`, `turno`, `cai`, `total`, `cliente`, `otro`.
- Sin existencias: se registra igual (la mercadería ya salió), con `inventario_negativo` y la alerta.
- Se registra a nombre de quien hizo la venta (su turno, su sucursal, la bitácora); `subido_por` y `motivo_subida`
  dicen quién la subió (M2). La venta lleva la nota "Emitida sin conexión" y el nombre del equipo.

## Resolver

- `ventas_sin_internet_por_resolver(empresa, todas?)` (`ventas.resolver_sin_internet`): lista con líneas, pagos,
  usuario, equipo y problema; las graves primero.
- `resolver_venta_sin_internet(id, 'registrar' | 'anular', motivo, id_operacion, {"a_mi_turno"?})`: registrar = como la
  original, con su fecha real (M5: un mes cerrado se reabre primero; nunca con otra fecha); si el precio no era el de la
  foto ni el de hoy, con el precio que cobró el equipo; `a_mi_turno` = el efectivo entra al turno de quien resuelve (el
  de la venta ya se cerró). Un número repetido o fuera del bloque no se registra: se anula y se hace una venta normal.
  Anular = el número queda ANULADO; el dinero se trata como sobrante de caja hasta devolverlo.
- `bloques_sin_internet(empresa)`: equipos (última noticia, sin noticias 48 h), bloques (usados, libres), por resolver
  y reglas. Alerta nueva `sin_internet` (solo si la empresa tiene equipos).

## Transferencias por confirmar (decisión del dueño, 0.20.0)

Una transferencia (con o sin internet) entra a "Transferencias por confirmar": no es dinero disponible.
- `transferencias_por_confirmar(empresa, todas?)` (`dinero.ver` o `dinero.trasladar`): con `referencia_repetida` y
  `sin_internet`.
- `confirmar_transferencia_venta` (la de siempre): Dr banco / Cr por confirmar, con rastro; la conciliación bancaria la
  empareja con la fila del estado de cuenta (prueba 154).
- `marcar_transferencia_no_llego(pago, motivo, id_operacion, {"fecha"?})` (`dinero.trasladar`, una vez): con cliente,
  la venta queda como deuda del cliente (cuenta por cobrar `TRF-<factura>` que se cobra como cualquier otra: Dr
  Clientes / Cr por confirmar); a Consumidor final, deuda del cajero que la registró (Dr Cuentas por cobrar a empleados).
  Con bitácora y motivo. Esa venta ya no se anula completa (se corrige con una devolución).

## Pruebas

152 (subir), 153 (bloques, devolver, turno, desactivar y conciliar, M5, tickets, 48 h), 154 (transferencias), 155
(espejo y tanda de 20 en menos de 8 s), 156 (concurrencia), 157 (de 0.19.0 a 0.20.0 como en Supabase).

## Pendiente (honesto)

- Registrar a mano en la app las ventas de las copias en papel de un equipo perdido (el servidor ya lo acepta por
  `subir_ventas_sin_internet` con el equipo desactivado; falta la pantalla).
- El comprobante que se reimprime desde el servidor no dice "Emitida sin conexión" (la venta lo lleva en la nota).
- `preparar_sin_internet` entrega el catálogo completo cuando cambia (no por páginas ni solo lo que cambió de cada producto).
- El permiso se revisa con el que el usuario tiene al subir (no "a la hora de la venta").

# Facturas de emergencia — módulo "facturas_emergencia" (056, núcleo 0.20.0)

Decisión del dueño: plan B cuando no hay sistema (o el equipo se dañó): facturas escritas a mano en un **talonario de
imprenta con su propio CAI**, que después se pasan al sistema. Módulo que se enciende y apaga como los demás (depende de
`ventas` y `fiscal_hn`; Armador, ficha y `ficha.py` lo conocen). **El contador debe confirmar cómo pedir a la SAR el
CAI del talonario** (imprenta autorizada, punto de emisión propio).

- Permisos: `talonario.administrar` (dueño y admin: registrar y desactivar rangos) y `talonario.registrar` (dueño y
  admin; el dueño se lo puede dar al cajero: pasar facturas y anular números).
- `registrar_talonario(empresa, {"cai","rango_desde","rango_hasta","fecha_limite_emision","nota"?}, id_operacion)`: el
  establecimiento es una sucursal; el **punto de emisión es propio** (nunca el de una caja; una caja nueva no puede
  tomarlo y un rango CAI de caja no puede usar el prefijo de un talonario); sin cruces; CAI vencido no.
  `desactivar_talonario(empresa, talonario, motivo)`.
- `registrar_factura_talonario(empresa, {"talonario_id","numero","fecha","cliente_id"?,"lineas","pagos","caja_id"?,
  "descuento_factura"?,"nota"?}, id_operacion)` (+ `ventas.vender`, y `ventas.cobrar` si entra dinero): número dentro del
  rango (`TALONARIO_INVALIDO`), no usado ni anulado (`TALONARIO_REPETIDO`), la fecha de la copia dentro de la vigencia
  del CAI (`CAI_VENCIDO`) y no futura, mes abierto (`PERIODO_CERRADO`: el dueño lo reabre). Se registra la venta
  completa (inventario, caja o cuenta, ISV, libro de ventas) con ese número, esa fecha y los datos fiscales del talonario
  (`datos_fiscales.talonario = true`). Funciona aunque la caja tenga un bloque sin internet. Una venta que pediría
  aprobación no se pasa (`APROBACION_REQUERIDA`: la pasa quien aprueba).
- `anular_numero_talonario(empresa, talonario, numero, motivo, id_operacion, fecha?)`: un número arruinado queda
  ANULADO y sale en el libro de ventas en cero como "ANULADA" (también los números de un bloque sin internet anulados o
  no usados).
- `talonarios(empresa)`: cada talonario con usados, anulados, libres, **huecos** (libres antes del último usado) y el
  detalle. Prueba 158.
