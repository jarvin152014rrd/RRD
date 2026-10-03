# Base de Negocios — Núcleo

Base para programas de administración de negocios (Honduras, lempiras).
La app será una PWA (página web instalable) y los datos vivirán en Supabase
(PostgreSQL). **Toda la lógica de dinero corre en el servidor**, dentro de
funciones SQL que guardan todo o nada. El navegador solo muestra y llama
esas funciones.

Versión del núcleo: ver `VERSION_NUCLEO` (hoy 0.6.0, etapa 2b-1.1: arranque fácil). Cambios: `CHANGELOG.md`.

## Carpetas

```
base-negocios/
├── VERSION_NUCLEO          versión del núcleo
├── CHANGELOG.md            qué cambió en cada versión
├── docs/                   CONVENCIONES, PERSONALIZAR, PROCEDIMIENTOS
├── nucleo/                 IGUAL para todos los clientes (no se edita por cliente)
│   ├── sql/migraciones/    cambios a la base, numerados: 001_, 002_, ...
│   ├── pruebas/            pruebas automáticas + simulador de Supabase
│   └── docs/               una hoja corta por módulo del núcleo
├── personal/               lo propio de cada cliente (ficha, tema, plantillas)
│   ├── ficha.schema.json   reglas de la ficha (JSON Schema)
│   └── ficha.ejemplo.json  ficha de ejemplo (formato 1, el de antes)
├── clientes/               una carpeta por cliente con su ficha.json (NO se sube a git,
│   └── ejemplo/ficha.json  salvo esta muestra del formato 2)
├── app/                    aquí irá la PWA
├── respaldos/              respaldos de migrar.sh (NO se sube a git)
└── herramientas/
    ├── probar.sh           corre todas las pruebas
    ├── migrar.sh           respalda (cifrado) y aplica migraciones pendientes
    ├── nuevo_cliente.sh    crea la empresa de un cliente desde su ficha
    ├── aplicar_ficha.sh    lleva a la base lo que dice la ficha (módulos, perfil, licencia, límites)
    ├── lista_clientes.sh   tabla de clientes: paquete, módulos, licencia, núcleo, uso/límite
    ├── ficha.py            (lo usan los otros) lee y valida fichas
    ├── respaldar.sh        respaldo completo cifrado (age o gpg)
    ├── restaurar.sh        restaura un respaldo en una base NUEVA y la revisa
    ├── conexion.sh         (lo usan los otros) conexión sin exponer la clave
    └── servidor_local.sh   (lo usan los otros) PostgreSQL local de pruebas
```

Qué hace cada migración:

| Archivo | Contenido |
|---|---|
| 001_base | empresa, sucursal, caja (punto de emisión), roles, permisos, usuarios, módulos, licencia |
| 002_bitacora | bitácora de auditoría (solo agregar) y bloqueo de borrados |
| 003_catalogo_cuentas | catálogo de cuentas NIIF para PYMES |
| 004_periodos | meses contables: cerrar y reabrir |
| 005_asientos | asientos de partida doble: registrar y anular |
| 006_seguridad | RLS (cada quien ve solo su empresa) y permisos |
| 007_instalacion | crear una empresa nueva desde su ficha (jsonb) |
| 008_catalogo_errores | mensaje sencillo y qué hacer para cada código de error |
| 009_soporte | acceso de soporte temporal del proveedor (lo da el dueño) |
| 010_administracion | `mi_perfil`, usuarios, sucursales, cajas, subcuentas |
| 011_reportes | `saldo_cuentas(desde, hasta)` para los estados mensuales |
| 012_roles_admin | lo que puede el admin, permisos solo del dueño, `configurar_empresa` |
| 013_terceros | clientes y proveedores (una tabla) |
| 014_productos | unidades, categorías, campos extra, productos, historial de precios |
| 015_inventario | bodegas, kardex con costo promedio, ajustes, traslados, carga inicial, existencias |
| 016_compras | compras, anulación, pagos a proveedores, CxP con antigüedad |
| 017_seguridad_operaciones | rol contador, `terceros.ver`, RLS más rápido, índices, `id_operacion` por tipo, fecha de anulación, costos ocultos |
| 018_inventario_correcciones | Saldos de apertura, fecha atrasada, 0 unidades = L 0, fracciones, reactivar, anular documentos de inventario |
| 019_compras_correcciones | anular pagos, saldos iniciales de proveedores, activar módulos con saldo |
| 020_precios_isv | precio con o sin ISV, `precio_isv()`, `v_producto` |
| 021_correcciones_revision_040 | id_operacion revisado después del candado, activar módulos con candado, factura de saldo inicial por uuid, fracciones sin carrera |
| 022_dinero | cuentas de dinero con su subcuenta, rastro del dinero, depósitos (en tránsito), retiros, traslados, saldos iniciales, comprobantes, compras con cuenta de dinero, "dónde está mi dinero" y estado de cuenta |
| 023_caja_turnos | turnos de caja por cajero, arqueo (conteo por denominación), diferencias pendientes y su resolución |
| 024_gastos | categorías de gasto, gastos con ISV, topes por puesto, aprobaciones (genéricas), caja chica (cuadre), pagos fijos |
| 025_arranque_facil | saldo negativo por cuenta (solo el dueño), turnos obligatorios o no, perfiles pequeño/mediano/grande, asistente de arranque, empezar en cero |
| 026_impuestos_servicios | impuestos como datos por empresa, servicios (sin kardex) |
| 027_fiscal_hn | régimen fiscal de Honduras: CAI por caja, numeración, alertas |
| 028_ventas | ventas todo-o-nada, descuentos y topes, crédito, anulación aprobada, doble aprobación |
| 029_cotizaciones_lecturas | cotizaciones, vistas de ventas y CxC, documento impreso, "seguir una venta" |
| 030_modulos_dependencias | dependencias entre módulos como datos, apagar sin romper (correcciones permitidas), cuentas controladas con el módulo apagado |
| 031_ventas_decisiones_dueno | una promoción por línea (se elige), nunca descuento sobre descuento, vendedor que cobra, ventas de servicios sin inventario |
| 032_limites_ficha_proveedor | límites del contrato, solicitudes al proveedor, `aplicar_ficha` / `vista_previa_ficha` |
| 033_cobros_saldo_favor | cobros a clientes (consolidados, excedente a saldo a favor), anular cobro, condonación, saldos iniciales de clientes, saldo a favor y vales, estado de cuenta, `id_operacion` como datos |
| 034_apartados | apartados con anticipo (reserva de existencias), formas de pago saldo a favor y anticipo en la venta |
| 035_devoluciones | devoluciones y notas de crédito (CAI o internas), cambio de producto, tope y aprobación |
| 036_comisiones | comisiones de vendedores: devengo al cobrar, ajustes, pago por período |
| 037_cierre_2b2b | claves nuevas de `configurar_empresa`, `MODULO_CON_SALDO` de los módulos nuevos, asistente (clientes con saldos), `estado_cuenta_cliente` |

Detalle de cada módulo: `nucleo/docs/` (dinero, caja, gastos y arranque en `dinero.md`, `caja.md`, `gastos.md`, `arranque.md`).

## Cómo correr las pruebas (un comando)

```bash
bash base-negocios/herramientas/probar.sh
```

Levanta un PostgreSQL 16 local en `base-negocios/.pgdata` (no se sube a git),
crea una base vacía, aplica todo y corre cada prueba en su propia copia.
Hay pruebas `.sql` (lógica de la base) y `.sh` (herramientas y dos
conexiones a la vez).
Muestra `OK` o `FALLA` por prueba y al final `RESULTADO: TODO OK`.
Si algo falla, termina con error (código distinto de 0).

## Reglas de oro

1. **Nada se borra ni se edita.** Un error se corrige con un contra-asiento
   (`anular_asiento`) que guarda motivo, usuario y fecha. Ni el
   administrador de la base puede borrar asientos ni la bitácora.
2. **Dinero en centavos enteros.** L 115.00 se guarda como `11500`.
   Nunca decimales para dinero. Las cantidades sí pueden tener fracciones.
3. **Todo o nada.** Si una parte de una operación falla, no se guarda nada.
4. **Cada operación lleva un `id_operacion` (uuid).** Si se manda dos veces
   (reintento o sin internet), se guarda una sola vez.
5. **Debe = Haber, siempre.** Lo revisa la función y además la base al confirmar.
6. **Mes cerrado no recibe asientos.** Reabrir exige permiso y motivo.
7. **Cada quien ve solo su empresa** (RLS) y solo hace lo que su rol permite.
8. **Licencia vencida = solo lectura.** Consultar y exportar nunca se bloquea.
9. **El proveedor instala y actualiza, pero no registra movimientos ni ve
   cifras.** Para soporte, el dueño le da un acceso temporal de solo lectura
   (con motivo y vencimiento, máximo 30 días); vence solo. Esto vale dentro
   de la app: con la llave `service_role` o la clave `postgres` técnicamente
   se lee todo, y eso se regula por contrato y bitácora (P-04).
10. **Las migraciones solo van hacia adelante.** Una migración ya aplicada no
    se edita: se crea otra con el número siguiente (`migrar.sh` lo vigila).
11. **Fechas:** la fecha contable (la que cuenta para los libros) es aparte
    de la hora de registro, que la pone el servidor. "Hoy" se calcula en la
    zona de la empresa (America/Tegucigalpa por defecto). La fecha contable va
    desde el inicio de la empresa hasta hoy + 3 días (configurable).
    Todo lo exportado va en ISO 8601 (`2026-01-31`, `2026-01-31T18:00:00Z`).
12. **Meses en orden.** Se cierran en orden y se reabren del último hacia atrás.
13. **Bitácora a prueba de manos.** Cada fila lleva una huella encadenada;
    `verificar_bitacora()` avisa si alguien la alteró por fuera.
14. **Kardex = contabilidad.** El valor del inventario es igual al saldo de
    la cuenta de inventario, y las CxP por proveedor al de proveedores. Esas
    cuentas no aceptan asientos manuales si su módulo está activo, y el
    módulo no se activa si ya tienen un saldo que no explica.
15. **Secretos fuera de la vista.** Las herramientas nunca pasan la clave de
    la base (ni la ficha del cliente) como argumento; los respaldos salen
    cifrados (P-03). "Base local de pruebas" es solo el socket de `.pgdata`
    (o `BASE_LOCAL_SOCKET`), nunca `localhost`.
16. **Rastro del dinero.** Cada lugar con dinero es una cuenta de dinero con
    su subcuenta; todo lo que entra o sale deja una fila (de dónde, a dónde,
    quién, equipo, referencia, turno). Su suma = la contabilidad; su
    subcuenta no acepta asientos manuales; ninguna queda en negativo.

## Funciones que usará la app (RPC)

| Función | Para qué | Permiso |
|---|---|---|
| `mi_perfil(empresa?)` | quién soy, rol, permisos, módulos, licencia (arma el menú) | con sesión |
| `registrar_asiento(empresa, fecha, descripcion, lineas, id_operacion, sucursal?)` | registrar un asiento | asientos.registrar |
| `anular_asiento(asiento, motivo, id_operacion?, fecha?)` | contra-asiento | asientos.anular |
| `cerrar_periodo(empresa, año, mes)` | cerrar mes (en orden) | periodos.cerrar |
| `reabrir_periodo(empresa, año, mes, motivo)` | reabrir el último mes cerrado | periodos.reabrir |
| `saldo_cuentas(empresa, desde, hasta)` | saldos y movimientos entre fechas | contabilidad.ver |
| `verificar_bitacora(empresa?)` | revisar que nadie alteró la bitácora | bitacora.ver |
| `cambiar_permiso_rol(empresa, rol, permiso, otorgar, motivo)` | editar permisos | permisos.editar |
| `agregar_usuario_empresa(empresa, correo, rol, nombre?)` | agregar / reactivar / cambiar rol | usuarios.administrar |
| `desactivar_usuario_empresa(empresa, user_id, motivo)` | desactivar (nunca borrar) | usuarios.administrar |
| `crear_sucursal(empresa, codigo, nombre)` / `desactivar_sucursal` / `reactivar_sucursal(empresa, sucursal, motivo)` | sucursales (no se desactiva con existencias) | sucursales.administrar |
| `crear_caja(empresa, sucursal, nombre, punto_emision)` / `desactivar_caja` / `reactivar_caja(empresa, caja, motivo)` | cajas | sucursales.administrar |
| `crear_subcuenta(empresa, codigo_madre, codigo, nombre, naturaleza?)` | subcuenta de detalle | catalogo.editar |
| `otorgar_acceso_soporte(empresa, vence_en, motivo)` / `revocar_acceso_soporte(empresa, motivo)` | soporte temporal | soporte.otorgar (solo dueño) |
| `configurar_empresa(empresa, datos, motivo)` | tope de crédito, inventario negativo, precio incluye ISV por defecto | empresa.configurar (solo dueño) |
| `crear_tercero` / `editar_tercero` / `desactivar_tercero` | clientes y proveedores | terceros.editar / .credito / .desactivar |
| `crear_unidad`, `crear_categoria`, `crear_campo_extra`, `crear_producto`, `editar_producto`, `desactivar_producto`, `reactivar_categoria`, `reactivar_campo_extra` | catálogo | productos.editar |
| `cambiar_precio_producto(empresa, producto, precio, motivo)` | precio con historial | productos.precios |
| `buscar_producto_por_codigo(empresa, codigo)` | escáner / cámara | miembro de la empresa |
| `crear_bodega` / `desactivar_bodega` / `reactivar_bodega` | bodegas | bodegas.administrar |
| `ajustar_inventario(empresa, bodega, fecha, lineas, motivo, id_operacion)` | conteo físico + asiento | inventario.ajustar |
| `trasladar_inventario(empresa, origen, destino, fecha, lineas, id_operacion, nota?)` | traslado entre bodegas | inventario.trasladar |
| `cargar_saldo_inicial(empresa, bodega, fecha, lineas, id_operacion, motivo?)` | apertura del inventario (contra Saldos de apertura) | inventario.carga_inicial |
| `anular_documento_inventario(documento, motivo, id_operacion, fecha?)` | anular carga inicial, ajuste o traslado | inventario.anular + el del tipo |
| `registrar_compra(empresa, datos, id_operacion)` | compra contado (acepta `cuenta_dinero_id`) / crédito | compras.registrar |
| `anular_compra(compra, motivo, id_operacion, fecha?)` | contra-movimiento + contra-asiento | compras.anular |
| `pagar_proveedor(empresa, documento, monto, fecha, forma_pago, id_operacion, referencia?, cuenta_pago?, cuenta_dinero_id?)` | abono a una compra o saldo inicial desde la caja o banco elegido (con rastro si es cuenta de dinero) | compras.pagar |
| `anular_pago_proveedor(pago, motivo, id_operacion, fecha?)` | contra-asiento a la misma cuenta de dinero | compras.anular |
| `registrar_saldo_inicial_cxp(empresa, datos, id_operacion)` / `anular_saldo_inicial_cxp(saldo, motivo, id_operacion, fecha?)` | facturas de proveedores pendientes al empezar | compras.saldo_inicial (solo dueño) |
| `precio_isv(precio, incluye_isv, impuesto, cantidad?)` | precio sin ISV, ISV y con ISV (regla única de redondeo) | con sesión |
| `crear_cuenta_dinero(empresa, datos)` / `editar_cuenta_dinero` / `desactivar_cuenta_dinero` / `reactivar_cuenta_dinero` | cajas, bancos, caja chica, POS, transferencias, tránsito (crea su subcuenta) | dinero.administrar |
| `trasladar_dinero(empresa, datos, id_operacion)` | depósito (en tránsito), retiro, reposición de caja chica, traslado | dinero.trasladar |
| `confirmar_deposito(operacion, id_operacion, fecha?, referencia?)` | el banco ya tiene el depósito | dinero.trasladar |
| `anular_operacion_dinero(operacion, motivo, id_operacion, fecha?)` | contra-asiento | dinero.anular |
| `registrar_saldo_inicial_dinero(empresa, datos, id_operacion)` | saldo de apertura de una cuenta de dinero | dinero.saldo_inicial (solo dueño) |
| `agregar_adjunto(empresa, documento_tipo, documento, comprobante)` | foto o PDF del comprobante (solo agregar) | adjuntos.agregar |
| `donde_esta_mi_dinero(empresa)` / `estado_cuenta_dinero(cuenta, desde, hasta)` | saldos por cuenta y tránsito / movimientos con origen o destino | dinero.ver |
| `abrir_turno(empresa, caja, fondo, id_operacion, datos?)` / `cerrar_turno(turno, contado, id_operacion, datos?)` / `mi_turno(empresa)` | turno de caja por cajero con arqueo | caja.turno |
| `resolver_diferencia(turno, destino, motivo, id_operacion, fecha?)` | faltante al cajero o a gasto; sobrante a otros ingresos | caja.supervisar |
| `crear_categoria_gasto` / `desactivar_categoria_gasto` / `reactivar_categoria_gasto` | categorías ligadas a cuentas de gasto | dinero.administrar |
| `registrar_gasto(empresa, datos, id_operacion)` / `anular_gasto(gasto, motivo, id_operacion, fecha?)` | gasto con ISV y comprobante (sobre el tope queda pendiente) | gastos.registrar / gastos.anular |
| `resolver_aprobacion(aprobacion, aprobar, motivo, id_operacion, fecha?)` | aprobar o rechazar (dentro del tope del puesto) | gastos.aprobar |
| `configurar_tope_rol(empresa, rol, tipo, sin_aprobacion, aprueba_hasta, motivo)` | topes por puesto | empresa.configurar (solo dueño) |
| `cuadre_caja_chica(cuenta, contado?)` | fondo, gastos con y sin comprobante, esperado | dinero.ver |
| `crear_pago_fijo` / `editar_pago_fijo` / `registrar_pago_fijo` / `pagos_fijos_proximos` / `reporte_pagos_fijos` | plantillas, próximos y vencidos, gasto real, total mensual | dinero.administrar / gastos.registrar / dinero.ver |
| `crear_empresa_inicial(ficha jsonb)` | instalar cliente | solo service_role |
| `vista_previa_ficha(empresa, cambios)` / `aplicar_ficha(empresa, cambios, motivo)` | módulos, perfil, licencia y límites del contrato (aplicar_ficha.sh) | solo service_role |
| `solicitar_al_proveedor(empresa, tipo, detalle, id_operacion)` | pedir ampliación, módulo u otra cosa | proveedor.solicitar (dueño, admin) |
| `responder_solicitud_proveedor(solicitud, estado, respuesta)` | atender o rechazar una solicitud | solo service_role |
| `promociones_aplicables(empresa, producto, fecha?, cantidad?)` | promociones que puede elegir quien vende | ventas.vender / ventas.cotizar |
| `registrar_cobro(empresa, datos, id_operacion)` / `anular_cobro(cobro, motivo, id_operacion, fecha?)` / `confirmar_transferencia_cobro` | cobros a clientes y su anulación (`nucleo/docs/cobros.md`) | ventas.cobrar / cobros.anular / dinero.trasladar |
| `condonar_saldo_cxc` / `anular_condonacion` | redondeo explícito con motivo | cobros.condonar / cobros.anular |
| `registrar_saldo_inicial_cxc` / `anular_saldo_inicial_cxc` | facturas que los clientes ya debían | ventas.saldo_inicial (solo dueño) |
| `consultar_vale(empresa, codigo)` / `estado_cuenta_cliente(empresa, cliente, desde?, hasta?)` | saldo de un vale / estado de cuenta | ventas.vender / ventas.ver |
| `registrar_devolucion(venta, datos, id_operacion)` / `documento_nota_credito(devolucion)` | devoluciones y notas de crédito (`devoluciones.md`) | ventas.devolver |
| `crear_apartado` / `abonar_apartado` / `completar_apartado` / `cancelar_apartado` | apartados con anticipo (`apartados.md`) | apartados.registrar / apartados.cancelar |
| `configurar_comisiones` / `fijar_porcentaje_comision` / `pagar_comisiones` / `anular_pago_comisiones` | comisiones (`comisiones.md`) | comisiones.configurar (dueño) / comisiones.pagar |

Vistas: `v_existencia` (inventario.ver; costos solo con inventario.costos),
`v_kardex` (inventario.costos), `v_cxp_documento` y `v_cxp_proveedor` (compras.ver),
`v_producto` (precio sin y con ISV), `v_cuenta_dinero`, `v_deposito_transito` (dinero.ver),
`v_turno_caja`, `v_diferencia_cajero` (dinero.ver o el propio cajero), `v_gasto`, `v_aprobacion`.
0.9.0: `v_cobro`, `v_cobros_por_caja`, `v_saldo_favor`, `v_apartado`, `v_devolucion`, `v_comision`,
`v_comision_vendedor` y `v_mis_comisiones` (cada vendedor las suyas, sin costos).
Detalle de cada módulo en `nucleo/docs/` (terceros, productos, inventario, compras, usuarios).

Formato de `lineas` (montos en centavos):
`[{"cuenta":"1.1.01.01","debe":11500},{"cuenta":"4.1.01.01","haber":10000},{"cuenta":"2.1.02.01","haber":1500}]`

## Errores

Todo error empieza con una CLAVE: `NO_CUADRA: el debe (100) no es igual...`.
La tabla `error_catalogo` tiene, para cada clave, el **mensaje sencillo**
para el usuario y **qué hacer**. La app toma lo que va antes de `:` y lo
busca ahí. Claves de hoy: `SIN_SESION`, `NO_PERTENECE`, `SIN_PERMISO`,
`LICENCIA_VENCIDA`, `MODULO_INACTIVO`, `PROHIBIDO`, `NO_PERMITIDO`,
`NO_EXISTE`, `YA_EXISTE`, `DATO_INVALIDO`, `FALTA_MOTIVO`,
`FALTA_DESCRIPCION`, `FALTA_ID_OPERACION`, `NO_CUADRA`, `LINEA_INVALIDA`,
`CUENTA_INVALIDA`, `YA_ANULADO`, `FECHA_INVALIDA`, `FECHA_ANTERIOR_AL_INICIO`,
`FECHA_MUY_FUTURA`, `PERIODO_CERRADO`, `PERIODO_INVALIDO`, `MES_NO_TERMINADO`,
`MES_ANTERIOR_ABIERTO`, `REABRIR_EN_ORDEN`, `SUCURSAL_INVALIDA`,
`SIN_SUCURSAL_ACTIVA`, `ULTIMA_SUCURSAL`, `ZONA_INVALIDA`, `FICHA_INVALIDA`,
`USUARIO_NO_EXISTE`, `VENCIMIENTO_INVALIDO`, `TOPE_CREDITO`, `RTN_INVALIDO`,
`TERCERO_INVALIDO`, `PRODUCTO_INVALIDO`, `CAMPO_EXTRA_INVALIDO`, `BODEGA_INVALIDA`,
`CANTIDAD_INVALIDA`, `EXISTENCIA_INSUFICIENTE`, `SALDO_INICIAL_YA_CARGADO`,
`CUENTA_CONTROLADA`, `PAGO_EXCEDE_SALDO`, `ID_OPERACION_USADO`,
`ENTRADA_FECHA_ATRASADA`, `MOVIMIENTOS_POSTERIORES`, `MODULO_CON_SALDO`,
`CUENTA_DINERO_INVALIDA`, `SALDO_INSUFICIENTE`, `TOPE_CAJA_CHICA`,
`MOVIMIENTO_SIN_RASTRO`, `MONEDA_NO_SOPORTADA`, `TURNO_YA_ABIERTO`,
`CAJA_OCUPADA`, `TURNO_CERRADO`, `FONDO_NO_CUADRA`, `SIN_TURNO_ABIERTO`,
`YA_RESUELTO`, `TOPE_APROBACION`, `COBRO_EXCEDE_SALDO`, `SALDO_FAVOR_INSUFICIENTE`,
`VALE_INVALIDO`, `VALE_VENCIDO`, `SALDO_FAVOR_USADO`, `EXISTENCIA_RESERVADA`,
`APROBACION_REQUERIDA`, `VENTA_CON_DEVOLUCIONES`, `DEVOLUCION_INVALIDA`,
`DEVOLUCION_NO_PERMITIDA`, `NADA_QUE_PAGAR`.

**Regla:** si una migración usa una clave nueva, la agrega a `error_catalogo`
en ese mismo archivo. La prueba 17 falla si alguna falta.

## Más documentos

- `docs/CONVENCIONES.md` — nombres, centavos, `_en`, permisos, migraciones.
- `docs/PERSONALIZAR.md` — qué se cambia por cliente sin programar y qué nunca.
- `docs/PROCEDIMIENTOS.md` — instalar, actualizar, respaldar/restaurar
  (cifrado), soporte, simulacro de restauración, activar módulos con saldos.
