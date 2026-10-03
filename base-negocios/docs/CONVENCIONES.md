# Convenciones del núcleo

Reglas para que todo el código se vea y funcione igual. Si algo nuevo no
cabe en estas reglas, se discute antes de programarlo.

## Nombres
- Todo en **español, sin tildes ni ñ** en nombres de tablas, columnas y
  funciones: `dueno`, `anio`, `sucursal`, `asiento_linea`.
- Tablas en **singular**: `empresa`, `cuenta`, `periodo`.
- Columnas que apuntan a otra tabla: `<tabla>_id` (`empresa_id`, `cuenta_id`).
- Sí/no: palabra que se lea como pregunta: `activa`, `es_detalle`, `suspendida`.
- Funciones que la app llama (RPC): verbo + cosa: `registrar_asiento`,
  `cerrar_periodo`, `crear_caja`. Parámetros con `p_` (`p_empresa_id`).
- Esquema `public`: lo que ve la app (con RLS). Esquema `interno`: lo
  privado (plantillas, contadores, funciones de ayuda). Nunca se expone.

## Dinero y cantidades
- Dinero **siempre en centavos enteros** (`bigint`), columnas terminadas en
  `_centavos`. L 115.00 = `11500`. Nunca `numeric` ni decimales para dinero.
- Tope por monto: 9,007,199,254,740,991 (el mayor entero exacto en JavaScript).
- Cantidades (unidades, kilos) sí pueden llevar decimales: `numeric(18,4)`.
- Costo unitario (centavos por unidad): `numeric(18,6)`, columnas
  `costo_unitario` / `costo_promedio` (única excepción a "centavos enteros":
  el valor total que llega a los libros siempre se redondea a centavos).
- Datos de documentos (compras, terceros, productos) llegan en `jsonb` con
  claves conocidas; una clave que no se reconoce es error.
- Moneda de la empresa: código ISO 4217 (`HNL`, `USD`).
- **ISV:** el precio se guarda como lo escribe el usuario, con la marca
  `precio_incluye_isv`. La cuenta sale SIEMPRE de `public.precio_isv(precio,
  incluye, impuesto, cantidad)`: por LÍNEA (sobre cantidad x precio), redondeo
  a centavo con mitades hacia arriba. Si incluye: sin = round(total / (1 + tasa)),
  ISV = total - sin. Si no: ISV = round(sin x tasa), con = sin + ISV.
- **Costo promedio:** se calcula en el ORDEN DE REGISTRO (no por fecha). Una
  entrada no puede tener fecha anterior a la última salida del producto en
  esa bodega, salvo permiso `inventario.fecha_atrasada` (y entonces lo ya
  salido no se recalcula). 0 unidades = L 0.00 (lo que sobre va a ajuste de costo).

- **Impuestos (0.7.0):** nunca tasas fijas en el código: la tasa sale de la tabla
  `public.impuesto` de la empresa (`interno.impuesto_de`, `public.precio_con_tasa`,
  `public.precio_impuesto`). Cada documento guarda el código y la tasa que usó.
  `public.precio_isv` (tasas de Honduras) queda solo por compatibilidad.
- **Servicios (0.7.0):** `producto.tipo = 'servicio'` nunca entra al kardex.

## Fechas y horas
- Columnas de momento (fecha + hora) terminan en **`_en`**: `creado_en`,
  `registrado_en`, `vence_en`, `revocado_en`. Tipo `timestamptz`. Las pone
  el servidor con `now()`, nunca el navegador.
- Columnas de solo fecha terminan en `fecha_...` o `_el`: `fecha_contable`,
  `fecha_inicio`, `vence_el`. Tipo `date`.
- "Hoy" siempre con `hoy_local(empresa)` (zona de la empresa).
- Todo lo que se exporta (JSON, CSV, reportes) va en **ISO 8601**:
  `2026-01-31` y `2026-01-31T18:00:00Z` (UTC, con `iso()`).
- País: ISO 3166-1 de 2 letras (`HN`).

## Permisos
- Formato **`modulo.accion`**, en minúsculas: `asientos.registrar`,
  `contabilidad.ver`, `usuarios.administrar`.
- `es_movimiento = true` si mueve los libros (el proveedor nunca lo tiene).
- `es_financiero = true` si deja leer cifras (el proveedor solo con soporte
  temporal vigente).
- Toda función que escribe empieza con `interno.exigir_escritura(...)`;
  toda función que lee cifras, con `interno.exigir_lectura(...)`.
- Rol `contador`: solo permisos de lectura (`es_financiero` o `*.ver`, nunca
  `es_movimiento`). Lo vigila un trigger; solo el dueño crea contadores.
- Una RPC que devuelve montos de costo (kardex, ajustes, traslados) los pasa
  por `interno.ocultar_costos(...)`: sin `inventario.costos` llegan en null y
  con `"costos_ocultos": true` (desde 0.9.1 en cualquier nivel de la respuesta, también anidados).

## Errores
- Todo `RAISE EXCEPTION` empieza con una CLAVE en mayúsculas y dos puntos:
  `'NO_CUADRA: el debe ... '`. La clave va en `error_catalogo` con su
  mensaje sencillo y qué hacer (en la misma migración que la usa).

## id_operacion
- Cada RPC que crea algo recibe un `id_operacion` (uuid) y llama
  `interno.exigir_tipo_operacion(empresa, id, 'tipo')`: un reintento solo se
  reconoce si el id ya se usó para el MISMO tipo de operación; si se usó para
  otra cosa, `ID_OPERACION_USADO`.
- Orden (desde 0.5.0): permiso -> revisión rápida del tipo -> validaciones ->
  `interno.reservar_operacion(empresa, id, tipo)` (toma `bloquear_libros` y
  revisa el tipo OTRA VEZ, ya con lo que otros confirmaron) -> "¿ya existe?" ->
  guardar. Sin la segunda revisión, dos operaciones distintas con el mismo id
  al mismo tiempo podían pasar las dos.
- Al agregar una tabla con `id_operacion` (desde 0.9.0): una fila en
  `interno.id_operacion_uso (tabla, columna, tipo, orden)` en la migración
  nueva; `interno.tipo_operacion_2b2` la revisa sola (antes había que
  reemplazar `interno.tipo_operacion_2b`).

## Anular (patrón; los cobros de 0.9.0 lo copian: `anular_cobro`)
- El documento original NO se edita: la anulación es una fila aparte
  (`pago_proveedor_anulacion`, `inventario_documento_anulacion`) o columnas
  de anulación que se llenan una sola vez (compra, saldo inicial).
- **Anular un abono** (pago a proveedor hoy; cobro a cliente en 2b):
  `anular_X(id, motivo, id_operacion, fecha?)` con permiso propio; motivo de
  5 letras o más; fecha por defecto hoy y nunca anterior al abono; candado de
  la empresa (`bloquear_libros`); mes abierto; una sola vez (`YA_ANULADO`);
  contra-asiento con `anula_asiento_id` = asiento del abono, a la MISMA
  cuenta de dinero del abono (Dr esa cuenta / Cr CxP en pagos; en cobros:
  Dr CxC / Cr esa cuenta); el saldo del documento se calcula sumando solo
  abonos NO anulados; el documento se puede anular cuando ya no tiene abonos
  vigentes.

## Cuentas de los módulos
- Las cuentas que usa un módulo están en `interno.cuenta_sistema` (un solo
  lugar). Si `modulo_controla` está activo, esa cuenta no acepta asientos
  manuales. Los asientos de un módulo se anulan desde su documento.
- El código de un uso se pide SIEMPRE con `interno.cuenta_de(empresa, uso)`:
  si el código de la plantilla ya era del cliente, la cuenta se creó en el
  siguiente libre y quedó anotada en `interno.cuenta_sistema_empresa`
  (`interno.asegurar_cuenta_uso` al instalar una versión nueva).

## Rastro del dinero (0.5.0; ventas y cobros de 2b-2 lo copian)
- Todo lugar con dinero es una `cuenta_dinero` con su subcuenta 1.1.01.NN.
- Toda RPC que crea un asiento que toca una cuenta de dinero llama, en la
  misma transacción y con el candado tomado, a
  `interno.rastrear_dinero(asiento, operacion, documento_tipo, documento_id, referencia, equipo)`.
  Si lo olvida, el asiento no se confirma (`MOVIMIENTO_SIN_RASTRO`). La
  función también aplica la política de saldo negativo de cada cuenta (0.6.0:
  por defecto no permitir) y no deja pasar el fondo de la caja chica.
- Lo que se paga se valida con `interno.cuenta_dinero_para_pagar` (caja,
  caja chica o banco). El equipo sale de `interno.equipo(datos)`.
- Un cobro en efectivo (2b-2) toma su cuenta con `interno.cuenta_efectivo_cobro(empresa, caja?)`
  (turno abierto del usuario; sin turno solo si la empresa no los exige).
- Efectivo que SALE por una anulación o devolución (0.9.1, decisión del dueño):
  la cuenta sale de `interno.cuenta_salida_efectivo(empresa, cuenta, autorizados, sustituir)`
  (turno abierto de quien hace la operación; nunca el turno de otro cajero:
  `TURNO_AJENO`) y, antes de `rastrear_dinero`, `set_config('app.turno_origen', <turno original>, true)`
  (se limpia después) para que el movimiento lleve `turno_origen_id`.
- Comprobantes: `"comprobante": {"ruta","tipo","sha256"}` en los datos o
  `agregar_adjunto`; la ruta empieza con el id de la empresa.

## Aprobaciones (0.5.0; 2b-2 las reutiliza)
- Una fila en `aprobacion` (tipo, documento, monto, solicitante, estado). El
  documento queda "pendiente" SIN mover nada; `resolver_aprobacion` despacha
  por tipo, revisa el tope del puesto (`interno.tope_rol`), que nadie resuelva
  lo que pidió (salvo el dueño) y aplica o rechaza (con motivo) una sola vez.
- Para un tipo nuevo: su permiso, su tope en `tope_rol` y su rama en
  `resolver_aprobacion` (migración nueva).

- **Doble aprobación (0.7.0):** `aprobacion.aprobaciones_requeridas` se fija al
  pedir (trigger); cada rama de `resolver_aprobacion` llama `interno.paso_aprobacion`
  antes de aplicar (la primera solo se anota; el dueño aprueba solo).
- **Régimen fiscal (0.7.0):** el núcleo no conoce el CAI: pide
  `interno.numero_fiscal(...)` e imprime `interno.bloque_fiscal(venta)`. Un régimen
  nuevo es un módulo `fiscal_xx` que agrega su rama en esas dos funciones.

## Vistas
- Por defecto `security_invoker = true` (respetan RLS).
- Políticas y vistas que piden un permiso usan
  `empresa_id = ANY (ARRAY(SELECT public.empresas_con_permiso('permiso')))`:
  PostgreSQL lo calcula una vez por consulta. Nunca `tiene_permiso(...)` por
  fila en una política (la prueba 53 lo vigila).
- Si hay que ocultar columnas según el permiso (ej. costos), vista "del
  sistema" con filtro explícito `public.puede_leer(empresa, permiso)`.
- Una vista `security_invoker` no llama funciones de `interno` (el usuario
  no las puede ejecutar) ni lee `auth.users`: para nombres, `public.nombre_usuario()`.
  Lo que necesite cálculos internos va en una RPC de lectura (`exigir_lectura`).

## Funciones
- `SECURITY DEFINER` siempre con `SET search_path = ''` y nombres completos
  (`public.asiento`), para que nadie "cuele" objetos.
- Cada RPC nueva: `REVOKE` de todos y `GRANT` solo a quien la usa.
- Lo que cambia algo con motivo usa `set_config('app.motivo', ..., true)`
  para que lo tome la bitácora, y lo limpia al terminar.

## Migraciones
- Archivo `NNN_nombre.sql` (tres dígitos): `012_ventas.sql`.
- Una migración **aplicada en un cliente no se edita nunca**: se crea la
  siguiente. `migrar.sh` lo detecta por la huella (sha256) del archivo.
- Cada migración corre completa o nada (una transacción).
- Toda tabla nueva en `public`: RLS activado, política de lectura, trigger
  `no_vaciar`, y si guarda datos del negocio: `auditar` y `no_borrar`.
- Cada cambio lleva su prueba en `nucleo/pruebas/prueba_NN_que_prueba.sql`
  (o `.sh`). La primera línea `-- PRUEBA:` / `# PRUEBA:` dice qué prueba.

## Herramientas (bash)
- Se conectan con `herramientas/conexion.sh`: la clave nunca va como
  argumento de psql/pg_dump ni en PGPASSWORD (pgpass temporal 600 que se
  borra); se confirma con un identificador único del proyecto; los
  respaldos salen cifrados. `SIN_PREGUNTAR` / `SIN_RESPALDO` solo con la base
  local de pruebas: el socket de `.pgdata` o `BASE_LOCAL_SOCKET` (nunca
  `localhost`). Datos del cliente (ficha) por la entrada estándar, no como argumento.

## Versiones (VERSION_NUCLEO)
- MAYOR.MENOR.ARREGLO. ARREGLO: corrección sin cambios de uso. MENOR:
  funciones o columnas nuevas. MAYOR: algo deja de funcionar como antes.
- Cada versión se anota en `CHANGELOG.md`.
