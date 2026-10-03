# Requisitos acordados con el dueño del proyecto

Lista viva de lo que se decidió en las conversaciones. Cada etapa nueva debe
revisar este archivo antes de empezar. Si algo cambia, se actualiza aquí.

## Reglas generales

- Un solo programa (PWA) para computadora y celular, con un solo "cerebro":
  toda la lógica de dinero vive en el servidor.
- Al entrar, el programa reconoce el puesto (dueño, admin, cajero, vendedor,
  contador, proveedor) y muestra solo lo permitido. El servidor también lo bloquea.
- Activar y desactivar en vez de borrar: usuarios, productos, cajas, cuentas,
  fondos, pagos fijos, alertas, módulos.
- Menú por pestañas y subpestañas por tema. Ajustes siempre al final.
- **Sin emojis en PDFs ni en documentos impresos o descargables.**
- Sin internet: solo venta rápida y cobro, con cola local, id_operacion y
  rango CAI por caja. Todo lo demás requiere conexión.

## Autoservicio (el cliente no depende del proveedor)

Principios: vista previa, confirmación, bitácora y posibilidad de revertir en
cada cambio de Ajustes. El dueño pone los límites; el admin opera dentro de ellos.

Solo dueño: datos fiscales (RTN), activar/desactivar módulos pagados, crear o
desactivar administradores, tabla de permisos y puestos nuevos, horarios de
acceso por puesto, topes (crédito, descuento, monto que pide aprobación,
aprobaciones del admin), comisiones, reglas de distribución de utilidades y
fondos, reabrir meses, acceso de soporte del proveedor, descarga total de datos,
usuario contador.

Admin (dentro de los topes): usuarios vendedor/cajero, restablecer contraseñas
(no la del dueño), cerrar sesión a distancia, CAI, sucursales/cajas/bodegas,
catálogos, productos, precios (individual y masivo por %), listas de precios,
promociones con fechas, campos extra, clientes y límites de crédito, formas de
pago, bancos, pagos fijos, metas de venta, aprobaciones hasta su tope, cierre
de mes, alertas y reportes programados, Excel de ida y vuelta.

Topes de gasto (0.5.0, valor inicial a confirmar con el dueño): el admin
registra sin aprobación y aprueba hasta L 5,000.00; los demás puestos piden
aprobación siempre. El dueño los cambia por puesto.

Extras: panel "Mi negocio hoy", modo vacaciones (admin a cargo con límites y
fechas), rol contador de solo lectura, deshacer el último cambio de Ajustes,
página "Mi cuenta" (plan, módulos, próximo pago, pedir módulo).

Rol contador (hecho en 0.4.0): solo lectura de contabilidad, reportes,
bitácora, clientes y proveedores, compras y existencias. SÍ ve costos y valor
del inventario (los necesita para el balance y el costo de ventas). Solo el
dueño lo crea; nunca recibe permisos que muevan los libros.

## Ayuda dentro del programa

- NO lleva botón "?" ni videos de ayuda (decisión del dueño).

## Rastreo del dinero (obligatorio)

- Cada lugar con dinero es una cuenta con nombre: cajas de efectivo (por
  turno y cajero), cada cuenta bancaria registrada (banco, número, tipo,
  moneda), caja chica, tarjeta/POS por liquidar, transferencias por confirmar,
  dinero en tránsito.
- Todo movimiento indica de qué cuenta sale y a cuál entra. Si es banco, se
  elige cuál de las cuentas bancarias registradas. No existe una salida de
  dinero sin destino ni una entrada sin origen.
- Depósitos de efectivo al banco y retiros de efectivo del banco: una sola
  operación (sale de una cuenta y entra a la otra), con comprobante. Depósito
  no confirmado = dinero en tránsito con alerta.
- Cada movimiento guarda usuario, fecha y hora del servidor, caja o equipo,
  referencia y foto del comprobante.
- Arqueo por turno y cajero, cuadre de caja chica, conciliación bancaria con
  CSV del banco, prueba diaria automática de cuadre.
- Reportes: "¿Dónde está mi dinero hoy?", estado de cuenta de cualquier cuenta
  por fechas o mes, "seguir una venta" (venta, cobro, caja, depósito, banco),
  flujo de dinero del mes.
- Hecho en 0.5.0 (sin ventas todavía): cuentas de dinero con su subcuenta,
  rastro de cada entrada y salida, depósito / retiro / reposición / traslado
  en una operación, depósito en tránsito con alerta (3 días por defecto, lo
  cambia el dueño), comprobantes (foto o PDF, solo agregar), gastos, caja
  chica con cuadre, pagos fijos, "¿dónde está mi dinero?" y estado de cuenta.
  Pendiente: conciliación con CSV del banco, prueba diaria automática,
  "seguir una venta", flujo del mes y cuentas en otra moneda (USD).

## Fondos y distribución de utilidades

- Fondos configurables, cada uno activable/desactivable: reinversión,
  emergencias y los que cree el dueño (por ejemplo: impuestos, aguinaldos,
  equipo nuevo).
- Al cerrar el mes, el dueño decide (o aplica su regla guardada) qué
  porcentaje de la utilidad va a cada fondo y cuánto a los socios.
- La distribución se calcula sobre la utilidad COBRADA (dinero que de verdad
  entró), mostrando también la utilidad facturada. Nunca repartir lo que aún
  se debe (error conocido de RRD).
- Meta opcional por fondo (por ejemplo: emergencias = 3 meses de pagos fijos).
- Asignar a un fondo es un asiento de patrimonio (utilidades a reserva). Si el
  dueño quiere separar el dinero físicamente, se hace además un traslado a la
  cuenta bancaria elegida para ese fondo.
- Usar un fondo exige: qué fondo, para qué, de qué cuenta física sale el dinero
  (caja, caja chica o cuál banco), comprobante y aprobación del dueño.
- Estado de cada fondo: saldo, aportes, usos y su rastro completo.

## Proyecciones

- Flujo de caja proyectado (30, 60, 90 días, vista semanal): dinero disponible
  hoy + cobros esperados de cuentas por cobrar según vencimiento − pagos de
  cuentas por pagar según vencimiento − pagos fijos.
- Cobros vencidos se muestran aparte (no se asume que entran).
- Alerta si alguna semana proyectada queda en negativo.

## Inventario y productos

- Código de barras por cámara del celular y lector USB en computadora.
- Excel de ida y vuelta: descargar la base actualizada (con campos extra),
  editar y subir con vista previa de errores. Nunca borra; vacío conserva el
  valor anterior; columna código como llave. Un solo Excel con hojas Productos,
  Existencias por sucursal, Clientes, Categorías.
- Plantillas por rubro como datos, no como código.

### Precio e ISV

- Cada producto tiene impuesto (15%, 18% o Exento) y la marca "precio incluye
  ISV" (Sí/No). El valor por defecto lo elige el dueño en Ajustes
  (recomendado: Sí). El programa calcula la otra cifra.
- Hecho en 0.4.0. Regla: el precio se guarda como se escribe; el ISV se
  calcula por línea (cantidad x precio) y se redondea a centavo, mitades
  hacia arriba. Productos de antes de 0.4.0 quedaron "sin ISV".
- Costo promedio (0.4.0): en orden de registro; no se registran entradas con
  fecha anterior a la última salida del producto en esa bodega, salvo el dueño.

### Columnas del Excel

Columnas azules = editables (se importan). Columnas grises = solo
información (se exportan y se ignoran al subir). Montos en lempiras con 2
decimales; fechas AAAA-MM-DD; celda vacía conserva el valor; nunca borra.

- Productos (editable): código (llave, no cambia), código de barras, nombre,
  descripción, categoría, subcategoría, unidad, se vende con decimales,
  impuesto, precio de venta, precio incluye ISV, existencia mínima, proveedor
  principal, ubicación, activo, campos extra.
  Solo información: costo promedio, existencia total, valor del inventario,
  margen %, precio con y sin ISV, última venta, última compra.
- Clientes y proveedores (editable): código, tipo, nombre o razón social, RTN,
  teléfono, correo, dirección, límite de crédito, plazo en días, activo,
  campos extra. Solo información: saldo actual, saldo vencido, último pago.
- Categorías: nombre, categoría padre, activo.
- Carga inicial (una sola vez): existencias iniciales (código, sucursal,
  bodega, cantidad, costo) y saldos iniciales de clientes y proveedores
  (documento, fecha, vencimiento, monto).
- Conteo físico: se descarga, se llena con lo contado y se sube; el programa
  calcula diferencias y crea ajustes que aprueba admin o dueño. Nunca cambia
  la existencia directamente.
- Hoja Instrucciones con cada columna y sus valores válidos.

## Celular

Resumen del negocio, venta rápida, consultar precio y existencia, conteo de
inventario con cámara, recibir mercadería, cobrar abonos, gasto con foto del
comprobante, aprobaciones y alertas.

## Cierre de mes

Selector de cualquier mes anterior con estado de resultados, flujo, saldos de
clientes, inventario valorizado y balance, descargables en PDF y Excel. Cerrar
bloquea sin borrar. Reabrir: solo dueño, con motivo, en orden.

## Ventas, caja y comisiones (decisiones para la etapa 2b)

- Turno de caja POR CAJERO: cada cajero abre y cierra su turno con arqueo.
  (Hecho en 0.5.0. Aclarado: una caja tiene un solo turno abierto a la vez y
  el cajero no ve el esperado hasta cerrar, conteo a ciegas.)
- Diferencia en el arqueo: queda como "diferencia pendiente"; el dueño o el
  admin decide, con motivo, si se cobra al cajero (cuenta por cobrar a
  empleado) o se envía a gasto.
- Venta al crédito CONFIGURABLE en Ajustes: según límite del cliente (pide
  aprobación si lo pasa o si es cliente nuevo) o siempre con aprobación.
- Anular venta: el vendedor solo la solicita; aprueba admin o dueño con
  motivo, mientras el mes esté abierto. La factura conserva su número y queda
  ANULADA.
- Cliente NO obligatorio: sin cliente la venta queda como "Consumidor final".
  El crédito, el apartado y el saldo a favor sí requieren cliente.
- Devoluciones: el dueño activa en Ajustes cuáles permite: devolver dinero
  (de la caja o banco elegido), cambio por otro producto (se cobra o devuelve
  la diferencia) y nota de crédito. Nota de crédito sin cliente = vale con
  código para una próxima compra.
- Extras incluidos: cotizaciones (no mueven inventario ni dinero; se
  convierten en venta) y apartados con anticipo (reservan mercadería).
- Descuentos de tres tipos: por categoría (promociones con fecha de inicio y
  fin), por artículo y por factura. Tope por puesto; si se pasa, pide
  aprobación en el momento.
- Comisiones: interruptor de encendido/apagado; porcentaje por empleado; base
  elegida por el dueño: sobre la GANANCIA (precio sin ISV menos costo,
  recomendado) o sobre el precio sin ISV. Nunca sobre el ISV. Se ganan cuando
  la venta está cobrada completa y se ajustan con devoluciones.

## Arranque fácil para cualquier tamaño de negocio

Objetivo: que un negocio pequeño, mediano o grande cargue sus datos y empiece
a dar seguimiento el primer día, sin trabas.

- Saldo negativo configurable POR CUENTA de dinero: no permitir (por defecto),
  permitir con alerta ("revisa el saldo inicial"), o sobregiro autorizado hasta
  un monto. Cargar saldos iniciales NO es obligatorio para empezar.
- Perfiles por tamaño (pequeño, mediano, grande): solo configuraciones de
  inicio (módulos, turnos obligatorios o no, aprobaciones, contabilidad
  visible o no, menú). Mismo núcleo para todos. Se pueden cambiar después.
- Asistente de arranque con avance: datos del negocio, usuarios, cajas y
  bancos con saldo inicial (o empezar en cero), productos, clientes con
  saldos, proveedores con saldos, primera venta. Cada paso se puede saltar y
  el programa recuerda lo pendiente sin bloquear.
- Valores iniciales aprobados: admin registra y aprueba gastos hasta L 5,000;
  arqueo a ciegas; solo lempiras por ahora (dólares más adelante).
- Hecho en 0.6.0: saldo negativo por cuenta (solo el dueño, con motivo),
  turnos obligatorios o no por empresa, perfiles pequeno/mediano/grande como
  datos (vista previa y aplicar, solo el dueño; nunca tocan módulos ni datos),
  asistente de arranque de 7 pasos y "empezar en cero". Valores iniciales
  confirmados (L 5,000, arqueo a ciegas, solo la moneda de la empresa).
  Pendiente: la doble aprobación solo se guarda; se aplicará en 2b-2. El paso
  "primera venta" se marcará solo cuando exista ventas (2b-2).
