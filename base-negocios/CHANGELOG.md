# Cambios del núcleo

Formato: versión (fecha) y lista de cambios. La versión vive en `VERSION_NUCLEO`
y queda guardada en cada base al migrar (vista `version_esquema`).
Números: MAYOR.MENOR.ARREGLO (ver `docs/CONVENCIONES.md`).

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
