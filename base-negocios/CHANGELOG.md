# Cambios del núcleo

Formato: versión (fecha) y lista de cambios. La versión vive en `VERSION_NUCLEO`
y queda guardada en cada base al migrar (vista `version_esquema`).
Números: MAYOR.MENOR.ARREGLO (ver `docs/CONVENCIONES.md`).

## 0.8.0 (2026-10-03) — Módulos sin romper los números, ficha del proveedor, límites y decisiones de ventas

Migraciones nuevas 030-032 (las 001-029 no se tocaron). 93 pruebas (nuevas 88-93).

**Dependencias entre módulos como datos (030)** — tabla `modulo_dependencia`: inventario, dinero y
ventas -> contabilidad; compras -> inventario; fiscal_hn -> ventas. No se activa un módulo sin lo que
necesita ni se apaga uno que otro activo usa (`MODULO_DEPENDENCIA` dice cuál); se revisa al final de
cada sentencia (trigger de restricción). Ventas ya NO exige inventario: sin él solo vende servicios
(un bien da `MODULO_INACTIVO`); sin dinero solo vende al crédito. El catálogo (productos, categorías,
unidades, precios) también se edita con solo "ventas" (`interno.modulo_alterno`).

**Apagar = solo impide lo nuevo (030)** — `interno.exigir_escritura` deja pasar, con el módulo apagado
(si estuvo activo), las correcciones de `interno.modulo_apagado_permite`: anular compras, pagos y
saldos iniciales de proveedores, documentos de inventario, operaciones de dinero, gastos y ventas
(solicitar y aprobar), cancelar ventas pendientes, anular cotizaciones, cerrar un turno abierto,
resolver diferencias, confirmar depósitos y transferencias. Las cuentas del módulo (1.1.03.01,
1.1.02.01, 2.1.01.01, 1.1.02.04) siguen sin asientos manuales aunque esté apagado
(`modulo_activo.estuvo_activo`). Nunca se borra nada.

**Decisiones del dueño sobre ventas (031)** — nunca descuento sobre descuento: con varias promociones
vigentes quien vende elige una (`"promocion_id"` por línea; si no, `PROMOCION_A_ELEGIR` con la lista;
`PROMOCION_INVALIDA` si no aplica); una línea con promoción no admite descuento manual y el descuento
de factura va solo a las líneas sin otro descuento (`DESCUENTO_DOBLE`). `promociones_aplicables(...)`.
`empresa.vendedor_cobra` (falso por defecto; solo el dueño con `configurar_empresa`, motivo y
bitácora; perfil pequeño = true; respeta turnos). Confirmados sin cambios: topes de descuento 5 % /
10 % / 20 %, el admin aprueba créditos y anulaciones hasta L 5,000, cotizaciones de 15 días.

**Límites del contrato y solicitudes (032)** — `limite_contrato` (usuarios, cajas, sucursales,
bodegas; null = sin límite) que escribe solo el proveedor; crear o reactivar de más da
`LIMITE_CONTRATO` ("Llegaste al máximo de tu plan. Solicita una ampliación a tu proveedor."); los
desactivados y el usuario del proveedor no cuentan; bajar un límite no desactiva nada.
`solicitud_proveedor`, `solicitar_al_proveedor` (dueño y admin, aun con licencia vencida),
`responder_solicitud_proveedor` (llave del proveedor). `mi_perfil()` trae `limites` (límite y uso) y
`empresa.vendedor_cobra`. Permiso nuevo `proveedor.solicitar`.

**Ficha del proveedor (032 y herramientas)** — `vista_previa_ficha` / `aplicar_ficha` (solo
service_role): módulos en el orden de las dependencias, perfil, licencia y límites, todo o nada, con
bitácora. Ficha formato 2 en `clientes/<cliente>/ficha.json` (ignorada por git salvo
`clientes/ejemplo/ficha.json`; `personal/ficha.schema.json` acepta los dos formatos).
`herramientas/aplicar_ficha.sh` (valida, vista previa, prueba y deshace, confirma con el identificador
del cliente, respaldo cifrado, aplica; `--solo-mostrar`), `herramientas/lista_clientes.sh` (paquete,
módulos, licencia, núcleo, uso/límite con `(!)` al 80 %, solicitudes pendientes; sin acceso muestra
la ficha), `herramientas/ficha.py` (lo usan las tres). `nuevo_cliente.sh` acepta el formato 2 y pone
licencia y límites en la misma transacción. `conexion.sh`: `CONEX_SIN_PEDIR_CLAVE=1`.

**Pruebas nuevas:** 88 dependencias y apagado, 89 combinaciones de módulos con cuadre global (14),
90 promociones y vendedor que cobra, 91 límites y solicitudes, 92 herramientas de la ficha,
93 actualizar desde 0.7.0 con datos.

**Cambios que rompen (para quien ya usaba 0.7.0 en pruebas)**
- Una línea con promoción + descuento manual, o el descuento de factura sobre líneas con otro
  descuento, ahora da `DESCUENTO_DOBLE` o se reparte solo en las líneas libres; con dos promociones
  vigentes hay que mandar `promocion_id`. Se ajustó la prueba 80 (cifras rehechas a mano).
- Activar compras sin inventario o fiscal_hn sin ventas, o apagar inventario/ventas con compras/
  fiscal_hn activos, ahora da `MODULO_DEPENDENCIA`: se ajustaron las pruebas 45, 74 y 85.
- El admin tiene un permiso más (`proveedor.solicitar`) y el perfil un cambio más (`vendedor_cobra`):
  se ajustaron las pruebas 31 y 74.
- `calcular_venta`, `registrar_venta_base`, `configurar_empresa`, `cambios_perfil`, `guardar_perfil`,
  `perfiles_negocio`, `mi_perfil`, `resolver_aprobacion`, `exigir_escritura`,
  `revisar_cuenta_controlada` y `tipo_operacion_2b` se reemplazaron con la misma firma.

**Ventas pendientes y módulos apagados (031):** aprobar una venta pendiente la emite, así que pide
"inventario" (si lleva bienes) y "dinero" (si se cobra al contado) como una venta nueva
(`resolver_aprobacion` reemplazada con la misma firma); rechazarla o cancelarla sí se puede.

**Pendiente (honesto):** aviso automático al proveedor de las solicitudes (hoy en
`lista_clientes.sh`); la doble revisión de límites con dos personas a la vez no tiene prueba de
concurrencia propia (la protege el candado de la fila de límites).

## 0.7.0 (2026-10-03) — Etapa 2b-2a: ventas, CAI, impuestos como datos y servicios

Migraciones nuevas 026-029 (las 001-025 no se tocaron). 87 pruebas (nuevas 77-87).

**Impuestos como datos (026)** — tabla `impuesto` por empresa (código, nombre, porcentaje, clase
gravado/exento/exonerado, cuentas por pagar y de crédito fiscal), sembrada por país
(`interno.plantilla_impuesto`; Honduras: ISV15, ISV18, EXENTO, EXONERADO). `producto.tipo_impuesto`
y `compra_linea.tipo_impuesto` apuntan a la tabla (mismos códigos de antes). `configurar_impuesto`
(solo el dueño), `precio_con_tasa`, `precio_impuesto`. Compras, gastos (`"impuesto"`) y ventas calculan con la tabla.

**Servicios (026)** — `producto.tipo` bien | servicio; un servicio no mueve kardex; costo estimado
opcional en `servicio_costo` (solo con `inventario.costos`, nunca va a los libros);
`empresa.permite_servicios`; unidades SERV, HORA, SES, MES; `v_producto` con tipo e impuesto.

**Régimen fiscal de Honduras (027, módulo `fiscal_hn`)** — `cai_rango` por caja y tipo de documento,
`registrar_cai` / `desactivar_cai` / `reactivar_cai`, numeración del servidor dentro del rango de
ESA caja (sin repetir ni saltar), `SIN_CAI` / `CAI_VENCIDO` / `CAI_AGOTADO`, `cai_alertas` y
`v_cai_rango` (días y % configurables), leyendas y datos fiscales en el documento. Despacho por
régimen (`interno.numero_fiscal`, un solo régimen activo). Sin régimen: ticket interno.

**Ventas (028)** — `registrar_venta` todo o nada (documento, kardex a costo promedio, asiento y
rastro); efectivo (turno), tarjeta (POS por liquidar), transferencia (por confirmar →
`confirmar_transferencia_venta`), crédito (CxC con vencimiento), mixto; consumidor final;
promociones por categoría (`crear_promocion`, `editar_promocion`), descuento por artículo y por
factura prorrateado; topes de descuento por puesto (`configurar_tope_descuento`) y de crédito y
anulación (`configurar_tope_rol` acepta `credito` y `anulacion_venta`); venta pendiente sin mover
nada; `cancelar_venta`; crédito `segun_limite` | `siempre_aprobacion`; anulación solicitada
(`solicitar_anulacion_venta`) y aprobada con motivo; el dinero sale de la misma cuenta.
`resolver_aprobacion` despacha gasto, venta y anulación, con **doble aprobación** (también gastos).
Clientes 1.1.02.01 controlada por el módulo (`MODULO_CON_SALDO` al activar con saldo).
`configurar_empresa`: `credito_politica`, `documento_venta_modo`, `cai_dias_alerta`,
`cai_porcentaje_alerta`, `leyenda_factura`, `cotizacion_dias_vigencia`, `cotizacion_precios`,
`permite_servicios`. El paso "primera venta" del asistente se marca solo.

**Cotizaciones y lecturas (029)** — `crear_cotizacion`, `anular_cotizacion`,
`convertir_cotizacion_a_venta` (respeta precios cotizados si está vigente o recalcula, según
configuración); `v_venta`, `v_venta_linea`, `v_venta_pago`, `v_ventas_por_dia`,
`v_ventas_por_vendedor`, `v_ventas_por_caja`, `v_cxc_documento`, `v_cxc_cliente` (antigüedad),
`v_cotizacion`, `documento_venta` (total en letras) y `seguir_venta`.

**Permisos:** `ventas.ver`, `ventas.vender`, `ventas.cobrar`, `ventas.cotizar`, `ventas.aprobar`,
`ventas.solicitar_anulacion`, `ventas.anular`, `ventas.promociones`, `cai.administrar`,
`impuestos.configurar` (solo dueño). Vendedor: vende, cotiza y solicita; cajero: además cobra;
admin: todo de ventas con topes; contador: `ventas.ver`. Módulo nuevo `fiscal_hn`.

**Ganchos para 2b-2b:** `interno.cobros_vigentes_venta` (hoy 0), `interno.saldo_cxc_cliente`,
`interno.total_cxc`, `v_cxc_documento.cobrado_centavos`.

**Cambios que rompen (para quien ya usaba 0.6.0 en pruebas)**
- Admin, cajero, vendedor, contador y el proveedor con soporte tienen permisos nuevos: se ajustaron
  las pruebas 19, 31, 48, 57 y 69. El error de un impuesto que no existe es `IMPUESTO_INVALIDO`
  (antes `DATO_INVALIDO`): se ajustó la prueba 35.
- `resolver_aprobacion`, `configurar_tope_rol`, `configurar_empresa`, `registrar_compra`,
  `registrar_gasto`, `crear_producto`, `editar_producto`, `estado_arranque`, `mover_inventario`,
  `buscar_producto_por_codigo` y `v_producto` / `v_aprobacion` se reemplazaron con la misma firma
  (las vistas, con columnas nuevas al final).

## 0.6.0 (2026-10-03) — Etapa 2b-1.1: arranque fácil para cualquier tamaño de negocio

Migración nueva 025 (las 001-024 no se tocaron). 76 pruebas (nuevas 72-76).

**Saldo negativo por cuenta de dinero**
- `cuenta_dinero.politica_saldo_negativo`: `no_permitir` (defecto, como antes),
  `permitir_con_alerta` (alerta "Revise el saldo inicial" mientras esté en
  negativo) o `sobregiro_hasta` con `sobregiro_limite_centavos`.
- `configurar_saldo_negativo(empresa, cuenta, politica, limite, motivo)`: solo
  el dueño, con motivo y bitácora; no pasa a una política más estricta si la
  cuenta ya está por debajo. Tránsito siempre `no_permitir`.
- `interno.rastrear_dinero` revisa solo la cuenta de la que SALE dinero (una
  entrada nunca se rechaza). El rastro sigue obligatorio.
- `donde_esta_mi_dinero` trae `alertas` y, por cuenta, `politica_saldo_negativo`
  y `alerta`; `v_cuenta_dinero` tiene columnas nuevas al final.

**Turnos de caja obligatorios o no** — `empresa.turnos_obligatorios` (defecto
true) en `configurar_empresa` (solo el dueño). Sin turnos obligatorios el
efectivo entra a la caja sin turno: `interno.cuenta_efectivo_cobro(empresa, caja?)`
para los cobros de 2b-2; `interno.exigir_turno_abierto` devuelve un turno vacío.

**Perfiles por tamaño** (`interno.plantilla_perfil`, `_modulo`, `_tope`):
`perfiles_negocio()`, `vista_previa_perfil(empresa, perfil)` y
`aplicar_perfil(empresa, perfil, motivo)` (solo el dueño; bitácora). Nunca
borran datos ni activan o desactivan módulos (eso es del proveedor según el
plan). Banderas nuevas en `empresa`: `perfil`, `contabilidad_visible`,
`doble_aprobacion` (también en `configurar_empresa` y en `mi_perfil()->'empresa'`).
`crear_empresa_inicial` acepta `"perfil"` (ficha.schema.json y ficha.ejemplo.json);
sin `"modulos"` en la ficha activa los que sugiere el perfil.

**Asistente de arranque:** `estado_arranque(empresa)` (7 pasos con estado
hecho/saltado/pendiente y porcentaje; "hecho" sale de los datos reales),
`marcar_paso_arranque(empresa, paso, 'saltado'|'pendiente')`, tabla
`arranque_paso`, permiso nuevo `arranque.gestionar` (dueño y admin).
`empezar_cuenta_en_cero(empresa, cuenta)` (solo el dueño). Nunca bloquea operar.

**Valores iniciales confirmados:** admin registra y aprueba gastos hasta
L 5,000.00; arqueo a ciegas; solo la moneda de la empresa (prueba 75).

**Pendiente (honesto):** `doble_aprobacion` solo se guarda; se aplicará en las
aprobaciones de 2b-2. El paso "primera venta" se marcará solo con el módulo de ventas.

**Cambios que rompen:** ninguno para la app. El admin tiene un permiso más
(`arranque.gestionar`): se ajustó la prueba 31.

## 0.5.0 (2026-10-03) — Etapa 2b-1: dinero (y correcciones de la revisión de 0.4.0)

Migraciones nuevas 021-024 (las 001-020 no se tocaron). 71 pruebas.

**Correcciones de la revisión de 0.4.0 (021 y herramientas)**
- A. Una factura cargada como saldo inicial ya no entra como compra si el
  proveedor llega con el uuid en MAYÚSCULAS (se compara como uuid, con el candado).
- B. Activar un módulo toma primero el candado de la empresa: nadie mete un
  asiento a la cuenta controlada mientras se compara libros contra módulo.
- C. Las RPC revisan el `id_operacion` otra vez DESPUÉS de `bloquear_libros`
  (`interno.reservar_operacion`). Antes, un asiento manual y una compra con el
  mismo id al mismo tiempo podían pasar los dos (el asiento devolvía el de la compra).
- D. `conexion.sh`: "base local" es solo el socket de `.pgdata` del proyecto
  (o `BASE_LOCAL_SOCKET`); `localhost` ya no permite `SIN_PREGUNTAR`/`SIN_RESPALDO`.
- E. `nuevo_cliente.sh` pasa la ficha por la entrada estándar de psql, no como argumento.
- F. El motor de inventario bloquea el producto antes que su saldo y nunca deja
  una existencia con decimales en un producto sin decimales (ni al anular);
  quitar "decimales" bloquea los saldos antes de revisar.

**Cuentas de dinero y rastro (022)**
- `cuenta_dinero` (caja, banco con número enmascarado, caja chica con fondo
  fijo, POS por liquidar, transferencias por confirmar, tránsito): crear una
  crea su subcuenta 1.1.01.NN; esa subcuenta no acepta asientos manuales.
- `dinero_movimiento`: una fila por cada línea que toca una cuenta de dinero
  (contrapartida, usuario, equipo, referencia, turno). Sin ella el asiento no
  se confirma (`MOVIMIENTO_SIN_RASTRO`). Ninguna cuenta queda en negativo.
- `trasladar_dinero` (depósito en tránsito, retiro, reposición de caja chica,
  traslado), `confirmar_deposito`, `anular_operacion_dinero`,
  `registrar_saldo_inicial_dinero` (solo dueño), `agregar_adjunto`
  (comprobantes en Storage con huella sha256, solo agregar).
- Lecturas: `donde_esta_mi_dinero`, `estado_cuenta_dinero`, `v_cuenta_dinero`,
  `v_deposito_transito` (alerta con `dias_alerta_transito`, nueva clave de `configurar_empresa`).
- Compras: `registrar_compra` acepta `cuenta_dinero_id`; `pagar_proveedor`
  tiene un último parámetro opcional `p_cuenta_dinero_id`; pagos, compras de
  contado y sus anulaciones dejan rastro.

**Turnos de caja (023):** `abrir_turno`, `cerrar_turno` (arqueo con conteo por
denominación), `resolver_diferencia` (al cajero, a gasto u otros ingresos),
`mi_turno`, `v_turno_caja`, `v_diferencia_cajero`. Cuentas nuevas 1.1.02.04,
1.1.02.05, 4.2.01.03, 6.1.02.11 (siguiente código libre si ya eran del cliente).

**Gastos (024):** categorías, `registrar_gasto` (ISV crédito fiscal con
factura y RTN), topes por puesto (`configurar_tope_rol`), aprobaciones
genéricas (`resolver_aprobacion`), `anular_gasto`, `cuadre_caja_chica`,
pagos fijos (`crear_pago_fijo`, `editar_pago_fijo`, `registrar_pago_fijo`,
`pagos_fijos_proximos`, `reporte_pagos_fijos`).

**Permisos y módulo:** módulo nuevo `dinero`. Permisos `dinero.ver`,
`dinero.administrar`, `dinero.trasladar`, `dinero.anular`,
`dinero.saldo_inicial` (solo dueño), `adjuntos.agregar`, `caja.turno`,
`caja.supervisar`, `gastos.registrar`, `gastos.aprobar`, `gastos.anular`,
`aprobaciones.ver`. Admin: todo menos saldos iniciales; contador: `dinero.ver`
y `aprobaciones.ver`; cajero: `caja.turno` y `adjuntos.agregar`; vendedor: nada de dinero.

**Cambios que rompen (para quien ya usaba 0.4.0 en pruebas)**
- `pagar_proveedor` tiene 9 parámetros (el último opcional): las llamadas de
  antes funcionan igual, pero quien la referencie por su firma de 8 debe usar la nueva.
- Empresas NUEVAS traen 6.1.02.11 "Faltantes de caja" (y 1.1.02.04/05,
  4.2.01.03): una subcuenta propia del cliente toma el siguiente número.
- `SIN_PREGUNTAR`/`SIN_RESPALDO` ya no aceptan `localhost`.
- Se ajustaron las pruebas 19, 31, 32, 48 y 57 (permisos nuevos, código
  6.1.02.11 ocupado, última migración).

## 0.4.0 (2026-10-03) — Correcciones de la revisión de la etapa 2a

Migraciones nuevas 017-020 (las 001-016 no se tocaron). 57 pruebas.

**Compras y cuentas por pagar (019)**
- `anular_pago_proveedor(pago, motivo, id_operacion, fecha?)`: contra-asiento a
  la MISMA cuenta de dinero, mes abierto, una sola vez, nunca con fecha anterior
  al pago; la factura recupera su saldo. Sin pagos vigentes, `anular_compra` ya
  funciona. Patrón documentado para los cobros de 2b (CONVENCIONES).
- Saldos iniciales de proveedores: `registrar_saldo_inicial_cxp` /
  `anular_saldo_inicial_cxp` (permiso `compras.saldo_inicial`, solo dueño).
  Salen en `v_cxp_documento` / `v_cxp_proveedor` y se pagan con `pagar_proveedor`.
- `v_cxp_documento`: columnas nuevas al final `origen`, `documento_id`,
  `fecha_documento` (la antigüedad se cuenta desde la fecha de la factura).
- Activar inventario o compras con saldo en 1.1.03.01 / 2.1.01.01 que el
  módulo no explica se rechaza (`MODULO_CON_SALDO`) con el procedimiento P-07.

**Inventario (018)**
- Cuenta nueva 3.3.01.03 "Saldos de apertura" (patrimonio): la carga inicial
  va contra ella (antes 3.1.01.01). Si el código ya era del cliente, se usa el
  siguiente libre (3.3.01.04...).
- `anular_documento_inventario(documento, motivo, id_operacion, fecha?)` para
  carga inicial, ajuste y traslado, solo sin movimientos posteriores
  (`MOVIMIENTOS_POSTERIORES`). Una carga anulada se puede volver a cargar.
- Costo promedio en orden de registro: una entrada con fecha anterior a la
  última salida del producto en esa bodega se rechaza (`ENTRADA_FECHA_ATRASADA`)
  salvo permiso `inventario.fecha_atrasada` (solo dueño).
- 0 unidades = L 0.00: el valor que sobre pasa a 5.1.01.02 con una línea
  `ajuste_costo` en el kardex y su asiento.
- `permite_fracciones` no se apaga con existencias fraccionarias.
- `desactivar_sucursal` rechaza si sus bodegas tienen existencias o valor.
  Nuevas: `reactivar_sucursal`, `reactivar_caja`, `reactivar_bodega`,
  `reactivar_categoria`, `reactivar_campo_extra`.

**Seguridad (017)**
- Rol `contador`: solo lectura (contabilidad, reportes, bitácora, terceros,
  compras, existencias CON costos). Solo el dueño lo crea; nunca recibe
  permisos de movimiento ni de administrar.
- Permiso `terceros.ver` (financiero): el proveedor ya no ve clientes ni
  proveedores (ni límites de crédito) sin acceso de soporte vigente.
- RLS: el filtro por permiso se calcula una vez por consulta
  (`empresa_id = ANY (ARRAY(SELECT empresas_con_permiso(...)))`) e índices nuevos.
- `id_operacion` por tipo: un reintento solo se reconoce si es del mismo tipo
  de operación; si no, `ID_OPERACION_USADO` (antes un asiento manual con el id
  de una compra devolvía el asiento de la compra como "duplicado").
- `anular_asiento`: la fecha no puede ser anterior al asiento original.
- Ajustes, traslados, cargas y anulaciones no devuelven costos a quien no
  tiene `inventario.costos` (vienen en null con `"costos_ocultos": true`).

**Precio con o sin ISV (020, decisión del dueño)**
- `producto.precio_incluye_isv` y `empresa.precio_incluye_isv_defecto`
  (true; lo cambia solo el dueño con `configurar_empresa`). El precio se
  guarda tal como se escribe. `public.precio_isv()` y vista `v_producto` con
  precio sin y con ISV (ISV por línea, redondeo a centavo, mitades hacia arriba).
  El historial de precios guarda la marca.

**Herramientas y procedimientos**
- `migrar.sh` y `nuevo_cliente.sh`: muestran el servidor completo y avisan si
  usan una DATABASE_URL de la terminal; se confirma escribiendo la referencia
  del proyecto de Supabase o el nombre de la empresa que ya está en la base.
- La clave nunca va como argumento de psql/pg_dump: pgpass temporal (600) que
  se borra; si falta, se pide con `read -s`. `SIN_PREGUNTAR`/`SIN_RESPALDO`
  solo con base local.
- Respaldos CIFRADOS (age con llave pública, o gpg AES256); nuevos
  `respaldar.sh` y `restaurar.sh` (en base nueva, todo o nada, con revisión).
- PROCEDIMIENTOS: P-03 reescrito, P-06 simulacro de restauración, P-07
  activar un módulo con saldos previos; nota honesta sobre el acceso técnico
  del proveedor (service_role / clave postgres).

**Cambios que rompen (para quien ya usaba 0.3.0 en pruebas)**
- Carga inicial de inventario: el haber va a 3.3.01.03 (antes 3.1.01.01).
  Las cargas viejas no se tocan; al anularlas vuelven contra 3.1.01.01.
- Productos creados antes de 0.4.0 quedan con `precio_incluye_isv = false`
  (su precio era sin ISV). Los nuevos toman el defecto de la empresa (true).
- Leer `tercero` pide `terceros.ver` (se dio a dueño, admin, cajero, vendedor).
- `pago_proveedor.compra_id` puede venir vacío (pago de un saldo inicial:
  `saldo_inicial_id`). `pagar_proveedor` acepta el id de la compra o del saldo inicial.
- `migrar.sh` ya no deja respaldos sin cifrar; pide frase o llave (P-03).
- Se ajustaron las pruebas 19, 20, 31, 36 y 39 (permisos nuevos, respaldo cifrado, cuenta de apertura).

## 0.3.0 (2026-10-03) — Etapa 2a

Migraciones nuevas 012-016 (las 001-011 no se tocaron). 43 pruebas.

**Roles (decisión del dueño, 012)**
- El admin, por defecto: agrega y desactiva usuarios cajero y vendedor
  (crear o desactivar administradores es solo del dueño), sucursales, cajas y
  bodegas; catálogos, precios, clientes y proveedores; crédito hasta el tope
  del dueño; compras, pagos, ajustes y traslados.
- El admin nunca nombra ni toca dueños ni administradores, no toca al
  proveedor y no da (ni cambia o desactiva a alguien con) un rol con permisos
  que él no tiene.
- Solo del dueño, sin poder delegarse: `permisos.editar`, `periodos.reabrir`,
  `soporte.otorgar`, `empresa.configurar`.
- `configurar_empresa`: tope de límite de crédito y permitir existencia negativa.
- Contraseñas: quedan en Supabase Auth; alta con clave temporal y
  restablecer por Edge Function (pendiente, ver `nucleo/docs/usuarios.md`).

**Clientes y proveedores (013):** una tabla `tercero` con roles, RTN
validado, teléfono, correo, límite de crédito (centavos) y plazo. Crear,
editar, desactivar y reactivar; historial en bitácora.

**Productos (014):** unidades, categorías (3 niveles), campos extra
validados por empresa, productos con código interno y de barras únicos,
ISV15/ISV18/EXENTO, precio en centavos, historial de precios con motivo.

**Inventario (015):** bodegas; kardex solo-agregar con costo promedio
ponderado y saldos por bodega actualizados en la misma transacción con
candado; existencia negativa solo con configuración o permiso (con alerta);
ajustes por conteo físico con asiento; traslados; carga inicial con asiento
de apertura; búsqueda por código de barras; vistas `v_existencia` y `v_kardex`.

**Compras (016):** compras al contado o crédito (documento + kardex + asiento
en una transacción), ISV crédito fiscal, anulación con contra-movimiento y
contra-asiento, pagos a proveedores sin pasar el saldo; el dinero sale de la
caja o banco elegido (subcuenta de 1.1.01) y la anulación vuelve a ella; vistas
`v_cxp_documento` y `v_cxp_proveedor` con antigüedad.

**Cuadre con la contabilidad:** con inventario o compras activos, las
cuentas 1.1.03.01 y 2.1.01.01 no aceptan asientos manuales
(`CUENTA_CONTROLADA`), y `anular_asiento` no anula asientos de un módulo.

**Cambios que rompen (para quien ya usaba 0.2.0 en pruebas)**
- El admin ya tiene `usuarios.administrar` y `sucursales.administrar`;
  cajero y vendedor tienen `inventario.ver` y `terceros.editar` (se dan
  también a las empresas ya instaladas).
- Asientos manuales a 1.1.03.01 / 2.1.01.01 se rechazan si el módulo
  inventario / compras está activo.
- Se ajustaron las pruebas 19, 31 y 32 a los permisos nuevos.

## 0.2.0 (2026-10-03) — Etapa 1.5

Las migraciones 001-007 se corrigieron directamente (ningún cliente las tenía
instaladas); lo nuevo va en 008-011.

**Seguridad y auditoría**
- Bitácora con huella encadenada (sha256 por fila + huella anterior, por
  empresa) y `verificar_bitacora()` que detecta filas editadas, borradas o
  metidas a la fuerza.
- El proveedor ya no ve cifras (asientos, saldos, bitácora) por defecto ni
  recibe permisos por la tabla de roles. Nuevo acceso de soporte temporal:
  el dueño lo da con motivo y vencimiento (máx. 30 días), vence solo, se
  puede revocar y queda en bitácora (`otorgar_acceso_soporte`,
  `revocar_acceso_soporte`).
- `cambiar_permiso_rol` exige motivo (mín. 5 letras), que queda en bitácora.
- Permisos nuevos: `usuarios.administrar`, `sucursales.administrar`,
  `catalogo.editar`, `soporte.otorgar`. Columna `permiso.es_financiero`.

**Contabilidad**
- Fecha contable entre `empresa.fecha_inicio` y hoy + `dias_futuro_max`
  (3 por defecto, configurable 0-31).
- Cierre de meses en orden; meses anteriores sin movimientos se cierran
  solos; no se cierra el mes en curso ni futuros; se reabre solo el último
  cerrado.
- Al registrar se exige sucursal activa (error claro si no hay ninguna).
- `saldo_cuentas(empresa, desde, hasta)`: saldo inicial, movimiento y saldo final.
- Registrar, anular, cerrar y reabrir se ordenan con el mismo candado por
  empresa (sin números repetidos ni huecos con varias personas a la vez).

**Empresa e instalación**
- `empresa`: `moneda` ISO 4217 (defecto HNL), `pais` ISO 3166 (defecto HN),
  `rubro`, `fecha_inicio`, `dias_futuro_max`; zona horaria validada.
- `hoy_local()` usa la zona horaria de la empresa.
- `crear_empresa_inicial(ficha jsonb)` valida la ficha campo por campo.
  `personal/ficha.schema.json` (JSON Schema) y `herramientas/nuevo_cliente.sh`.
- Fechas exportadas en ISO 8601 (`iso()` para fecha y hora en UTC).

**App**
- `mi_perfil()`: usuario, empresa, rol, permisos, módulos y estado de licencia
  (activa / en gracia / solo lectura, con días).
- Administración: agregar/desactivar usuarios, crear/desactivar sucursales y
  cajas, crear subcuentas.
- Catálogo de errores (`error_catalogo`): mensaje sencillo y qué hacer.

**Herramientas**
- `migrar.sh`: muestra a qué base se conecta, `--solo-mostrar`, pide
  escribir el nombre de la base, respaldo previo con pg_dump en `respaldos/`.
- `probar.sh`: también corre pruebas `.sh`; la versión esperada sale de
  `VERSION_NUCLEO`. 32 pruebas.

**Cambios que rompen (para quien ya usaba 0.1.0 en pruebas)**
- `crear_empresa_inicial(nombre, rtn, dueño, proveedor)` ahora es
  `crear_empresa_inicial(ficha jsonb)`.
- `cambiar_permiso_rol` tiene un quinto parámetro obligatorio: `motivo`.
- `hoy_local()` ahora acepta la empresa: `hoy_local(empresa)`.
- La ficha usa `nombre` en vez de `nombre_comercial`.

## 0.1.0 — Etapa 1

- Esquema base: empresa, sucursal, caja (punto de emisión), roles, permisos
  editables por empresa, usuarios por empresa, módulos y licencia.
- Bitácora solo-agregar; nada se borra ni se edita (ni el superusuario).
- Catálogo de cuentas NIIF para PYMES.
- Meses contables: cerrar y reabrir con motivo.
- Asientos de partida doble con `id_operacion` (sin duplicados), anulación
  por contra-asiento, numeración sin huecos.
- RLS: cada quien ve solo su empresa. Licencia vencida = solo lectura.
- `probar.sh` y `migrar.sh`. 16 pruebas.
