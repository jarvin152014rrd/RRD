# Arranque fácil (025_arranque_facil) — para negocios pequeños, medianos y grandes

**Idea:** que cualquier negocio empiece a dar seguimiento el primer día, sin
trabas. Cargar saldos iniciales NO es obligatorio para empezar; el programa
recuerda lo que falta, pero nunca bloquea.

## Perfiles por tamaño (datos, no código)

Viven en `interno.plantilla_perfil` (+ `_modulo` y `_tope`). Solo son el punto
de partida: después cada cosa se cambia sola (`configurar_empresa`,
`configurar_tope_rol`, `configurar_saldo_negativo`).

| | pequeno | mediano | grande |
|---|---|---|---|
| Turnos de caja obligatorios | no (el efectivo entra sin turno) | sí | sí |
| Contabilidad en el menú (`contabilidad_visible`) | no (los libros se llevan igual) | sí | sí |
| Doble aprobación (`doble_aprobacion`) | no | no | sí (se aplicará en 2b-2) |
| Tope del admin en gastos | L 5,000 | L 5,000 | L 5,000 |
| Módulos sugeridos | contabilidad, ventas, inventario, dinero | + compras | + compras |

- `perfiles_negocio()`: la lista con lo que trae cada uno (para elegir).
- `vista_previa_perfil(empresa, perfil)` (solo el dueño): qué cambiaría, SIN
  cambiar nada: `cambios` (campo, actual, nuevo), `topes`, `modulos`
  (`sugeridos`, `activos`, `faltan`, `activos_no_sugeridos`), `avisos` y `hay_cambios`.
- `aplicar_perfil(empresa, perfil, motivo)` (solo el dueño, `empresa.configurar`):
  aplica lo mismo que mostró la vista previa; queda en la bitácora con el
  motivo ("Perfil pequeno: ..."). Se puede aplicar otro cuando se quiera.
- **Nunca** borra datos y **nunca** activa ni desactiva módulos: activar un
  módulo pagado es del proveedor según el plan. Si el perfil sugiere un módulo
  que no está activo, la vista previa lo dice ("pídalo en Mi cuenta"); un
  módulo activo que el perfil no sugiere se queda activo (con o sin saldo).
- Al instalar: `"perfil": "pequeno"` en la ficha (`personal/ficha.schema.json`).
  Si la ficha no trae `"modulos"`, se activan los que sugiere el perfil (lo
  decide quien instala: el proveedor). Sin perfil, la empresa queda como siempre.

La app lee `perfil`, `turnos_obligatorios`, `contabilidad_visible` y
`doble_aprobacion` en `mi_perfil()->'empresa'`.

## Asistente de arranque

`estado_arranque(empresa)` (permiso `arranque.gestionar`: dueño y admin):

| # | paso | se marca "hecho" solo cuando... |
|---|---|---|
| 1 | `datos_negocio` | la empresa tiene RTN |
| 2 | `usuarios` | hay al menos un usuario activo además del dueño (y del proveedor) |
| 3 | `cuentas_dinero` | hay cajas o bancos y TODOS (activos, sin contar tránsito) tienen saldo inicial vigente o "empezar en cero" |
| 4 | `productos` | existe al menos un producto |
| 5 | `clientes` | existe al menos un cliente |
| 6 | `proveedores` | existe al menos un proveedor |
| 7 | `primera_venta` | (llega con el módulo de ventas, 2b-2; mientras tanto se salta) |

Devuelve `pasos` (orden, paso, título, estado `hecho`/`saltado`/`pendiente`,
detalle), `hechos`, `saltados`, `pendientes`, `porcentaje` (hechos de 7,
redondeado: 1=14, 2=29, 3=43, 4=57, 5=71, 6=86, 7=100), `terminado` (nada
pendiente), `cuentas_sin_saldo_inicial` y `cuentas_en_negativo`.

`marcar_paso_arranque(empresa, paso, 'saltado' | 'pendiente')`: saltar o volver
a pendiente (queda en la bitácora). "hecho" no se marca a mano: sale de los
datos y gana a "saltado". Una caja nueva (por ejemplo, la que se crea sola al
abrir el primer turno) vuelve a dejar el paso 3 pendiente hasta declararla.

## Saldo inicial de cajas y bancos (o empezar en cero)

- `registrar_saldo_inicial_dinero(empresa, datos, id_operacion)` (solo el
  dueño): contra 3.3.01.03 Saldos de apertura, **una vez por cuenta**; si
  estaba mal se anula con `anular_operacion_dinero` (motivo) y se carga otra vez.
- `empezar_cuenta_en_cero(empresa, cuenta)` (solo el dueño): deja constancia de
  que la cuenta empieza en L 0.00; no mueve dinero; una sola vez. Si después
  aparece dinero de antes, se registra su saldo inicial.

Ejemplo (prueba 75): banco con saldo inicial L 5,000.00 y gaveta "en cero" =
paso 3 hecho. Se anula el del banco (pendiente otra vez) y se carga L 4,500.00:
Saldos de apertura = 450,000 centavos.

## Valores iniciales aprobados por el dueño

- El admin registra y aprueba gastos hasta **L 5,000.00** (`interno.plantilla_tope_rol`; los demás puestos 0).
- Arqueo **a ciegas**: `mi_turno` nunca muestra el esperado.
- Solo la **moneda de la empresa** (`MONEDA_NO_SOPORTADA`); dólares más adelante.
