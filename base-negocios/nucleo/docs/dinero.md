# Dinero: cuentas, rastro, depósitos y traslados (022_dinero) — módulo "dinero"

**Idea:** cada lugar donde hay dinero es una **cuenta de dinero** con nombre, y
todo lo que entra o sale de ella deja su **rastro** (de dónde vino o a dónde
fue, quién, cuándo, desde qué equipo y con qué referencia). El rastro siempre
suma lo mismo que la contabilidad.

## Cuentas de dinero

Tipos: `efectivo_caja` (caja de un punto de emisión o caja general/fuerte),
`banco`, `caja_chica`, `pos_por_liquidar`, `transferencia_por_confirmar`,
`transito` (depósitos sin confirmar).

- `crear_cuenta_dinero(empresa, datos)` (dinero.administrar). Crea **su
  subcuenta** de detalle bajo 1.1.01 con el siguiente código libre (1.1.01.04,
  1.1.01.05...).
  ```json
  {"tipo":"banco","nombre":"BAC cheques","banco":"BAC Credomatic",
   "numero_cuenta":"7301-2345-6789","tipo_cuenta":"cheques","moneda":"HNL","sucursal_id":"..."}
  ```
  - Banco: solo se guardan los 4 últimos dígitos (`****6789`), nunca el número completo.
  - `efectivo_caja` con `"caja_id"` = efectivo de esa caja (para turnos); sin
    caja = caja general o caja fuerte.
  - `caja_chica` necesita `"fondo_fijo_centavos"` (el tope).
  - Moneda: por ahora solo la de la empresa (`MONEDA_NO_SOPORTADA`).
- `editar_cuenta_dinero(empresa, cuenta, datos, motivo)`: nombre (también el
  de la subcuenta), banco, número, tipo de cuenta, sucursal, fondo fijo (nunca
  menor que el saldo de la caja chica).
- `desactivar_cuenta_dinero` / `reactivar_cuenta_dinero (empresa, cuenta, motivo)`:
  solo en saldo 0, sin turno abierto ni depósitos en tránsito hacia ella. Su
  subcuenta se desactiva y reactiva con ella.
- La subcuenta de una cuenta de dinero **no acepta asientos manuales**
  (`CUENTA_CONTROLADA`), aunque el módulo esté apagado.

## El rastro (`dinero_movimiento`, solo agregar)

Una fila por cada línea de asiento que toca una cuenta de dinero: monto (+
entra, − sale), operación, documento, contrapartida (origen o destino),
turno de caja (si había uno abierto en esa caja), referencia, equipo
(`"equipo"` en los datos o la cabecera `x-equipo` de la app), usuario y hora
del servidor. Si un asiento toca una cuenta de dinero sin dejar su fila, **no
se guarda nada** (`MOVIMIENTO_SIN_RASTRO`). Por defecto ninguna cuenta queda
en negativo (`SALDO_INSUFICIENTE`; ver "Saldo negativo") y la caja chica no
pasa su fondo (`TOPE_CAJA_CHICA`).

## Saldo negativo por cuenta (0.6.0)

Cada cuenta de dinero tiene su política (`politica_saldo_negativo`):

| política | qué pasa |
|---|---|
| `no_permitir` (defecto) | una salida que la deja en negativo se rechaza (`SALDO_INSUFICIENTE`) |
| `permitir_con_alerta` | la salida pasa; mientras esté en negativo sale la alerta "Revise el saldo inicial..." |
| `sobregiro_hasta` | pasa hasta el límite (`sobregiro_limite_centavos`); más allá, `SALDO_INSUFICIENTE`; en negativo sale la alerta de sobregiro |

- `configurar_saldo_negativo(empresa, cuenta, politica, limite_centavos, motivo)`:
  **solo el dueño** (`empresa.configurar`), con motivo; queda en la bitácora.
  No se pasa a una política más estricta si la cuenta ya está por debajo de lo
  que permitiría (primero se registra la entrada o el saldo inicial que falta).
  El dinero en tránsito siempre es `no_permitir`.
- Solo se revisa la cuenta de la que SALE dinero: una entrada nunca se rechaza
  aunque la cuenta siga en negativo.
- El rastro (origen y destino) sigue siendo obligatorio siempre.
- Alertas: `donde_esta_mi_dinero` trae `alertas` (cuentas en negativo con su
  mensaje) y en cada cuenta `politica_saldo_negativo` y `alerta`;
  `v_cuenta_dinero` tiene `alerta_saldo_negativo`.

Ejemplo (prueba 72): Caja 1 en 0 con "permitir con alerta": gasto de 10,000 →
-10,000 y alerta; entra 4,000 → -6,000; saldo inicial de 20,000 → 14,000 y la
alerta se va. BAC 1,000,000 con sobregiro de 50,000: gasto 1,030,000 → -30,000;
otro de 30,000 se rechaza (-60,000); uno de 20,000 pasa (-50,000, justo el límite).

## Operaciones (una sola operación: sale de una y entra a otra)

`trasladar_dinero(empresa, datos, id_operacion)` (dinero.trasladar):
```json
{"tipo":"deposito","origen_id":"<caja>","destino_id":"<banco>","monto_centavos":250000,
 "fecha":"2026-01-10","referencia":"Boleta 99881","equipo":"PC oficina",
 "comprobante":{"ruta":"<empresa_id>/depositos/b99881.jpg","tipo":"image/jpeg","sha256":"..."}}
```
| tipo | de | a | asiento |
|---|---|---|---|
| `deposito` | caja de efectivo o caja chica | banco | Dr Depósitos en tránsito / Cr caja; queda **en tránsito** |
| `retiro` | banco | caja de efectivo o caja chica | Dr caja / Cr banco |
| `reposicion_caja_chica` | banco o caja de efectivo | caja chica | sin monto: repone fondo − saldo |
| `traslado` | cualquiera | cualquiera (no tránsito) | Dr destino / Cr origen |

- La cuenta de tránsito se crea sola la primera vez ("Depósitos en tránsito")
  o se indica con `"transito_id"`.
- `confirmar_deposito(operacion, id_operacion, fecha?, referencia?)`: el banco
  ya lo tiene (Dr banco / Cr tránsito). Una sola vez.
- Alerta: un depósito con más de `dias_alerta_transito` días sin confirmar
  (defecto 3; lo cambia el dueño con `configurar_empresa`) sale con `alerta = true`.
- `anular_operacion_dinero(operacion, motivo, id_operacion, fecha?)`
  (dinero.anular): contra-asiento; nunca deja una cuenta en negativo. Un
  depósito ya confirmado no se anula (el dinero ya está en el banco: se corrige
  con un retiro o traslado).
- `registrar_saldo_inicial_dinero(empresa, datos, id_operacion)` (dinero.saldo_inicial,
  solo dueño): una vez por cuenta; contra 3.3.01.03 Saldos de apertura o, con
  `"contrapartida":"1.1.01.01"`, pasando el saldo de una cuenta de efectivo
  SIN rastro (caja general, bancos de la plantilla). Se anula con
  `anular_operacion_dinero` (pide también dinero.saldo_inicial).
- `empezar_cuenta_en_cero(empresa, cuenta)` (dinero.saldo_inicial, 0.6.0): deja
  constancia de que la cuenta empieza en L 0.00 (no mueve dinero). Lo usa el
  asistente de arranque (ver `arranque.md`). Cargar saldos iniciales no es
  obligatorio para empezar.

Ejemplo (prueba 62): BAC 1,000,000 y caja fuerte 300,000. Depósito de 250,000:
caja fuerte 50,000, tránsito 250,000, BAC 1,000,000. Al confirmar: BAC
1,250,000 y tránsito 0.

## Comprobantes (`adjunto`, solo agregar)

`agregar_adjunto(empresa, documento_tipo, documento_id, comprobante)`
(adjuntos.agregar). La foto o PDF va a Supabase Storage en la carpeta de la
empresa (`<empresa_id>/...`); aquí se guarda la ruta, el tipo (jpeg, png,
webp, heic, pdf), la huella sha256 y quién lo subió. Documentos:
operacion_dinero, gasto, turno_caja, compra, pago_proveedor,
cxp_saldo_inicial, inventario_documento. Nunca se borra; el mismo archivo
(misma huella) no se repite. También van dentro de los datos de cada
operación como `"comprobante"`.

## Lecturas (dinero.ver)

- `donde_esta_mi_dinero(empresa)`: saldo de cada cuenta (activas y las
  desactivadas con saldo), totales por tipo, depósitos en tránsito (con días
  y alerta) y `otras_cuentas_efectivo_sin_rastro`: cuentas 1.1.01 que no son
  cuentas de dinero pero tienen saldo en los libros.
- `estado_cuenta_dinero(cuenta, desde, hasta)`: saldo inicial, cada movimiento
  (fecha, operación, de dónde o a dónde, referencia, usuario, equipo, turno,
  saldo corrido) y saldo final.
- Vistas `v_cuenta_dinero` (con saldo) y `v_deposito_transito`.

## Compras con cuenta de dinero

`registrar_compra` acepta `"cuenta_dinero_id"` en una compra de contado (la
forma de pago sale del tipo de cuenta) y `pagar_proveedor` tiene un último
parámetro opcional `p_cuenta_dinero_id` (la forma de pago puede ir en NULL).
También el código de la subcuenta (`cuenta_pago`) deja rastro. Las llamadas de
antes con "caja"/"banco" (1.1.01.01 / 1.1.01.03) siguen igual: esas cuentas de
la plantilla no tienen rastro (aparecen aparte en "dónde está mi dinero").

## Reintentos

Cada operación lleva `id_operacion`; un reintento del mismo tipo devuelve lo
mismo (`"duplicado": true`) y de otro tipo da `ID_OPERACION_USADO`.

Permisos por defecto: dueño todo; admin ve, administra, traslada y anula;
contador solo ve; cajero agrega comprobantes; vendedor nada.
