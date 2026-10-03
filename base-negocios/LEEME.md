# Base de Negocios — Núcleo

Base para programas de administración de negocios (Honduras, lempiras).
La app será una PWA (página web instalable) y los datos vivirán en Supabase
(PostgreSQL). **Toda la lógica de dinero corre en el servidor**, dentro de
funciones SQL que guardan todo o nada. El navegador solo muestra y llama
esas funciones.

Versión del núcleo: ver `VERSION_NUCLEO` (hoy 0.3.0, etapa 2a). Cambios: `CHANGELOG.md`.

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
│   └── ficha.ejemplo.json  ficha de ejemplo
├── app/                    aquí irá la PWA
├── respaldos/              respaldos de migrar.sh (NO se sube a git)
└── herramientas/
    ├── probar.sh           corre todas las pruebas
    ├── migrar.sh           respalda y aplica migraciones pendientes a una base
    ├── nuevo_cliente.sh    crea la empresa de un cliente desde su ficha
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

Detalle de cada módulo: `nucleo/docs/`.

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
   (con motivo y vencimiento, máximo 30 días); vence solo.
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
    cuentas no aceptan asientos manuales si su módulo está activo.

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
| `crear_sucursal(empresa, codigo, nombre)` / `desactivar_sucursal(empresa, sucursal, motivo)` | sucursales | sucursales.administrar |
| `crear_caja(empresa, sucursal, nombre, punto_emision)` / `desactivar_caja(empresa, caja, motivo)` | cajas | sucursales.administrar |
| `crear_subcuenta(empresa, codigo_madre, codigo, nombre, naturaleza?)` | subcuenta de detalle | catalogo.editar |
| `otorgar_acceso_soporte(empresa, vence_en, motivo)` / `revocar_acceso_soporte(empresa, motivo)` | soporte temporal | soporte.otorgar (solo dueño) |
| `configurar_empresa(empresa, datos, motivo)` | tope de crédito, inventario negativo | empresa.configurar (solo dueño) |
| `crear_tercero` / `editar_tercero` / `desactivar_tercero` | clientes y proveedores | terceros.editar / .credito / .desactivar |
| `crear_unidad`, `crear_categoria`, `crear_campo_extra`, `crear_producto`, `editar_producto`, `desactivar_producto` | catálogo | productos.editar |
| `cambiar_precio_producto(empresa, producto, precio, motivo)` | precio con historial | productos.precios |
| `buscar_producto_por_codigo(empresa, codigo)` | escáner / cámara | miembro de la empresa |
| `crear_bodega` / `desactivar_bodega` | bodegas | bodegas.administrar |
| `ajustar_inventario(empresa, bodega, fecha, lineas, motivo, id_operacion)` | conteo físico + asiento | inventario.ajustar |
| `trasladar_inventario(empresa, origen, destino, fecha, lineas, id_operacion, nota?)` | traslado entre bodegas | inventario.trasladar |
| `cargar_saldo_inicial(empresa, bodega, fecha, lineas, id_operacion, motivo?)` | apertura del inventario | inventario.carga_inicial |
| `registrar_compra(empresa, datos, id_operacion)` | compra contado / crédito | compras.registrar |
| `anular_compra(compra, motivo, id_operacion, fecha?)` | contra-movimiento + contra-asiento | compras.anular |
| `pagar_proveedor(empresa, compra, monto, fecha, forma_pago, id_operacion, referencia?, cuenta_pago?)` | abono a CxP desde la caja o banco elegido | compras.pagar |
| `crear_empresa_inicial(ficha jsonb)` | instalar cliente | solo service_role |

Vistas: `v_existencia` (inventario.ver; costos solo con inventario.costos),
`v_kardex` (inventario.costos), `v_cxp_documento` y `v_cxp_proveedor` (compras.ver).
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
`CUENTA_CONTROLADA`, `PAGO_EXCEDE_SALDO`.

**Regla:** si una migración usa una clave nueva, la agrega a `error_catalogo`
en ese mismo archivo. La prueba 17 falla si alguna falta.

## Más documentos

- `docs/CONVENCIONES.md` — nombres, centavos, `_en`, permisos, migraciones.
- `docs/PERSONALIZAR.md` — qué se cambia por cliente sin programar y qué nunca.
- `docs/PROCEDIMIENTOS.md` — instalar, actualizar, respaldar/restaurar, soporte.
