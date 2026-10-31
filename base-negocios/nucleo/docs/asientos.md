# Asientos (005_asientos)

**Qué guarda:** asiento (cabecera) y sus líneas, en centavos.

**Registrar:** `registrar_asiento(empresa, fecha, descripcion, lineas, id_operacion, sucursal?)`.
Revisa: sesión, empresa, permiso, licencia, módulo, fecha válida, mes
abierto, sucursal activa, cuentas de detalle activas, montos enteros
positivos, debe = haber. Número correlativo sin huecos por empresa.
Si llega dos veces el mismo `id_operacion`, devuelve el mismo asiento.

**Anular:** `anular_asiento(asiento, motivo, id_operacion?, fecha?)` crea un
contra-asiento enlazado. La fecha no puede ser anterior a la del asiento
(`FECHA_INVALIDA`); por defecto es hoy, o la del asiento si este tiene fecha
futura. No se anula dos veces. Se puede anular aunque la sucursal o cuenta
se hayan desactivado. Los asientos de un módulo se anulan desde su documento.

**id_operacion:** solo se reconoce como reintento si es del mismo tipo
(asiento manual con asiento manual); si ya se usó en otra operación (una
compra, un pago...), `ID_OPERACION_USADO`.

**Sin sucursal indicada:** usa la primera sucursal activa; si no hay ninguna,
`SIN_SUCURSAL_ACTIVA`.

**Lectura:** vistas `v_asiento` (estado vigente/anulado/anulacion) y
`v_saldo_cuenta` (saldo total por cuenta). Para rangos de fechas ver reportes.
