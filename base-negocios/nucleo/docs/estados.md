# Estados por mes, selector y exportación (040_cierre_mes) — `contabilidad.ver`

Cada función recibe `(empresa, año, mes)`. **Mes cerrado** = se sirve la foto del cierre
(`fuente: "foto"`). **Mes abierto** = se calcula en vivo (`fuente: "en_vivo"`,
`preliminar: true` y la nota "PRELIMINAR"). Todas traen encabezado (empresa, RTN,
moneda), `desde`/`hasta`, `generado_en` (ISO UTC) y `lineas` para imprimir tal cual
(concepto, monto, tipo `titulo|detalle|subtotal|total`, nivel).

| Función | Qué devuelve |
|---|---|
| `estado_resultados` | ventas, devoluciones y descuentos, ventas netas, costo, utilidad bruta y margen %, gastos por categoría (cuenta 6.1), utilidad operativa, otros ingresos y gastos, utilidad neta; **utilidad cobrada**; comparativo |
| `balance_general` | activo y pasivo corriente / no corriente, patrimonio (más resultado del año y de años anteriores sin cierre anual), `cuadra`; comparativo |
| `flujo_efectivo` | método directo desde el rastro: saldo inicial, entradas y salidas por tipo, traslados internos aparte, saldo final; comparativo |
| `saldos_cuentas_mes` | cada cuenta: inicial, debe, haber, final (sumas iguales) |
| `cuentas_por_cobrar_mes` / `cuentas_por_pagar_mes` | por cliente / proveedor con antigüedad y vencido; documentos |
| `inventario_mes` | por producto y bodega (valores solo con `inventario.costos`) |
| `dinero_mes`, `isv_mes` | cuentas de dinero; ISV débito, crédito y a pagar |
| `exportar_mes` | TODO el paquete del mes en un JSON (`formato: exportacion_mes_v1`) |

**Comparativo** (resultados, balance, flujo): `mes_anterior` y `mismo_mes_anio_anterior`
(null si es antes del inicio de la empresa) con cada cifra, su variación en centavos y en %.

**Exportación:** la app arma el PDF y el Excel (el servidor no genera PDF). Montos en
centavos enteros, fechas ISO 8601, **sin emojis** (la prueba 120 lo revisa).

## Utilidad cobrada (decisión, base del reparto de utilidades)

utilidad cobrada = utilidad neta del mes − (utilidad por cobrar al final − al inicio).
Utilidad por cobrar de una factura al crédito = saldo × (base sin ISV − costo) / total
(nunca negativa). Los saldos iniciales de clientes no son ingreso del sistema y no cuentan.
Una venta al crédito no cobrada no aporta utilidad cobrada; cuando se cobra, su margen
entra en el mes del cobro. Una condonación resta solo el ISV que no se cobró.

Ejemplo (prueba 120, enero): neta 39,679; V_ENE_2 debe 25,000 de 45,000 con margen
38,136 − 30,000 = 8,136 → por cobrar 25,000 × 8,136 / 45,000 = 4,520; cobrada 35,159.

## ISV del mes

Débito = impuesto de ventas menos notas de crédito (cuentas por pagar de la tabla de
impuestos); crédito = compras y gastos con factura (1.1.04.01); a pagar = débito −
crédito (negativo = crédito a favor). Los asientos manuales sobre esas cuentas (pago a la
SAR) van aparte (`ajustes_manuales_*`). **A validar por un contador** (formato SAR).
