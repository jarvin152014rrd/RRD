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

Extras: panel "Mi negocio hoy", modo vacaciones (admin a cargo con límites y
fechas), rol contador de solo lectura, deshacer el último cambio de Ajustes,
página "Mi cuenta" (plan, módulos, próximo pago, pedir módulo).

## Ayuda dentro del programa

- Botón "?" en cada pantalla con guía corta en texto (funciona sin internet).
- Enlace opcional a video en YouTube (no listado). Los videos NO van dentro
  del programa: solo se guarda el enlace.

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

## Celular

Resumen del negocio, venta rápida, consultar precio y existencia, conteo de
inventario con cámara, recibir mercadería, cobrar abonos, gasto con foto del
comprobante, aprobaciones y alertas.

## Cierre de mes

Selector de cualquier mes anterior con estado de resultados, flujo, saldos de
clientes, inventario valorizado y balance, descargables en PDF y Excel. Cerrar
bloquea sin borrar. Reabrir: solo dueño, con motivo, en orden.
