# Cierre de mes con foto (040_cierre_mes) — parte de "contabilidad"

> Formatos según NIIF para PYMES. **Un contador hondureño debe validar la presentación**
> (estado de resultados, balance, flujo e ISV) antes de entregarlos a terceros.

## Cerrar — `cerrar_mes(empresa, año, mes, motivo?)` (`periodos.cerrar`: dueño y admin)

1. **Descuadre contable = NO cierra** (`DESCUADRE_CONTABLE`): el debe no es igual al haber
   hasta el fin del mes, un asiento no cuadra o el balance no cuadra. No se guarda nada.
2. Bloquea el mes con `cerrar_periodo` (igual que antes: en orden `MES_ANTERIOR_ABIERTO`,
   solo meses terminados `MES_NO_TERMINADO`; los meses vacíos de antes se cierran solos).
3. Guarda la **foto inmutable** (`cierre` + `cierre_detalle`), una sección por estado:
   `estado_resultados`, `balance_general`, `flujo_efectivo`, `saldos_cuentas`,
   `cuentas_por_cobrar` (por cliente con antigüedad 0-30/31-60/61-90/+90 y vencido),
   `cuentas_por_pagar`, `inventario` (por producto y bodega), `dinero` (cada cuenta:
   inicial, entradas, salidas, final), `saldo_favor` (saldos a favor / vales y anticipos),
   `comisiones` (por vendedor) e `isv` (débito, crédito, a pagar). Todo "a la fecha de fin
   del mes" aunque se cierre días después (una anulación cuenta en su fecha).
4. Devuelve las **advertencias** (no bloquean): `depositos_en_transito`, `turnos_abiertos`,
   `aprobaciones_pendientes`, `transferencias_por_confirmar`, `cuentas_en_negativo`,
   `alerta_cuadre` (diferencias de arqueo sin resolver; un módulo que no cuadra con su
   cuenta) y, con fondos, `reparto_version_anterior`.

Reintento seguro: si el mes ya está cerrado con su foto devuelve la misma (`ya_estaba`).
Un mes cerrado antes de 0.10.0 (o con `cerrar_periodo`) se puede pasar por `cerrar_mes`
para guardarle la foto sin abrirlo.

## Reabrir (sin cambios: `reabrir_periodo`, solo el dueño, motivo, en orden)

Al reabrir, la foto vigente queda **superada** (con quién, cuándo y el motivo); nunca se
borra. Al volver a cerrar se crea la **versión siguiente**. `historial_cierres(empresa,
año?, mes?)` lista las versiones; `ver_cierre(cierre)` muestra cualquiera completa.

Ejemplo (prueba 120): enero cerrado (v1) con un depósito en tránsito de 50,000 como
advertencia; febrero cerrado, reabierto ("Falta una factura"), se agrega un gasto de
1,000 y se cierra otra vez: v1 superada con utilidad 8,087 y v2 vigente con 7,087.
