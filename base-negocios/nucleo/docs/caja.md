# Turnos de caja por cajero (023_caja_turnos) — módulo "dinero"

**Reglas:** un cajero no tiene dos turnos abiertos; una caja no tiene dos
cajeros a la vez. La caja (punto de emisión) usa su cuenta de dinero de
efectivo; si no tiene, se crea al abrir el primer turno ("Efectivo <caja> (001-001)").

## Abrir — `abrir_turno(empresa, caja, fondo_centavos, id_operacion, datos?)` (caja.turno)

```json
{"conteo":[{"denominacion_centavos":10000,"cantidad":5}], "equipo":"Caja 1",
 "cuenta_origen_id":"<caja fuerte>", "nota":"..."}
```
- El fondo puede ir como monto, como conteo por denominación o los dos (deben coincidir).
- El fondo contado debe ser lo que la caja tiene en el sistema. Si no:
  `FONDO_NO_CUADRA`, o con `cuenta_origen_id` (pide dinero.trasladar) se trae
  o se lleva la diferencia desde esa cuenta en un traslado aparte (no cuenta
  como entrada del turno).
- `mi_turno(empresa)`: el turno abierto del usuario, **sin el esperado**
  (conteo a ciegas).

## Durante el turno

Todo lo que entra o sale de esa caja (traslados, depósitos, gastos, pagos y,
en 2b-2, cobros) queda marcado con el turno en el rastro del dinero.

## Turnos obligatorios o no (0.6.0, por empresa)

`empresa.turnos_obligatorios` (defecto `true`; lo cambia solo el dueño con
`configurar_empresa(..., '{"turnos_obligatorios": false}', motivo)` o con el
perfil "pequeno").

- **Obligatorios** (regla de siempre): sin turno abierto no entra efectivo
  (`SIN_TURNO_ABIERTO`).
- **No obligatorios** (negocios pequeños): el efectivo entra a la caja SIN
  turno (el rastro queda con `turno_id` vacío). Los turnos se pueden seguir
  usando igual. Si la caja tiene abierto el turno de OTRO cajero, no se cobra
  en ella sin turno (`CAJA_OCUPADA`), para no descuadrar su arqueo.

Para la etapa 2b-2 (cobros en efectivo): `interno.cuenta_efectivo_cobro(empresa, caja?)`
da la cuenta de dinero donde entra el efectivo: la del turno abierto del
usuario; sin turno, `SIN_TURNO_ABIERTO` si son obligatorios, o la cuenta de
efectivo de la caja indicada (o de la única caja activa; se crea si falta).
`interno.exigir_turno_abierto(empresa)` sigue igual cuando son obligatorios; si
no lo son, devuelve un turno vacío (id NULL) en vez de error.

## Efectivo de anulaciones y devoluciones (0.9.1, decisión del dueño)

Anular un cobro o una venta, devolver dinero de una devolución o el anticipo de un
apartado: el efectivo sale del **turno abierto de quien hace la operación, a su nombre**,
con referencia al turno donde había entrado (`dinero_movimiento.turno_origen_id`).
**Nadie saca dinero del turno de otro cajero** (`TURNO_AJENO`). Sin turno propio y con
turnos obligatorios: `SIN_TURNO_ABIERTO`. Una anulación pedida por un cajero cuyo turno
sigue abierto sale de ese turno al aprobarla. Un turno cerrado nunca se toca. Detalle y
ejemplo en `cobros.md` (prueba 107).

**Cuenta de salida elegida (0.9.2):** si la única caja tiene abierto el turno de otro cajero,
quien anula puede elegir otra cuenta para el efectivo: `anular_cobro(..., fecha?, cuenta_salida_id)`
y, al aprobar la anulación de una venta, `resolver_aprobacion(..., fecha?, cuenta_salida_id)`.
Vale la caja fuerte (cuenta de efectivo sin punto de emisión), un banco, la caja chica o la caja
de su propio turno; nunca la del turno de otro cajero (`TURNO_AJENO`). Devolver dinero de una
devolución y el anticipo de un apartado ya piden la cuenta (`"cuenta_dinero_id"`). Prueba 115.

## Cerrar — `cerrar_turno(turno, contado_centavos, id_operacion, datos?)`

(caja.turno; el turno de otro cajero pide caja.supervisar). `datos`: `conteo`, `nota`, `equipo`, `fecha`.
- **Esperado = fondo + entradas − salidas** del turno (= saldo de la caja en el sistema).
- **Diferencia = contado − esperado** (− falta, + sobra). La caja queda con lo
  contado y la diferencia queda **pendiente** en 1.1.02.04 Diferencias de caja
  por resolver (faltante al debe, sobrante al haber). Esa cuenta no acepta
  asientos manuales.

Ejemplo (prueba 63): fondo 50,000; entra 10,000; salen 20,000 (depósito) y
5,000 (gasto): esperado 35,000. Cuenta 34,000: faltan 1,000.

## Resolver — `resolver_diferencia(turno, destino, motivo, id_operacion, fecha?)` (caja.supervisar)

| Diferencia | destino | asiento |
|---|---|---|
| faltante | `cobrar_al_cajero` | Dr 1.1.02.05 CxC empleados / Cr 1.1.02.04 |
| faltante | `gasto` | Dr 6.1.02.11 Faltantes de caja / Cr 1.1.02.04 |
| sobrante | `otros_ingresos` | Dr 1.1.02.04 / Cr 4.2.01.03 Sobrantes de caja |

Con motivo, una sola vez. Nadie resuelve la diferencia de su propio turno
(salvo el dueño). Si la empresa ya usaba esos códigos, se usó el siguiente
libre (ver `interno.cuenta_de`).

## Lecturas

- `v_turno_caja`: cada turno (fondo, entradas, salidas, esperado, contado,
  diferencia, estado y resolución). dinero.ver ve todos; cada cajero ve los suyos.
- `v_diferencia_cajero`: por cajero: turnos, con diferencia, faltantes,
  sobrantes, pendiente, cobrado al cajero, enviado a gasto, a otros ingresos.

`desactivar_caja` no deja desactivar una caja con turno abierto.
Permisos por defecto: caja.turno = dueño, admin, cajero; caja.supervisar = dueño, admin.
