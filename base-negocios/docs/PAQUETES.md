# Paquetes sugeridos (guía de venta del proveedor)

Uso interno del proveedor. El programa no muestra paquetes ni precios: al
instalar se activan los módulos elegidos (ficha + perfil) y el precio va en el
contrato de servicio.

Cliente ideal: negocio pequeño o mediano que va empezando y tiene problemas
para controlar su dinero.

## Módulos de cada paquete (nombres reales para la ficha)

Lo que existe hoy (0.11.0). Lo demás de la lista de abajo llega en etapas
siguientes y se agregará aquí con su nombre de módulo. Dependencias en
`nucleo/docs/modulos.md` (compras necesita inventario; fiscal_hn y comisiones necesitan ventas; apartados necesita ventas e inventario; fondos y conciliacion necesitan dinero).

| Módulo (ficha) | Esencial | Completo | Nota |
|---|---|---|---|
| `contabilidad` | sí | sí | siempre |
| `ventas` | sí | sí | incluye cotizaciones, cobros y saldos iniciales de clientes, saldo a favor / vales, devoluciones y notas de crédito; sin inventario solo vende servicios |
| `inventario` | sí | sí | negocio de solo servicios: puede ir en `false` |
| `dinero` | sí | sí | cajas, bancos, caja chica, gastos, pagos fijos, turnos |
| `compras` | no | sí | necesita inventario |
| `fiscal_hn` (`"regimen_fiscal"`) | extra | extra | facturas y notas de crédito con CAI; necesita ventas |
| `apartados` | no (extra) | sí | apartados con anticipo; necesita ventas e inventario |
| `comisiones` | no (extra) | sí | comisiones de vendedores; necesita ventas |
| `fondos` | no (extra) | sí | fondos (reinversión, emergencias...), socios y reparto de la utilidad cobrada; necesita dinero |
| `conciliacion` | no (extra) | sí | conciliación bancaria con el estado de cuenta del banco (CSV); necesita dinero |

En todos los paquetes (sin módulo): alertas en un solo lugar y "Mi negocio hoy" (ganancia de hoy y del mes);
libros de ISV de ventas y compras cuando se usa `fiscal_hn`.

| Perfil y límites sugeridos (a confirmar con el dueño) | Esencial | Completo |
|---|---|---|
| `perfil` | `pequeno` (vendedor cobra, sin turnos obligatorios) | `mediano` |
| `limites.usuarios` | 3 a 5 | 10 a 15 |
| `limites.cajas` | 1 | 3 |
| `limites.sucursales` | 1 | 2 |
| `limites.bodegas` | 1 | 3 |

Los números de límites son una guía para el contrato; el proveedor los pone en
la ficha de cada cliente y los cambia con `aplicar_ficha.sh` (P-09, P-10).

Ejemplo "solo servicios" (salón, taller de mano de obra): `contabilidad`,
`ventas` y `dinero` en true; `inventario` y `compras` en false.

## Paquete esencial (negocio pequeño)

Objetivo: dejar de perder dinero y saber dónde está.

- 1 sucursal, 1 caja, pocos usuarios.
- Ventas de productos y servicios (contado y crédito).
- Inventario sencillo con código de barras.
- Clientes, créditos y cobros.
- Gastos y pagos fijos.
- Cajas, bancos y caja chica con rastro completo.
- "¿Dónde está mi dinero hoy?" y resumen del negocio.
- Cierre de mes con foto, selector de meses y estados descargables (en todos los paquetes: es parte de contabilidad).
- Proyección de flujo de caja a 30/60/90 días (parte de contabilidad).
- Excel de ida y vuelta. Uso en celular.
- Perfil sugerido: pequeño (contabilidad trabaja por dentro, sin turnos
  obligatorios).

## Paquete completo (negocio mediano)

Todo lo esencial, más:

- Varias cajas, turnos por cajero y arqueo. Más usuarios.
- Aprobaciones y doble aprobación.
- Comisiones de vendedores.
- Cotizaciones y apartados.
- Compras y cuentas por pagar completas.
- Fondos (reinversión, emergencias) y reparto de utilidades.
- Proyección de cobros y pagos.
- Conciliación bancaria y usuario contador.
- Varias bodegas y reportes avanzados.
- Perfil sugerido: mediano.

## Extras (para cualquier paquete)

- Facturación con CAI (régimen fiscal Honduras).
- Órdenes de trabajo (talleres, técnicos).
- Citas y agenda (salones, clínicas).
- Cobros recurrentes (gimnasios, academias, membresías).

## Plantillas por rubro (Armador)

`armador/plantillas/*.json` sugiere módulos, perfil, límites, categorías, palabras y demo de cada rubro
(el proveedor decide al final; el cuestionario de la visita ajusta la sugerencia):

| Rubro | Módulos sugeridos (además de contabilidad) | CAI | Paquete | Usuarios / cajas / sucursales / bodegas | Palabras |
|---|---|---|---|---|---|
| Ferretería | ventas, inventario, dinero, compras, apartados | sí | completo | 5 / 1 / 1 / 2 | (las de siempre) |
| Salón de belleza | ventas, inventario, dinero, comisiones | no | completo | 5 / 1 / 1 / 1 | "Cobrar servicios" |
| Taller mecánico | ventas, inventario, dinero, comisiones | sí | completo | 4 / 1 / 1 / 1 | "Órdenes de trabajo", "Repuestos" |
| Tienda / abarrotería | ventas, inventario, dinero | no | esencial | 3 / 1 / 1 / 1 | "Fiado (quién me debe)" |
| Restaurante / comedor | ventas, inventario, dinero, compras | sí | completo | 6 / 1 / 1 / 1 | "Comandas", "Menú e insumos" |

Las palabras solo cambian títulos del menú; nunca qué se ve. Mostrar la demo del rubro en la visita:
Armador > Demostración.

## Al cerrar una venta

1. Armar el cliente con el Armador (armador/LEEME.md), o llenar a mano la ficha
   (`clientes/<cliente>/ficha.json`, copia de `clientes/ejemplo/`) con los módulos, perfil, licencia y límites.
2. Instalar con herramientas/nuevo_cliente.sh (ver docs/PROCEDIMIENTOS.md P-01).
   Cambios después (agregar un módulo, ampliar límites, renovar licencia):
   herramientas/aplicar_ficha.sh (P-09, P-10).
3. Contrato de servicio: precio de instalación, mensualidad, qué incluye el
   soporte, usuarios incluidos, y que los datos son del cliente.
