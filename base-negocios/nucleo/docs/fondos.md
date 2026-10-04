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
