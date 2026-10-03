# Régimen fiscal de Honduras: CAI (027_fiscal_hn) — módulo "fiscal_hn"

> Basado en el Régimen de Facturación de la SAR (Acuerdo 481-2017). **Un
> contador debe validar** el formato, los códigos de tipo de documento y las
> leyendas antes de usarlo con clientes reales.

## Aislado como régimen

- Lo fiscal de Honduras es el módulo **`fiscal_hn`** (lo activa el proveedor según el plan).
- El núcleo de ventas solo pide `interno.numero_fiscal(empresa, caja, tipo, fecha)`, que despacha al
  régimen activo (`interno.regimen_fiscal`: un módulo `fiscal_*`; a lo más uno activo). Otro país =
  otro módulo `fiscal_xx` que agrega su rama ahí y en `interno.bloque_fiscal` (documento impreso).
- **Sin régimen activo**, toda venta sale con ticket interno (T-001-001-00000001, correlativo propio de la caja).
- Con régimen: `empresa.documento_venta_modo` = `solo_factura` (defecto) | `factura_o_ticket` | `solo_ticket`.

## Rangos — `registrar_cai(empresa, datos)` (cai.administrar: dueño y admin)

```json
{"caja_id":"...","tipo_documento":"factura"|"nota_credito"|"nota_debito",
 "cai":"A1B2C3-D4E5F6-A7B8C9-D0E1F2-A3B4C5-D6",
 "rango_desde":"001-001-01-00000001","rango_hasta":"001-001-01-00005000",
 "fecha_limite_emision":"2026-12-31","ultimo_usado":"001-001-01-00000120"}
```
- Formato del número: establecimiento (sucursal) - punto de emisión (caja) - tipo - correlativo de 8.
  El establecimiento y el punto de emisión deben ser los de la caja.
- Rangos del mismo prefijo no se cruzan (ni desactivados: un número fiscal no se repite nunca).
  Un mismo código de tipo no se usa para dos tipos de documento.
- No se registra un CAI ya vencido. El rango no se edita: si está mal, `desactivar_cai` y se registra el correcto (`reactivar_cai`).

## Numeración (solo el servidor)

`interno.asignar_numero_fiscal`: toma el rango vigente más antiguo de **ESA caja** y tipo, lo
bloquea (dos cajeros a la vez esperan en fila: sin repetir ni saltar; una venta que falla no
consume número) y avanza el correlativo. Cada caja tiene su propio rango: en la etapa sin
internet cada caja numerará sola sin chocar con otra.
- Sin rango vigente: `SIN_CAI`; vencido: `CAI_VENCIDO`; agotado: `CAI_AGOTADO`.
- Un documento fiscal no lleva fecha futura ni anterior al último del rango (orden de fecha).
- La venta guarda `regimen_fiscal` y `datos_fiscales` (CAI, rango, fecha límite).

## Alertas — `cai_alertas(empresa)` y vista `v_cai_rango`

`por_vencer` (faltan `empresa.cai_dias_alerta` días o menos, defecto 30), `por_agotarse`
(usado ≥ `empresa.cai_porcentaje_alerta` %, defecto 80), `vencido`, `agotado` y `sin_cai` (caja
activa sin rango vigente). Los umbrales los cambia el dueño (`configurar_empresa`).

## Documento impreso (`documento_venta`)

RTN del emisor y del cliente, CAI, "rango autorizado desde ... al ...", fecha límite de emisión,
total en letras ("QUINCE LEMPIRAS CON 00/100") y leyendas: "La factura es beneficio de todos.
¡Exíjala!", "Original: Cliente. Copia: Obligado tributario emisor.", "Consumidor final" (sin RTN)
y la leyenda propia de la empresa (`leyenda_factura`). Una venta anulada sale "ANULADA" con su número.

Códigos de tipo de documento que usa la SAR (a confirmar por el contador; el sistema NO los
impone, toma el que trae el rango): 01 factura; las notas de crédito y débito según su resolución.
