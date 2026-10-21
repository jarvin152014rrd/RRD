# Pendientes de la app (0.7.1)

- Comas: unos pocos campos que NO usan `aCentavos`/`aCantidad` todavía toman la coma como decimal ("2,5" = 2.5):
  porcentaje de impuestos, topes en Reglas, mínimo del producto y cantidades de Traslados de inventario. Pasarlos
  a la misma regla (coma solo de miles) en la próxima ronda.
- Cifras de Compras y Gastos: suman hasta 300 filas (se avisa). Falta una lectura de totales en el núcleo.

- Pantallas en construcción (con su estado vacío amable): apartados, cajas abiertas, reportes y cierre de mes.
  HECHO (0.7.0): Compras (compras, proveedores, pagar a proveedores) y Dinero (gastos, depósitos y traslados,
  pagos fijos, fondos y socios, cuadrar con el banco, proyección).
- Fondos: el núcleo no tiene "aporte de capital" de un socio (solo repartos de utilidad y su pago). Faltan en
  pantalla: guardar socios y la regla de reparto, editar o desactivar un fondo y anular un reparto o un pago a
  socio (el núcleo sí los tiene).
- Usar un fondo exige el comprobante subido a Supabase Storage (`bucketComprobantes` en config.js): sin eso la
  pantalla lo explica y no deja guardar. No probado contra Storage real.
- Cuadrar con el banco: falta crear "otro" movimiento (pide un código de cuenta) y emparejar varias filas contra
  un movimiento (pendiente en el núcleo). La lectura del CSV cubre formatos comunes; probar con los CSV reales de
  BAC, Atlántida, Ficohsa y Banpaís.
- Gastos: la foto del comprobante, sin Storage, queda solo como nombre en la descripción (como en Caja).
- NÚCLEO (usuario limitado a su sucursal): `proyeccion_flujo` es de toda la empresa (la app no la muestra a un
  usuario limitado); `pagos_fijos_proximos` y `pago_fijo` tampoco se limitan (la app oculta los que se pagan desde
  una cuenta que no ve); `estado_fondos` trae el saldo de cuentas de otra sucursal (la app no lo muestra);
  `v_conciliacion` trae bancos de otras sucursales (la app solo muestra los bancos que el usuario ve).
- Compras: solo de productos que se guardan en inventario (así es `registrar_compra` del núcleo: un servicio da
  `PRODUCTO_INVALIDO`). Un servicio comprado (flete, reparación) se registra como gasto en Dinero.
- Compras: el total de la pantalla es aproximado (calculado en el navegador con la tasa de cada producto); el
  oficial lo da el núcleo al guardar y se muestra. Falta una lectura del núcleo tipo `calcular_venta_previa`
  para compras si se quiere el total exacto antes de guardar.
- Compras: el costo por unidad debe ser mayor que cero en pantalla (el núcleo acepta 0 para regalos o muestras).
- Proveedores: falta desactivar o reactivar en pantalla (`desactivar_tercero`, `terceros.desactivar`) y
  marcar como proveedor a alguien que ya es cliente.
- Saldos iniciales de proveedores (`registrar_saldo_inicial_cxp`, solo el dueño): se pagan desde la app, pero
  todavía se cargan solo por Excel o SQL.
- NÚCLEO (usuario limitado a su sucursal): `v_cxp_documento` deja fuera las compras de otras sucursales (RLS de
  `compra`) pero NO los saldos iniciales, y las tablas `pago_proveedor`, `compra_linea` y
  `pago_proveedor_anulacion` no se limitan por sucursal. La app ya quita en pantalla los de otra sucursal
  (`cuentasPorPagar` y la ficha del proveedor), pero el dato llega al navegador; tampoco hay revisión de sucursal
  al pagar un saldo inicial. Conviene filtrarlo en el núcleo (próxima migración).
- HECHO (0.6.0): "Alertas que recibo" y el estilo nuevo en todas las pantallas. Falta: notificaciones al celular.
- Excel: los nombres con emojis se descargan tal cual (si se quitaran, al volver a subir el archivo saldrían
  como "cambios"). Solo lo impreso y lo que se manda por WhatsApp va sin emojis.
- Comprobante: todavía no lleva el logo del negocio (la ronda 2 no agrega cambios visuales a lo impreso).
- Vender no tiene un título grande (h1) arriba: la pantalla empieza con "Buscar producto o servicio".
- DECISIÓN: la pantalla de entrar muestra la marca (nombre, logo y colores) guardada en ESE equipo: en un equipo
  compartido entre empresas distintas, la pantalla de entrar muestra la marca del último negocio. Son datos
  públicos del negocio, no sensibles. En un equipo nuevo usa `nombreNegocio` de `config.js` (lo pone
  `armar_app.sh` desde la ficha) o "Mi Negocio".
- NÚCLEO (próxima migración): `guardar_preferencias_alertas` no revisa `interno.puede_ver_alerta`
  (045_alertas_resumen.sql, líneas 320-328): un usuario podría guardar preferencias de tipos que no ve. No hace
  daño (esas alertas no le llegan igual), pero conviene rechazarlo en el servidor.
- Cobro de un usuario limitado a su sucursal: falta una prueba automática del saldo restante (hoy se calcula en
  la app como lo que debía en su sucursal menos lo aplicado).
- Vista previa del Armador: su burbuja de logo sigue en 36 px (la app pasó a 44 px).
- Inicio: "Lo más vendido" se calcula en el navegador con las últimas 1,000 líneas de venta (si hay más en la
  semana, lo dice). Con mucho volumen convendrá una función del núcleo que ya lo sume.
- NÚCLEO: `donde_esta_mi_dinero` devuelve las cuentas de TODA la empresa a un usuario limitado a sucursal. La app
  ya solo muestra las suyas (0.5.1), pero el dato llega al navegador: corregirlo en el núcleo (filtrar con
  `interno.sucursal_permitida`, como `resumen_hoy`).
- "Lo más vendido" no resta devoluciones (lo dice en pantalla); falta una lectura de devoluciones por producto.
- Inicio: a un usuario restringido por sucursal no se le muestran la gráfica ni lo más vendido (las vistas son de
  toda la empresa).
- Fotos de productos: la burbuja de "Lo más vendido" ya está lista para la miniatura.
- Fotos de comprobantes: se suben a Supabase Storage solo con `bucketComprobantes` en config.js (no probado
  contra Supabase real); en la demo no hay Storage y se guarda solo el nombre de la foto en la descripción.
- Devoluciones: falta el "cambio de producto" en pantalla (el núcleo ya lo tiene) y elegir vale / saldo a favor
  como forma de pago en Vender.
- Productos y clientes se leen completos (hasta 1,000) y se buscan en el navegador; con catálogos más grandes
  hará falta una búsqueda en el servidor.
- Vender no muestra existencias por bodega ni deja cambiar el precio (el núcleo no lo permite: solo descuento).
- La lista de "Ventas del día" no suma totales (eso es de Reportes, con `v_ventas_por_dia`).
- Venta y cobro sin internet (cola local con id_operacion y rango CAI por caja). Hoy sin internet solo
  se ve el aviso; no se guarda nada.
- Modo sencillo (perfil pequeño con pocas pestañas): falta decidir qué pestañas quedan.
- Elegir empresa cuando un usuario tiene varias (hoy entra a la última usada o la primera).
- HECHO (0.5.0): número de pendientes en la campanita y en la subpestaña. Falta: notificaciones al celular.
- Meta de ventas del día en Inicio (el núcleo aún no la tiene).
- Al fallar Aprobar porque otro ya resolvió, la lista se refresca solo al volver a entrar a Inicio.
- Letra IBM Plex se baja de Google Fonts; sin internet usa la del sistema. Evaluar incluirla en la app.
- HECHO (0.4.0): Edge Functions `crear-usuario` y `cerrar-sesion-remota` (`supabase/functions/`, probadas contra el
  emulador con `app-pruebas/probar_funciones.mjs`) y `herramientas/armar_app.sh` para Netlify.
- FALTA: probar todo en un proyecto REAL de Supabase y en Netlify (desde aquí no hay red a supabase.co). En
  especial: las pantallas después de entrar con la CSP de `_headers` (la prueba local solo abre la pantalla de
  entrar), las Edge Functions con las llaves nuevas (`sb_publishable_`/`sb_secret_`) y "Cerrar sesión" en modo
  supabase en el navegador (probado solo la función, no el botón en ese modo).
- Falta "reactivar usuario" y "restablecer contraseña" en pantalla (usuario_empresa no guarda el correo).
- Si "Agregar usuario" usa un correo que YA tenía cuenta en Auth, no se le cambia la clave (se avisa "entra con
  la clave que ya usaba"); si no la recuerda, hoy se cambia desde Authentication > Users.
- Cobro del cajero restringido por sucursal: la app manda a qué facturas va el abono (solo las de su sucursal); el
  servidor todavía no rechaza un cobro "a la más vieja" que caiga en otra sucursal si alguien lo llama por fuera.
- Cajas y bancos: cargar el saldo inicial de una cuenta YA creada (solo al crearla); editar nombre/fondo fijo.
- Inventario: crear categorías, unidades, campos extra y bodegas en pantalla (hoy: Excel de categorías o SQL);
  carga inicial de existencias en pantalla (hoy: hoja "Existencias iniciales" del Excel); anular ajustes/traslados.
- Excel: los productos se leen hasta 1,000 y el archivo hasta 5,000 filas (límite del servidor).
- Reglas y topes: guardar varios topes a la vez son llamadas separadas; si una falla, las anteriores quedan guardadas.
- La tabla de permisos deja marcar al contador permisos que mueven libros; el servidor lo rechaza con mensaje.
- Fotos de logo: se guardan dentro de la base (hasta 200 KB); con Storage convendría guardarlas allá.
- **Armador / rubros:** los "datos de cada orden" del rubro (taller: placa, marca y modelo, kilometraje; salón:
  estilista; restaurante: mesa y mesero) se guardan en `app.json` (`campos_orden`) pero la app todavía no los pide
  en Vender: falta un lugar en el núcleo para guardarlos en la venta (módulo futuro "órdenes de trabajo").
  Las palabras solo cambian títulos del menú; los encabezados dentro de las pantallas (ej. "Ventas del día")
  siguen con la palabra de siempre. Reportes típicos por rubro: solo anotados en la plantilla.
- Armador contra Supabase real (crear y aplicar): no probado; solo contra la base local.
