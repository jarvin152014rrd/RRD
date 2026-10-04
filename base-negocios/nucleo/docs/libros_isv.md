# Libros de ISV (044_libros_isv) — régimen fiscal de Honduras

> **Para validar con un contador hondureño** antes de presentarlos a la SAR: columnas, orden,
> cómo van las notas de crédito y las anulaciones, y los exonerados (constancia de exoneración).

## Funciones (`contabilidad.ver`: dueño, admin, contador)

- `libro_ventas(empresa, año, mes)`: facturas y tickets emitidos, notas de crédito y anulaciones.
- `libro_compras(empresa, año, mes)`: compras y gastos **con factura** (y sus anulaciones).
- `libros_isv(empresa, año, mes)`: los dos juntos e `isv_a_pagar_centavos` (ventas − compras;
  negativo = crédito a favor para el mes siguiente).

## Columnas (iguales en los dos libros)

Fecha, tipo, número de documento, CAI, RTN, nombre, gravado 15 %, gravado 18 %, gravado otra tasa,
exento, exonerado, ISV 15 %, ISV 18 %, ISV otra tasa, ISV total, total, estado, documento que corrige.
La respuesta trae `columnas` (clave y título en orden) y `filas` (objetos con esas claves): la app arma
el CSV o el Excel sin cálculos. Montos en centavos, fechas ISO.

## Reglas

- Cada documento va en el mes de **su asiento** (la misma fecha que usa la contabilidad).
- Emitido y anulado en el mismo mes: una fila en cero con estado `ANULADA` (conserva número y CAI).
- Anulado en un mes posterior: en ese mes una fila `anulacion` en negativo.
- Nota de crédito: en negativo, con la factura que corrige en `documento_referencia`.
- Gasto con factura: la tasa se reconoce por el ISV de la factura (10,000 de base con 1,800 de ISV = 18 %).
  Gasto sin factura: no va al libro.

## Cuadre (`cuadre`)

- Ventas: ISV del libro = débito fiscal de `isv_mes` y base del libro = ventas netas de los libros
  (cuentas 4.1, sin asientos manuales).
- Compras: ISV del libro = crédito fiscal de `isv_mes`.
- Los asientos manuales del contador sobre esas cuentas salen aparte (`ajustes_manuales_centavos`).

Ejemplo (prueba 125): enero con 15 %, 18 %, exento, una anulada el mismo mes, una nota de crédito y
una anulada en febrero: ISV de ventas 9,408 = débito; compras 73,800 = crédito; a pagar −64,392.

## Pendiente

- Las compras no guardan todavía el CAI de la factura del proveedor (columna vacía en compras; los
  gastos sí lo guardan).
- Formato oficial de la SAR (DMC / declaración mensual): confirmar con el contador.
