# Cambios del núcleo

Formato: versión (fecha) y lista de cambios. La versión vive en `VERSION_NUCLEO`
y queda guardada en cada base al migrar (vista `version_esquema`).
Números: MAYOR.MENOR.ARREGLO (ver `docs/CONVENCIONES.md`).

## 0.3.0 (2026-10-03) — Etapa 2a

Migraciones nuevas 012-016 (las 001-011 no se tocaron). 43 pruebas.

**Roles (decisión del dueño, 012)**
- El admin, por defecto: agrega y desactiva usuarios, sucursales, cajas y
  bodegas; catálogos, precios, clientes y proveedores; crédito hasta el tope
  del dueño; compras, pagos, ajustes y traslados.
- El admin nunca nombra ni toca dueños, no toca al proveedor y no da (ni
  cambia o desactiva a alguien con) un rol con permisos que él no tiene.
- Solo del dueño, sin poder delegarse: `permisos.editar`, `periodos.reabrir`,
  `soporte.otorgar`, `empresa.configurar`.
- `configurar_empresa`: tope de límite de crédito y permitir existencia negativa.
- Contraseñas: quedan en Supabase Auth; alta con clave temporal y
  restablecer por Edge Function (pendiente, ver `nucleo/docs/usuarios.md`).

**Clientes y proveedores (013):** una tabla `tercero` con roles, RTN
validado, teléfono, correo, límite de crédito (centavos) y plazo. Crear,
editar, desactivar; historial en bitácora.

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
contra-asiento, pagos a proveedores sin pasar el saldo, vistas
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
