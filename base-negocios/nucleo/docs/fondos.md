# Fondos, socios y reparto de utilidades (041_fondos) — módulo "fondos"

Necesita **dinero** (y por ella contabilidad). Lo activa el proveedor (ficha, `"fondos": true`).
Configurar y repartir: **solo el dueño** (`fondos.configurar`, `fondos.distribuir`,
`fondos.aprobar` no se pueden dar a otro puesto). Ver: dueño, admin y contador (`fondos.ver`).

## Socios — `guardar_socio(empresa, datos, motivo)`
`{"tercero_id"|"user_id", "nombre"?, "porcentaje", "activo"?}` (con `"socio_id"` edita
nombre, porcentaje o activo). La participación de los socios activos debe sumar 100 %
cuando se reparte por participación.

## Fondos — `crear_fondo` / `editar_fondo`
`{"nombre", "tipo": "reinversion"|"emergencias"|"otro", "meta_tipo": "ninguna"|"monto"|"meses_pagos_fijos",
"meta_monto_centavos", "meta_meses", "cuenta_dinero_id"?, "notas"?, "activo"?}`. Cada fondo
tiene SU reserva de patrimonio 3.2.02.NN (madre "Reservas de fondos" 3.2.02) que no acepta
asientos manuales. Meta "meses de pagos fijos" = meses × total mensual estimado de los
pagos fijos activos. Desactivado: no recibe repartos; lo que tiene se puede usar.

## Regla — `guardar_regla_distribucion(empresa, regla, motivo)`
`{"fondos":[{"fondo_id","porcentaje"}], "socios":[{"socio_id","porcentaje"}]}` o
`{"fondos":[...], "socios_porcentaje": 30}` (el 30 % según la participación). Todo suma
exactamente 100 % (`PORCENTAJES_INVALIDOS`).

## Repartir — `distribuir_utilidades(empresa, año, mes, datos, motivo, id_operacion)`
- Mes **cerrado con su foto** (`MES_ABIERTO`, `MES_SIN_CIERRE`); una vez por mes (`YA_DISTRIBUIDO`).
- Base = **utilidad COBRADA** del mes (de la foto; ver `estados.md`). Cero o negativa: no se
  reparte (`SIN_UTILIDAD_COBRADA`, el mensaje dice cobrada y facturada).
- `datos`: `{}` = regla guardada (`SIN_REGLA_DISTRIBUCION` si no hay) o los porcentajes;
  `"fecha"` (hoy por defecto, después del mes), `"separar_desde"` (cuenta de dinero).
- Montos por resto mayor (suman la base exacta). Asiento de patrimonio:
  Dr 3.3.01.02 Resultado del ejercicio / Cr reserva de cada fondo / Cr 2.1.01.03 Dividendos por pagar.
- Separación física (opcional): con `separar_desde`, cada fondo con `cuenta_dinero_id` recibe
  su parte con un traslado (otro asiento, con rastro).
- `anular_distribucion(distribucion, motivo, id_operacion, fecha?)`: contra-asientos (y el
  dinero separado vuelve). No si ya se pagaron dividendos de ese reparto o un fondo ya gastó
  lo recibido (`DISTRIBUCION_USADA`).

Ejemplo (prueba 121): base 35,159; reinversión 40 %, emergencias 30 %, socios 30 % (Dueño
60 %, Ana 40 %) → 14,063 / 10,548 / 6,329 / 4,219 (restos .70 y .62 reciben el centavo).

### Anular un reparto y reabrir el mes (pantalla en la app 0.10.0)

`anular_distribucion` ya existía (0.10.0). Reglas, probadas otra vez en la prueba 137:
- Solo el dueño (`fondos.distribuir`, no se da a otro puesto), con motivo (5 letras o más) e `id_operacion`
  (el mismo id devuelve la misma anulación con `duplicado`; otra vez con otro id: `YA_ANULADO`).
- **Nada se borra:** el reparto queda con `anulada_en`, motivo y su contra-asiento (`anula_asiento_id` =
  asiento del reparto); los fondos reciben un movimiento `anulacion_aporte` y vuelven a su saldo; el dinero
  separado vuelve a la cuenta de donde salió.
- **Si ya se pagó a un socio** de ese reparto: `DISTRIBUCION_USADA` ("anule primero esos pagos"). Se anula
  cada pago con `anular_pago_dividendos` (el dinero vuelve a su cuenta) y después el reparto. Si un fondo
  ya gastó lo recibido, tampoco (lo gastado no vuelve: se corrige con otro reparto).
- Después, el trigger `MES_CON_REPARTO` ya no bloquea: el mes se reabre con `reabrir_periodo` (en orden, del
  último cerrado hacia atrás), se corrige, se cierra otra vez (versión 2 de la foto) y se reparte de nuevo.

## Aportes de capital de los socios (0.16.0, migración 052)

Un socio mete dinero al negocio. **No es ganancia** (NIIF para PYMES: es patrimonio).

| | Debe | Haber |
|---|---|---|
| Aporte | cuenta de dinero que recibe (caja, caja chica o banco; con rastro) | 3.1.01.04 Aportes de socios |
| Anulación | 3.1.01.04 Aportes de socios | la MISMA cuenta de dinero |

**Decisión contable:** una sola cuenta nueva del sistema, 3.1.01.04 "Aportes de socios" (uso
`aportes_socios`, bajo 3.1.01 Capital social), y el detalle por socio en la tabla `socio_aporte` (como la
CxC por cliente). Así no se crea una cuenta por socio (el catálogo no crece con cada socio) y el cuadre es
simple: aportes vigentes = saldo de 3.1.01.04. La 3.1.01.02 "Aportes del dueño" de la plantilla se deja
para los asientos manuales que ya hubiera. La 3.1.01.04 la controla el módulo `fondos` (sin asientos
manuales, también apagado). Si el cliente ya usaba ese código, se crea en el siguiente libre
(`interno.cuenta_de`). Un contador puede reclasificar a capital social al formalizar (escritura).

- `registrar_aporte_socio(empresa, {"socio_id","monto_centavos","cuenta_dinero_id","fecha"?,"nota"?,"referencia"?,"equipo"?}, id_operacion)`:
  permiso nuevo **`fondos.aportes`** (dueño; el dueño se lo puede dar al admin; el contador no, porque mueve
  los libros), módulo `fondos`. Socio activo de la empresa; monto mayor que cero; la cuenta que recibe es
  caja, caja chica o banco de una sucursal del usuario (`SUCURSAL_NO_PERMITIDA`); el asiento lleva la
  sucursal de esa cuenta. Una caja de punto de venta solo en el turno propio (`TURNO_AJENO`,
  `SIN_TURNO_ABIERTO` si la empresa exige turnos); la caja chica no pasa su fondo fijo (`TOPE_CAJA_CHICA`).
  Reintento con el mismo id: el mismo aporte (`duplicado`).
- `anular_aporte_socio(aporte, motivo, id_operacion, fecha?)`: mismo permiso (también con el módulo
  apagado), motivo, fecha no anterior al aporte y mes abierto; contra-asiento a la misma cuenta. Si el
  dinero ya no está: `SALDO_INSUFICIENTE` (según la política de la cuenta). Una vez (`YA_ANULADO`).
- `aportes_socios(empresa, socio?)` (`fondos.ver`): por socio lo aportado (vigente), lo anulado y cuántos;
  la lista de aportes (más nuevos primero); `total_centavos`, `libros_centavos` y `cuadra`. Usuario
  limitado: solo aportes a cuentas de sus sucursales o de toda la empresa, sin el cuadre de libros.
  La tabla `socio_aporte` se lee con RLS (fondos.ver + sucursal de la cuenta).
- Dónde se ve: sube el saldo de la cuenta en `donde_esta_mi_dinero`; en el flujo de efectivo es una
  entrada "Aportes de capital de socios" (`interno.nombre_operacion`); el estado de resultados no cambia
  (prueba 138: ni un centavo).
- Pendiente (menor): activar `fondos` con saldo manual previo en 3.1.01.04 no da `MODULO_CON_SALDO`
  (la cuenta es nueva en 0.16.0; nadie debería tener asientos ahí).

## Usar un fondo — `usar_fondo(fondo, datos, motivo, id_operacion)`
`{"monto_centavos","cuenta_dinero_id","cuenta_destino","comprobante","fecha"?,"referencia"?}`;
el motivo dice para qué. Comprobante obligatorio. `cuenta_destino` = cuenta de detalle de
gasto, costo o activo (no efectivo ni cuentas de un módulo). Nunca más que el saldo
(`FONDO_INSUFICIENTE`). El dueño lo aplica al pedirlo; otro puesto con `fondos.usar` queda
**pendiente** (tipo `uso_fondo` en `aprobacion`) y lo aprueba el dueño con `resolver_aprobacion`.
Asiento: Dr destino / Cr cuenta de dinero (rastro) y Dr reserva / Cr 3.3.01.01 (se libera).

## Dividendos — `pagar_dividendos(empresa, {"socio_id","monto_centavos"?,"cuenta_dinero_id",...}, id)`
Sin monto paga todo lo pendiente; más que lo pendiente: `PAGO_EXCEDE_SALDO`.
`anular_pago_dividendos(pago, motivo, id, fecha?)` (también con el módulo apagado).

## Lecturas
`estado_fondos(empresa)`: por fondo saldo, aportes, usos, meta y % de meta, cuenta de
dinero y su saldo, libros; socios con dividendos pendientes; cuadre de dividendos.
Vistas `v_fondo_movimiento` (rastro con saldo corrido), `v_distribucion`, `v_dividendo_socio`.

Apagado: no se reparte, usa ni paga; se anula un reparto o un pago. La reserva y 2.1.01.03
siguen sin asientos manuales. Activar con saldo en 2.1.01.03 que no explica: `MODULO_CON_SALDO`.

## 0.16.0

`estado_fondos` a un usuario limitado a su sucursal: el saldo de la cuenta de dinero de un fondo que está en
otra sucursal llega en `null` (`solo_mis_sucursales: true`). Los fondos, socios y reservas se ven igual.
