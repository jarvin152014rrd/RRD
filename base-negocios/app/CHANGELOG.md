# Cambios de la app

## app 0.10.0 (núcleo 0.16.0; también funciona con 0.15.0) — Cambio de producto, anular reparto y aportes de socios

- **Devoluciones: cambio de producto.** Nuevo destino "Cambiarlo por otro producto" (si el dueño lo permite): se busca
  el producto nuevo, el servidor calcula lo devuelto, el total nuevo y la diferencia (`calcular_cambio_previo`; la app
  no suma dinero). Si vale más, se cobra la diferencia (efectivo, tarjeta o transferencia); si vale menos, la
  diferencia se devuelve en dinero o queda como saldo a favor / vale, según lo que el dueño permite. Al terminar: el
  resumen y el comprobante de la venta nueva (sin emojis ni íconos; Imprimir y WhatsApp). Un mismo `id_operacion` en
  los reintentos. Si pasa el tope del puesto lo explica (un cambio no queda en espera).
- **Dinero > Fondos y socios:** "Repartos y pagos a socios" con **Anular reparto** (solo el dueño, con motivo) y
  **Anular pago** a un socio (si ya se le pagó, primero se anula ese pago: el núcleo lo exige y la pantalla lo
  explica). **Aportes de los socios:** "Registrar aporte de un socio" (socio, monto, caja o banco, fecha, nota y
  referencia; aclara que no es ganancia), la lista por socio y la anulación con motivo.
- **¿Dónde está mi dinero?:** "Entró de los socios este mes" (aportes vigentes del mes).
- **Cierre de mes:** el mes con reparto explica los 3 pasos para reabrirlo y lleva a Fondos y socios.
- Cuadrar con el banco nombra "Aporte de socio" en los movimientos.
- **Núcleo 0.15.0:** sin `aportes_socios` no se muestra la parte de aportes; el cambio de producto solo se ofrece con
  núcleo 0.16.0 (y si falta la lectura, lo explica sin romper). Anular reparto y pagos sí funcionan (existen desde 0.10.0).
- Pruebas: `probar_app.cjs` (cambio que vale menos con saldo a favor y comprobante sin emojis; que vale más con un corte
  de internet; núcleo viejo y celular), `probar_compras_dinero.cjs` (aporte con corte de internet, en ¿Dónde está mi
  dinero?, no cambia el estado de resultados, anular; núcleo viejo; el admin no ve las acciones del dueño),
  `probar_reportes.cjs` (anular pago y reparto en pantalla y después reabrir el mes). Cascarón `cascaron-0.10.0`.

## app 0.9.1 (núcleo 0.16.0; también funciona con 0.15.0) — Arreglos de la revisión

- Compras y Todos los gastos piden los totales solo con su permiso (`compras.ver` / `dinero.ver`); si el servidor
  responde `SIN_PERMISO` o `FECHA_INVALIDA`, suman las filas como antes sin romper la pantalla.
- Si "desde" es después de "hasta", la app avisa ("La fecha 'desde' va antes que 'hasta'.") y no pide nada.
- Prueba nueva en `probar_compras_dinero.cjs`. Cascarón `cascaron-0.9.1`.

## app 0.9.0 (núcleo 0.16.0; también funciona con 0.15.0) — Totales del servidor y sucursales

- **Totales que suma el servidor** (núcleo 0.16.0): Compras (`totales_compras`: comprado, lo que se debe y cuántas)
  y Todos los gastos (`totales_gastos`: gastado y en espera) ya no suman en el navegador: las cifras son de TODO el
  rango aunque la lista muestre las últimas 300. Lo más vendido en Reportes > Ventas e Inicio sale de
  `mas_vendido` y **ya resta las devoluciones** (lo dice en pantalla y en el Excel/impreso).
- **Usuario limitado a su sucursal** (núcleo 0.16.0, que ya filtra en el servidor): ve la Proyección (con el aviso
  "Solo sus sucursales"), lo que se le debe hoy a cada vendedor (solo ventas de sus sucursales) y lo más vendido en
  Inicio. La gráfica de 7 días sigue oculta (es de toda la empresa).
- **Núcleo viejo (0.15.0):** si una lectura nueva no existe (404 / `PGRST202`), la app usa el método de antes
  (`rpcSiExiste` en `api.js`; se vuelve a probar al cerrar sesión) y, para un limitado, oculta lo que antes ocultaba
  (`nucleoFiltraSucursal`, por `version_esquema`).
- Pruebas: `probar_app.cjs` (Inicio con devoluciones restadas, limitado con su lo más vendido, núcleo viejo),
  `probar_compras_dinero.cjs` (cifras de compras y gastos = base, núcleo viejo, proyección del limitado con núcleo
  nuevo y viejo), `probar_reportes.cjs` (lo más vendido = `mas_vendido` y a mano, núcleo viejo; deuda de comisiones
  del limitado). Cascarón `cascaron-0.9.0`.

## app 0.8.1 (núcleo 0.15.0, sin migraciones nuevas) — Arreglos de la revisión de Reportes y cierre

- **Empleados y comisiones:** a un usuario limitado a su sucursal ya no se le pide `v_comision_vendedor` (es de toda
  la empresa): sin la columna "Se le debe hoy" y sin vendedores sacados de esa vista. Aviso del tope de 1,000 también
  en los turnos (pantalla y Excel). Una persona sin ventas visibles sale igual si tiene diferencias de caja o
  anulaciones, con "—" en las columnas de ventas.
- **Cierre de mes:** el pre-cierre busca, como `cerrar_periodo`, el mes abierto MÁS VIEJO anterior con asientos y lo
  nombra ("Falta: cerrar agosto de 2026 primero"); los meses vacíos de en medio no cuentan.
- **Ventas:** el aviso del tope de 1,000 filas también cuenta las devoluciones.
- **Quién hizo qué:** si hay más páginas, el Excel y lo impreso dicen "Solo las primeras N filas; hay más con estos filtros".
- **Productos:** los campos extra numéricos usan `aNumero` (0 o más, coma solo de miles) y los enteros piden número
  entero; nunca se manda un valor vacío en silencio.
- **`aNumero`** ya no acepta una "L" delante ("l5" se rechaza, igual que `aCantidad`).
- **¿Gané o perdí?:** el mes en curso se compara con los MISMOS días del mes anterior (`saldo_cuentas`); la tabla
  comparada trae "Otros gastos" (y "Otros ingresos") cuando hay, así la tarjeta de Gastos cuadra con la tabla.
- **Inventario valorizado:** los totales salen de las mismas filas que se muestran; un producto en negativo va
  aparte con su aviso. "Sin ventas" mira solo salidas con origen venta.
- Pruebas: `probar_reportes.cjs` 18 (nuevas: empleado sin ventas y tope de turnos, mes viejo abierto con el
  intermedio vacío; ampliadas: mismos días, tarjeta de gastos, totales del valorizado, "l5", limitado sin deuda de
  comisiones, bitácora impresa con más páginas). Cascarón `cascaron-0.8.1`.

## app 0.8.0 (núcleo 0.15.0, sin migraciones nuevas) — Reportes y cierre de mes funcionando

### Parte 1: Reportes (solo mirar)
- **¿Gané o perdí?:** un mes (`estado_resultados`, con su comparativo) u otras fechas (`saldo_cuentas`, con la
  misma cuenta del núcleo, comparado con los mismos días de antes). Frase sencilla ("En octubre ganó L …, L … más
  que en septiembre"), cifras grandes en verde y rojo, gastos por categoría, ganancia cobrada y tabla comparada.
  Con la contabilidad visible: **Ver en formato contable (NIIF)** (estado de resultados y `balance_general`).
- **Ventas:** por día, semana o mes con gráfica, por forma de pago (`v_ventas_por_caja`), por vendedor
  (`v_ventas_por_vendedor`) y lo más vendido (`v_venta_linea`, hasta 1,000 líneas). Dice que es lo facturado y
  que NO resta devoluciones (las muestra aparte, de `v_devolucion`).
- **Inventario valorizado:** al costo (`v_existencia`) y a precio de venta sin ISV, por categoría y bodega, bajo
  el mínimo y sin ventas en 30/60/90 días (`v_kardex`).
- **Empleados y comisiones:** `vigilancia_empleados` (ventas, ganancia, descuentos, anulaciones, diferencias),
  comisiones del período y lo que se les debe (`v_comision`, `v_comision_vendedor`; solo sobre lo cobrado) y
  faltantes y sobrantes por turno (`v_turno_caja`). Cada parte sale solo con su permiso.
- **Quién hizo qué:** `bitacora_legible` con filtros por fecha, persona y tipo, de 100 en 100, con el motivo; y
  "Bitácora completa" o sus problemas (`verificar_bitacora`).
- **Descargar Excel** (SheetJS de `vendor/`, una hoja por parte, montos en lempiras) e **Imprimir** (hoja A4 con
  logo, texto y líneas; sin íconos, emojis ni colores; `js/reportes.js` + `imprimible.js`).
### Parte 2: Cierre de mes
- Lista de meses con chips (Abierto, En revisión, Cerrado; Con reparto, Sin reparto). Pre-cierre con las
  advertencias del núcleo (`exportar_mes`) como lista "Listo / Falta" con botón a la pantalla donde se arregla
  (caja, depósitos, pendientes, cuentas, cuadrar con el banco), si el mes terminó, si el anterior está cerrado y si
  los libros cuadran; resumen del mes. **Cerrar** (`cerrar_mes`) con confirmación clara; **Reabrir**
  (`reabrir_periodo`) solo el dueño, con motivo, en orden y nunca con reparto (lo explica). Después del cierre lleva
  a Dinero > Fondos y socios para repartir. **Libros de ISV** del mes (`libros_isv`) en pantalla y Excel.
- `cerrar_mes` y `reabrir_periodo` no reciben `id_operacion` en el núcleo: la app arma la operación una vez y la
  repite una sola vez con los mismos datos si se corta el internet (el núcleo reconoce el reintento: "ya_estaba").
  Probado: con un corte, un solo cierre.
- Menú: Inventario valorizado pide además `inventario.ver`; Cierre de mes, `contabilidad.ver` (lo exige el núcleo).
### Parte 3: comas
- `aNumero` y `aPorcentaje` en `formato.js`: porcentaje de impuestos, topes de descuento, mínimo del producto,
  campos extra numéricos, cantidades de Traslados y conteo físico rechazan "2,5" con "Use punto para los decimales".
### Pruebas y demo
- `app-pruebas/probar_reportes.cjs` (16; la corre `probar_app.sh`): cifras contra la base y a mano, permisos,
  celular, Excel, impresión, comas y el cierre (rechazo con reparto, reabrir con motivo, revisión, cerrar con corte).
  `probar_app.cjs`: lo impreso de los reportes sin emojis. Demo: comisiones (Juan 5 %, Ana 3 %), turno de Ana con
  faltante de L 50.00 y una venta anulada con motivo. Cascarón `cascaron-0.8.0`.

## app 0.7.1 (núcleo 0.15.0, sin migraciones nuevas) — Arreglos de la revisión de Compras y Dinero

- **Grave: la coma en los montos.** `aCentavos`, `aCosto` y `aCantidad` borraban todas las comas: "150,50" se
  guardaba como L 15,050.00 y "2,5" como 25. Ahora la coma solo vale como separador de miles en grupos de 3
  ("1,500", "1,234,567.89"); cualquier otra se rechaza. Vale en TODAS las pantallas que usan esas funciones
  (vender, caja, cobros, gastos, compras, cajas, reglas, productos…): debajo de cualquier campo de dinero sale
  "Use punto para los decimales, por ejemplo 150.50" y el formulario no guarda. El Excel no usa estas funciones.
- **Confirmación de compra:** dice el total claro (total, subtotal e ISV), ya no "unos L …".
- **Cuadrar con el banco, lectura del CSV:** una fila con otro número de columnas que los títulos se deja fuera y
  se dice su número de fila; la columna del monto se busca por su título exacto ("Fecha valor" ya no se toma como
  monto); fecha con hora; campos entre comillas con salto de línea; tope de 5,000 movimientos o 2 MB con aviso;
  cada movimiento numerado (y su fila del archivo); los de otro mes se quitan con aviso antes de enviar. Un
  reintento dice "ya estaba cargado" (nunca "undefined").
- **Compras y Todos los gastos:** si llegan 300 filas avisa que las cifras de arriba suman solo esas y que acorte
  las fechas (el núcleo no tiene una lectura de totales).
- **Al salir** los filtros de Compras, Gastos, Cuadrar con el banco y Proyección vuelven a los de siempre.
- **Todos los gastos:** el menú pide `gastos.registrar` o `dinero.ver`; la lista pide `dinero.ver`; "Registrar
  un gasto" pide los dos. Sin `dinero.ver` explica que falta el permiso de ver las cajas (antes decía, por error,
  "Primero guarde sus cajas").
- **Pagar a un proveedor:** la fecha mínima es la mayor entre la fecha de la factura y la de los libros.
- Pruebas: `probar_compras_dinero.cjs` 21 (nuevas: comas con 12 casos, CSV, tope de 300, filtros al salir, permiso
  de gastos, fecha mínima). Cascarón `cascaron-0.7.1`.

## app 0.7.0 (núcleo 0.15.0, sin migraciones nuevas) — Compras y Dinero funcionando

### Parte 1: Compras
- **Compras > Compras:** lista con su estado en chips (pagada, por pagar con su vencimiento, vencida, anulada) y
  filtros sencillos por fecha y proveedor; arriba cuánto compró en esas fechas y cuánto debe todavía.
  **Nueva compra:** proveedor, número de factura, fecha, bodega y los productos (se buscan como en Vender) con
  cantidad y costo por unidad sin ISV. El ISV lo calcula el núcleo con el impuesto de cada producto (en
  pantalla se ve un total aproximado; si la factura de papel trae otro ISV por redondeo, se puede escribir el de
  cada línea). **De contado** pide de qué caja o banco sale (con su saldo al lado); **al crédito** pone el
  vencimiento con el plazo del proveedor (se puede cambiar). Pide confirmación y después muestra subtotal, ISV y
  total que guardó el núcleo para cuadrarlos con el papel. Los productos entran al inventario con su costo
  (lo hace `registrar_compra`). **Detalle** con líneas, pagos y **Anular** con motivo (`anular_compra`: nada se
  borra; los productos salen y el dinero vuelve a su cuenta). Una compra con pagos vigentes pide anular antes
  los pagos (también desde el detalle, `anular_pago_proveedor`).
- **Compras > Proveedores:** lista con lo que se le debe a cada uno (rojo si hay vencido), crear y editar
  (`crear_tercero` / `editar_tercero`; el plazo pide `terceros.credito`), y la ficha con lo que se le debe
  factura por factura (con **Pagar**) y su historial de compras y pagos.
- **Compras > Pagar a proveedores:** cuentas por pagar con chips (vencida, por vencer en 7 días, al día), lo
  vencido primero y tres cifras (debo, vencido, vence en 7 días). **Pagar** total o parcial diciendo de qué caja
  o banco sale; avisa si es parcial y cuánto quedará; no deja pagar de más. Mensaje: "Pago de L 4,500.00 a
  Distribuidora X · sale de BAC cheques".
### Parte 2: Dinero (además de "¿Dónde está mi dinero?")
- **Todos los gastos:** lista de toda la empresa con filtros (fecha, categoría, caja o banco), cifras de lo
  gastado y lo que espera aprobación; **Registrar un gasto** desde cualquier caja o banco (con factura e ISV
  opcional, que separa el núcleo) y anular o cancelar con motivo. Si pasa el tope del puesto dice claro "en
  espera de aprobación · todavía no sale dinero" (lo decide `registrar_gasto`).
- **Depósitos y traslados:** **Mover dinero** (depositar al banco, retirar, pasar entre cuentas, reponer la caja
  chica) en una sola operación (`trasladar_dinero`); depósitos **en tránsito** con días y alerta, **Confirmar
  depósito** (`confirmar_deposito`) y anular con motivo (`anular_operacion_dinero`); últimos movimientos.
- **Pagos fijos:** lista con próxima fecha y chips (atrasado, vence pronto, al día) y lo que se va al mes;
  crear, editar (con motivo), desactivar y activar (`crear_pago_fijo` / `editar_pago_fijo`); **Pagar ahora** con
  el monto real y la cuenta (`registrar_pago_fijo`, respeta topes).
- **Fondos y socios** (módulo fondos): cada fondo con saldo, de dónde viene, en qué se usó, meta y en qué
  cuenta está; socios con lo que se les debe y **Pagar su parte** (`pagar_dividendos`); movimientos de los
  fondos; **Usar un fondo** (pide comprobante: sin almacenamiento configurado lo explica y no deja guardar);
  **Repartir la utilidad de un mes** cerrado y **Nuevo fondo** (solo el dueño).
- **Cuadrar con el banco** (módulo conciliación): elegir banco y mes, cargar el estado de cuenta (CSV del banco
  con coma, punto y coma o tabulador, débito/crédito o monto; o escrito a mano), ver programa, banco y diferencia
  con la fórmula explicada, **marcar como el mismo movimiento**, crear comisión o intereses del banco, deshacer
  y **cerrar el mes**. Si el mes ya está cerrado en los libros, lo creado va con fecha de hoy y se dice.
- **Proyección:** 30, 60 o 90 días por semana (`proyeccion_flujo`): disponible hoy, saldo al final, gráfica de
  barras (rojo si una semana queda en negativo), tabla por semana, detalle de lo que entra y sale, cobros vencidos
  aparte y la fórmula en una línea. A un usuario limitado a su sucursal no se le muestra (es de toda la empresa).
- Menú: Depósitos, Pagos fijos y Cuadrar con el banco piden además `dinero.ver` (sin él no podrían leer las cuentas).

- Cada formulario manda un `id_operacion` fijo: un doble envío o un reintento sin internet no duplica (probado).
- **Arreglo:** "Editar cliente" no guardaba (la app mandaba un `id_operacion` que `editar_tercero` no recibe).
- **Arreglo:** al salir se borran las listas guardadas en memoria (productos, cuentas…): quien entre después
  en el mismo equipo ya no ve por un minuto las del anterior.
- Piezas nuevas: `js/formularios.js` (cuentas con saldo, monto, fecha, dato, cifra chica) y en `formato.js`
  `aCosto`, `aCantidad`, `sumarDias`, `diasEntre`; más estados en `chipEstado`.
- Demo: módulos de fondos y conciliación, dos pagos fijos, dos fondos y dos socios con el reparto del mes pasado
  (mes cerrado), una compra de contado y una venta de taladros y el estado de cuenta del BAC del mes pasado.
- Pruebas nuevas en `app-pruebas/probar_compras_dinero.cjs` (17; las corre `probar_app.sh`). Cascarón `cascaron-0.7.0`.

## app 0.6.1 (núcleo 0.15.0, sin migraciones nuevas) — Arreglos de la revisión de la ronda 2

- **Contraste automático siempre AA:** el texto oscuro ahora es negro (#000000); con colores "del medio"
  (#ff0000, #808080) el #1a1a1a no llegaba a 4.5. Si aun así ninguno llegara, el fondo se oscurece o aclara
  hasta que llegue (`fondoLegible`).
- **Foco:** usa el acento solo si tiene contraste 3 o más sobre blanco (antes 2); si no, el azul de la marca.
  Por eso el foco de siempre pasa a azul marino fuera del encabezado. **Íconos de los títulos:** el acento
  oscurecido hasta 3 o más sobre blanco (`--color-acento-icono`).
- **Doble aprobación:** si el servidor responde `falta_segunda_aprobacion`, el aviso dice "Primera aprobación
  lista; falta la segunda" (en Pendientes y en Inicio).
- **Cobro de un usuario limitado a su sucursal:** "Todavía debe en su sucursal" = lo que debía en su sucursal
  menos lo aplicado (antes salía el saldo de toda la empresa).
- **Tablas en el celular accesibles:** `role` table/row/cell/columnheader y el encabezado escondido solo a la
  vista. Impuestos: columna "Acciones" y "Cambiar <nombre>". Los botones repetidos en filas dicen de qué son
  para el lector de pantalla (Ver, Cobrar, Devolver, Desactivar, Aprobar...).
- **Tabla de permisos:** cada casilla dentro de un área de 44 px.
- **Emojis:** también se quitan las etiquetas de banderas de regiones (U+E0020 a U+E007F).
- **Gasto y depósito:** el mensaje usa el monto que devuelve el servidor y el nombre de la cuenta del dato.
- **Entrar en un equipo nuevo:** `armar_app.sh` pone en `config.js` solo el nombre del negocio (de la ficha,
  validado) como `nombreNegocio`; la pantalla de entrar lo usa si el equipo no tiene marca guardada.
- Pruebas: `probar_app.cjs` 43 (nueva: doble aprobación, casillas de 44 px, nombre en config.js; ampliadas:
  contraste con #ff0000, #808080, #f5e663 y #0b0b2e, roles de la tabla, bandera de región). Cascarón `cascaron-0.6.1`.

## app 0.6.0 (núcleo 0.15.0, sin migraciones nuevas) — Rediseño, ronda 2: todas las pantallas, la marca y lo impreso

- **El estilo de Inicio en todas las pantallas:** títulos con ícono dorado; montos en verde (entra dinero) y
  rojo (sale o falta); chips de estado (pagada, pendiente, vencida, anulada, en espera de aprobación); listas
  con burbuja de ícono y los botones en su propia línea. Piezas nuevas en `js/ui.js`: `titulo`, `chipEstado`,
  `monto`, `tabla`, `cabezaPantalla`; `estadoVacio` acepta varios botones.
- **Pantallas vacías que enseñan** (productos, clientes, ventas del día, cotizaciones, existencias, conteo,
  traslados, cajas y bancos, caja chica, depósitos, quién me debe), con botón solo si la persona puede usarlo.
- **Mensajes claros después de cada acción**, con ícono verde (o rojo si hay un problema, como un faltante) y
  los datos que devuelve el servidor: venta, cotización, devolución, gasto, depósito o retiro, abrir y cerrar
  turno, cobro, cliente, producto y precio, conteo, traslado, Excel, cajas, impuestos, reglas, usuarios.
- **Tablas como tarjetas en el celular** (< 700 px) con una sola solución: `ui.tabla` + CSS (existencias,
  movimientos, vista previa del Excel, impuestos, topes y permisos).
- **Entrar** cálida: banda con el color del negocio, logo (o iniciales) y nombre grandes, sin textos técnicos.
- **Alertas que recibo** ya funciona (`mis_preferencias_alertas` / `guardar_preferencias_alertas`, del núcleo).
- **Subpestañas de Inicio y Pendientes al lado del título** en computadora (como el dibujo); arriba en el celular.
- **Marca del cliente:** logo de 44 px (o iniciales en burbuja de acento) en el encabezado y en entrar; la
  marca solo cambia el principal y el acento; **contraste automático AA** (texto blanco u oscuro; el principal
  usado como letra se oscurece si hace falta); ya no se rechaza un color claro. **Vista previa en vivo** del
  encabezado real en Ajustes > Mi negocio. La barra del navegador del celular toma el color del negocio.
- **Lo impreso** (comprobante, WhatsApp de la venta y del cobro, título de la hoja al imprimir): sin íconos,
  sin emojis (aunque el negocio, los productos o las palabras del rubro los traigan; nuevo `js/imprimible.js`)
  y en negro. Sin cambios visuales nuevos.
- **Arreglo:** ya no sale el texto "null" en Mi cuenta (dueño), Excel (sin permiso de copia), Mi negocio
  (admin) y Traslados (sin mercadería en camino).
- Pruebas: `probar_app.cjs` 42 (nuevas: subpestañas y tablas como tarjetas, estado vacío, alertas que recibo,
  contraste de la marca con #f5e663 y #0b0b2e y vista previa, lo impreso con emojis, ninguna pantalla con
  emojis ni "null" en computadora y celular con capturas de todas). Cascarón `cascaron-0.6.0`.

## app 0.5.1 (núcleo 0.15.0, sin migraciones nuevas) — Arreglos de la revisión de la ronda 1

- **Usuario limitado a su sucursal:** en Inicio la tarjeta de dinero usa `resumen_hoy` (ya filtrado) y dice
  "Dinero disponible en mis sucursales"; el monto y su chip salen de la misma lectura. En Dinero > ¿Dónde está mi
  dinero? solo ve las cuentas de sus sucursales y las de toda la empresa, con un aviso y el total de lo que ve.
- **"Hoy" es la fecha del servidor** en cada carga de Inicio (`resumen_hoy` → `fecha`) y se refresca en el
  perfil: una app abierta toda la noche ya no se queda en el día anterior.
- **"Descargar todo" vuelve a estar en Mi cuenta** cuando la persona no ve "Excel y copia de mis datos" (mismos
  permisos que antes: `empresa.configurar` o `usuarios.administrar`).
- **Próximo pago** pide solo lo que vence de hoy en adelante (máximo 20) y, para usuarios limitados a sucursal,
  no toma los saldos iniciales sin sucursal. La gráfica y "lo más vendido" piden solo los últimos días.
  `api.leer` acepta filtros "desde/hasta" (`{ col: { gte } }`, `{ col: { lte } }`); el emulador también.
- "Me deben" solo con el módulo de ventas y "Debo a proveedores" solo con el de compras.
- **Aprobar/Rechazar solo para quien puede:** cada tipo pide su permiso (gasto: `gastos.aprobar`; venta,
  descuento, crédito y devolución: `ventas.aprobar`; anular venta: `ventas.anular`; uso de fondo:
  `fondos.aprobar`; conteo: `inventario.ajustar`). Los demás (p. ej. el contador) ven "Espera aprobación…".
- Lo más vendido: aviso "sin restar devoluciones" y plural correcto ("1 vendido", "13 vendidos", "8.5 unidades").
- Pruebas: `probar_app.cjs` 36 (nueva: usuario limitado a sucursal; ampliadas: fecha del servidor, filtro desde,
  copia en Mi cuenta, aprobación sin permiso, plural). Cascarón `cascaron-0.5.1`.

## app 0.5.0 (núcleo 0.15.0, sin migraciones nuevas) — Rediseño, ronda 1: base visual e Inicio

- **Íconos propios** (`js/iconos.js`): 68 dibujos de línea dentro de la app (funcionan sin internet). Cada
  pestaña y subpestaña del menú tiene el suyo (también en la barra del celular, en "Más" y en la vista previa del
  Armador). Nada impreso lleva íconos ni emojis (el comprobante sigue igual).
- **Colores con significado fijo** (`css/tema.css`): verde = entra dinero / todo bien; rojo = sale dinero /
  problema; dorado = importante / hoy; azul = información. Con su fondo suave para burbujas y chips.
- **Piezas nuevas en `js/ui.js`:** tarjeta de cifra, botón grande de acción, chip de color, fila con burbuja de
  ícono, gráfica de barras sencilla, estado vacío y mensaje con ícono. Los avisos y errores ahora llevan ícono.
  Letra base de 16 px y tarjetas más aireadas.
- **Menú reordenado** ("cada pestaña responde una pregunta"):
  - Inicio: Mi negocio hoy y **Pendientes** (une Alertas y Aprobaciones, con su número).
  - Caja: Mi turno, Cobrar, Gasto pagado de esta caja, Meter o sacar efectivo, Cajas abiertas.
  - Dinero: ¿Dónde está mi dinero? (la tabla que antes estaba en Inicio), Todos los gastos, Depósitos y
    traslados, Pagos fijos, Fondos y socios, Cuadrar con el banco y Proyección (nueva, en construcción).
  - Reportes: ¿Gané o perdí?, Ventas, Inventario valorizado, Empleados y comisiones, Quién hizo qué, Cierre de mes.
  - Ajustes: el Excel se movió aquí como **"Excel y copia de mis datos"** (también trae "Descargar todo");
    "Mis datos" ahora es **"Mi cuenta"** y trae "Alertas que recibo" (en construcción).
  - Productos tiene botón directo **"Subir Excel"**.
  - Barra del celular: Inicio, Vender, Caja, Productos y Más.
  - Las rutas viejas siguen sirviendo y llevan a la nueva (`#/inicio/alertas`, `#/inicio/aprobaciones`,
    `#/inventario/excel`, `#/ajustes/mis-alertas`, `#/buscar`). Las palabras del rubro guardadas con la ruta
    vieja también (`barra/resumen` → Inicio, `barra/buscar` → Productos).
- **Inicio nuevo:** saludo según la hora del negocio, fecha y estado de su caja; botones Vender, Cobrar a un
  cliente, Registrar un gasto y Abrir/Cerrar mi caja (solo los que puede usar); cifras Vendí hoy (contra ayer),
  Hay en caja ahora, Me deben y Debo a proveedores (con el próximo pago); gráfica de ventas de 7 días con Hoy en
  dorado; lo más vendido de la semana (burbuja lista para la foto del producto); **Primeros pasos** (dueño y
  admin, se deduce de los datos y desaparece al terminar); Pendientes con Aprobar/Rechazar; número en la campanita.
  Todo sale de lecturas que ya existían en el núcleo: no se tocó el núcleo.
- Las pantallas en construcción ahora se ven con un estado vacío amable y botón "Volver a Inicio".
- Pruebas: `probar_app.cjs` 35 (nuevas: Inicio con sus partes, íconos en todo el menú, rutas viejas, cajero en
  Inicio, comprobante sin íconos); `probar_armador.cjs` revisa los íconos de la vista previa. Cascarón `cascaron-0.5.0`.

## app 0.4.0 (núcleo 0.15.0: migración nueva 051)

- **Supabase real:** `config.js` con `modo: 'supabase'` usa la Edge Function `cerrar-sesion-remota` para "Cerrar
  sesión" de un usuario (además de cerrarla en la base, borra sus sesiones de Supabase Auth). "Agregar usuario"
  avisa si el correo ya tenía cuenta ("entra con la clave que ya usaba"). En la demo, todo igual.
- `herramientas/armar_app.sh <cliente> <URL> <anon key>` → `dist/app-<cliente>/` para Netlify, con `config.js`
  y `_headers` (CSP, nosniff, sin marcos, `sw.js`/`config.js` sin caché). Rechaza llaves secretas.
- El emulador (`servidor_app.js`) imita además `/auth/v1/user` y `/auth/v1/admin/users` SOLO con `SERVICE_KEY`
  (pruebas de las Edge Functions); sin esa variable, la demo no cambia.
- Pruebas nuevas: `app-pruebas/probar_funciones.mjs` (10: Edge Functions reales y app para Netlify sin errores
  de CSP). Cascarón `cascaron-0.4.0`.

## app 0.3.1 (núcleo 0.14.0, sin migraciones nuevas)

- **Palabras del rubro:** el menú se lee de `js/menu_datos.js` (datos puros que también usa la vista previa del
  Armador) y toma los títulos de `config.palabras` del cliente (ej. taller: "Órdenes de trabajo", "Nueva orden de
  trabajo"; también el título de la página y el botón del celular). Solo cambian títulos, nunca qué se ve; sin
  palabras queda igual que antes. `servidor_app.js` las lee de `CONFIG_CLIENTE` (app.json del Armador).
  Prueba nueva en `probar_app.cjs` (31). Cascarón `cascaron-0.3.1`.

## app 0.3.0 (núcleo 0.14.0: migración nueva 050)

- **Arreglos:** el resumen de la venta muestra todo con ISV como lo ve el cliente: Subtotal − Descuento = Total y
  debajo "ISV 15 % incluido" (promo de L 60 se ve L 60.00, no L 52.17; lo calcula el servidor). Los avisos de abajo
  duran unos segundos y se limpian al cambiar de pantalla o de estado (el "Turno abierto…" ya no queda tras cerrar).
- **El cajero cobra abonos** (decisión del dueño): Caja > Cobrar a clientes y la ficha del cliente usan
  `cxc_para_cobrar` (permiso nuevo `cobros.ver_saldos`): ve lo que debe cada cliente factura por factura, sin
  ventas de toda la empresa, costos ni ganancias. Restringido por sucursal: solo sus facturas y el cobro se aplica
  solo a ellas.
- **Inventario** con subpestañas: Productos (buscar, crear/editar producto o servicio con categoría, unidad,
  impuesto, ¿incluye ISV?, mínimo y campos extra; cambiar precio con motivo e historial; activar/desactivar),
  Existencias por bodega (alerta bajo mínimo; costos solo con permiso), Conteo físico a ciegas (también celular con
  Cámara; crea ajustes pendientes de aprobación), Movimientos (kardex), Traslados (con confirmar recepción entre
  sucursales) y Excel (descargar con columnas azules/grises y hoja Instrucciones; subir con vista previa por fila;
  Guardar deshabilitado mientras haya errores). Excel con SheetJS (`xlsx-js-style` 1.2.0, Apache 2.0) en `vendor/`.
- **Ajustes** con subpestañas según permisos: Mi negocio (nombre comercial, logo, colores con vista previa y
  "Volver al anterior"; datos fiscales solo el dueño), Usuarios y permisos ("X de Y usados", agregar con clave
  temporal, desactivar, sucursales, cerrar sesión a distancia, "Solicitar ampliación", tabla de permisos solo del
  dueño), Cajas y bancos, Impuestos, Reglas y topes (solo dueño) y Mis datos (licencia, versión, descargar todo).
- Demo: segunda bodega (B2) y límite de 5 usuarios. `servidor_app.js` imita la Edge Function `crear-usuario`.
- 11 pruebas nuevas en el navegador (30 en total).

## app 0.2.0 (núcleo 0.13.2: migración nueva 049)

- **Vender** (computadora y celular): buscar por nombre, código o código de barras (lector USB = código + Enter;
  botón Cámara con `BarcodeDetector` si el navegador lo tiene, si no avisa); carrito con cantidad (decimales si el
  producto lo permite), precio, descuento por línea y de factura; total con ISV desglosado calculado por el
  servidor (`calcular_venta_previa`, nueva en el núcleo 0.13.2); promociones: la sugerida (la que más descuenta)
  marcada y se puede cambiar, nunca se suman; aviso cuando el descuento pasa el tope (la venta queda pendiente);
  cliente opcional (Consumidor final), crédito solo con cliente; efectivo con vuelto, tarjeta, transferencia
  (por confirmar), crédito y mixto; el vendedor sin "vendedor que cobra" solo ve Crédito; turno: si se exige y no
  hay, ofrece abrirlo. Cobrar = `registrar_venta` con id_operacion fijo mientras el carrito no cambia y botón
  bloqueado mientras envía (doble clic no duplica).
- Comprobante (`documento_venta`): número de ticket o CAI, impresión de 80 mm (solo el comprobante, sin emojis)
  y "Enviar por WhatsApp" (wa.me).
- Ventas del día, Cotizaciones (crear con el mismo carrito y convertir en venta), Devoluciones (desde una venta:
  líneas, cantidades, motivo y destino que permite el dueño: devolver dinero o nota de crédito).
- **Caja**: Mi turno (abrir con fondo contado por total o por billetes, entradas y salidas, cerrar con conteo a
  ciegas y luego lo esperado y la diferencia), Depósito o retiro (cuentas guardadas, referencia), Gasto de caja
  chica (foto opcional: sin Storage solo se guarda el nombre), Cobrar a clientes.
- **Clientes**: lista con búsqueda, ficha con estado de cuenta y antigüedad, cobrar abono (a la más vieja o
  eligiendo facturas; lo que sobra queda a favor solo con confirmación), crear y editar (RTN de 14 números;
  límite y plazo solo con `terceros.credito`), Quién me debe (más vencido primero) con "Cobrar por WhatsApp".
- Letra mínima 15 px en las pantallas nuevas (ayudas y etiquetas subieron a 15 px).
- Menú: `todos` (permisos que hacen falta todos). Nuevos `js/datos.js` y `js/comprobante.js`. `sw.js` 0.2.0.
- Demo: categoría "Pinturas" con dos promociones vigentes y fondo de caja chica.
- Pruebas en Chromium: 19 (11 nuevas). Tocar la pestaña o subpestaña actual vuelve a empezar la pantalla.

## app 0.1.0 (núcleo 0.13.1, sin migraciones nuevas)

- Base de la PWA: `index.html`, manifest, íconos, service worker que guarda solo el cascarón,
  aviso "Sin conexión".
- Tema con variables CSS (azul marino, dorado, crema; IBM Plex) y controles en CSS aparte.
- Entrar y salir con correo y clave; perfil y permisos en memoria; revisión periódica de
  `mi_estado_sesion` (sesión cerrada a distancia, usuario desactivado, fuera de horario).
- Menú armado con módulos activos y permisos: pestañas y subpestañas en computadora (Ajustes al
  final); en celular barra inferior Resumen / Vender / Buscar / Más (Ajustes dentro de Más).
- Inicio: `resumen_hoy`, `donde_esta_mi_dinero`, `alertas_activas`, aprobaciones con Aprobar /
  Rechazar con motivo (`resolver_aprobacion` con id_operacion). Errores con el catálogo.
- Demo local: `herramientas/demo_app.sh`, `servidor_app.js`, `emulador_supabase.sql`, `demo_datos.sql`.
- Pruebas en Chromium: `herramientas/probar_app.sh` (8 pruebas).
