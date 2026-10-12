# Cambios de la app

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
