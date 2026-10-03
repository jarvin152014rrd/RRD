# Catálogo de cuentas (003_catalogo_cuentas)

**Qué guarda:** catálogo NIIF para PYMES jerárquico (1 > 1.1 > 1.1.01 >
1.1.01.01). Cada empresa recibe una copia al instalarse.

**Reglas:** solo las cuentas de detalle (hojas) reciben movimientos. Tipo
por el primer dígito (1 activo ... 6 gasto). Naturaleza deudora/acreedora
(las cuentas "contra" la traen escrita). De una cuenta existente solo se
cambia el nombre o se desactiva; nunca se borra.

**Subcuentas:** `crear_subcuenta(empresa, codigo_madre, codigo, nombre, naturaleza?)`
(010). Van bajo una cuenta de agrupación, un nivel más abajo, y siempre son
de detalle. Permiso `catalogo.editar`.

**3.3.01.03 Saldos de apertura (0.4.0):** contrapartida de la carga inicial de
inventario y de los saldos iniciales de proveedores. Al terminar la apertura
debería quedar en 0 o con la diferencia que el contador reclasifica (a
capital o utilidades) con un asiento manual. Si una empresa ya usaba ese
código, se creó en el siguiente libre (3.3.01.04...).
