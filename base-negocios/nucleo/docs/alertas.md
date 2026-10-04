# Alertas y "Mi negocio hoy" (045_alertas_resumen)

## `alertas_activas(empresa)` — todas las alertas en una lista

Cualquier usuario de la empresa la puede llamar; **solo recibe lo que sus permisos le dejan ver**.
Cada alerta tiene la misma forma:

```json
{"tipo":"deposito_transito","gravedad":"media","titulo":"Depósito sin confirmar",
 "mensaje":"El depósito de L 1,000.00 a \"BAC cheques\" del 29/09/2026 lleva 5 días sin confirmarse.",
 "que_hacer":"Revise el estado de cuenta del banco...","enlace":"/dinero/depositos","datos":{...}}
```

Ordenadas de grave a leve (`alta`, `media`, `baja`). También trae `cantidad`, `altas` y
`ocultas_por_preferencia`.

| Tipo | Qué avisa | Quién la ve |
|---|---|---|
| `cai` | CAI vencido, por vencer, agotado, por agotarse, caja sin CAI | cai.administrar, ventas.ver o ventas.vender (con fiscal_hn) |
| `cierre_mes` | meses terminados sin cerrar (el mes pasado se da hasta el día 10) | periodos.cerrar |
| `cuenta_negativa` | cajas o bancos en negativo | dinero.ver |
| `deposito_transito` | depósitos con más de `dias_alerta_transito` días sin confirmar | dinero.ver |
| `diferencia_arqueo` | cierres de caja con diferencia sin resolver | caja.supervisar |
| `aprobaciones` | solicitudes pendientes (cuántas y de qué tipo) | aprobaciones.ver |
| `credito_vencido` | clientes con saldo vencido (alta si pasa de 30 días) | ventas.ver |
| `pago_fijo` | pagos fijos vencidos o que vencen en 7 días | dinero.ver |
| `stock_minimo` | productos con existencia igual o menor a su mínimo | inventario.ver |
| `conciliacion` | bancos sin conciliar el mes pasado | conciliacion.ver (módulo conciliacion) |
| `licencia` | licencia que vence en 15 días o menos, en gracia o vencida | proveedor.solicitar (dueño y admin) |
| `limite_contrato` | usuarios, cajas, sucursales o bodegas al 80 % o más | proveedor.solicitar |

El cajero (permisos por defecto) solo ve `cai` y `stock_minimo`: nada de dinero, bancos, créditos
ni costos. Cada alerta de un módulo apagado no sale.

## Preferencias por usuario

- `mis_preferencias_alertas(empresa)`: los tipos que el usuario puede ver, con `recibir` (por defecto sí).
- `guardar_preferencias_alertas(empresa, {"stock_minimo": false})`: cada usuario las suyas
  (tabla `alerta_preferencia`, no se borra; queda en la bitácora). Los tipos y sus nombres están
  en la tabla `alerta_tipo`.

## `resumen_hoy(empresa)` — "¿Cuánto gané hoy?"

Para el panel del dueño. Cada parte solo con su permiso (lo que no se puede ver va en `ocultos`):

| Parte | Qué trae | Permiso |
|---|---|---|
| `ventas_hoy` | total con ISV y cantidad de ventas de hoy; ayer y la diferencia (monto y %) | ventas.ver |
| `ventas_mes` | lo vendido en el mes; mes pasado completo y a la misma fecha | ventas.ver |
| `ganancia_hoy` | ventas sin ISV − costo de lo vendido; ayer y la diferencia | ventas.ver + inventario.costos |
| `ganancia_mes` | ganancia del mes (ventas − costo − gastos), bruta, gastos, cobrada; mes pasado completo y a la misma fecha | contabilidad.ver + inventario.costos |
| `dinero` | disponible (cajas, bancos, caja chica) y por confirmar (tránsito, POS, transferencias) | dinero.ver |
| `te_deben` | total, vencido y cuántos clientes | ventas.ver |
| `debes` | total a proveedores, vencido y cuántos | compras.ver |

Sin `inventario.costos` la ganancia llega en `null` y `costos_ocultos: true`. Trae una `frase`:
"Hoy vendiste L 30.00 y ganaste L 6.09. En el mes llevas L 37.45 de ganancia."

Ejemplo (prueba 126): hoy 2 tornillos = 3,000 (ganancia 609), ayer 1 galón = 45,000 (8,136), gasto
5,000: ganancia del mes 609 − 5,000 + 8,136 = 3,745 (si ayer es del mismo mes).

## Pendiente

- Enviar las alertas al celular (notificaciones) es de la etapa de pantallas.
- Meta de ventas del día (comparar contra una meta) y "movimientos fuera de horario".
