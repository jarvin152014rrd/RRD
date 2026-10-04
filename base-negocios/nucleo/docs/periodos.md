# Períodos (004_periodos)

**Qué guarda:** estado de cada mes (abierto / cerrado). Un mes sin fila está abierto.

**Fecha contable válida:** desde `empresa.fecha_inicio` hasta
`hoy_local(empresa) + dias_futuro_max`. Fuera de eso:
`FECHA_ANTERIOR_AL_INICIO` o `FECHA_MUY_FUTURA`. Vale aunque se escriba a
la fuerza en la tabla.

**Cerrar** (`cerrar_periodo`, permiso `periodos.cerrar`):
- solo meses que ya terminaron (`MES_NO_TERMINADO`);
- en orden: si un mes anterior con movimientos sigue abierto, `MES_ANTERIOR_ABIERTO`;
- los meses anteriores sin movimientos se cierran solos (queda en bitácora).

**Reabrir** (`reabrir_periodo`, permiso `periodos.reabrir`, motivo obligatorio):
solo el último mes cerrado; para uno anterior, reabrir hacia atrás
(`REABRIR_EN_ORDEN`).

**Candado:** cerrar, reabrir, registrar y anular toman el mismo candado por
empresa (`bloquear_libros`), así no se cruzan.

**0.10.0:** el cierre completo es `cerrar_mes` (bloqueo + foto + advertencias, ver
`cierres.md`). `cerrar_periodo` sigue igual (solo bloquea). Al reabrir un mes, por
cualquier camino, su foto queda superada.
