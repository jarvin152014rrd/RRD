# Pendientes de la app (0.10.0)

- HECHO (0.8.0): comas en impuestos, topes, mínimo, traslados y conteo. Quedan los campos `type=number`
  (arqueo por billetes, devoluciones, plazos), que el navegador ya no deja escribir con coma.
- Reportes (0.8.0), lo que falta o es dudoso:
  - NÚCLEO (usuario limitado a su sucursal): `estado_resultados`, `saldo_cuentas`, `balance_general`,
    `bitacora_legible`, `verificar_bitacora`, `historial_cierres`/`exportar_mes` y `v_ventas_por_vendedor` /
    `v_ventas_por_dia` son de TODA la empresa. La app no muestra ¿Gané o perdí?, Quién hizo qué, Cierre de mes ni
    las ventas por vendedor a un usuario limitado. Falta la versión por sucursal en el núcleo.
  - HECHO (0.9.0, núcleo 0.16.0): `v_comision_vendedor` se limita por sucursal en el servidor y el limitado la ve.
    NO SE HARÁ en el núcleo la versión por sucursal de estados/saldo de cuentas (ver nucleo/docs/sucursales.md).
  - HECHO (0.9.0): lo más vendido con `mas_vendido` (suma el servidor y resta devoluciones). Ventas por forma de
    pago, valorizado, comisiones y turnos siguen leyendo hasta 1,000 filas (se avisa).
  - Con un núcleo 0.15.0 lo más vendido sigue sin restar devoluciones (método viejo).
  - "Sin ventas en N días" mira solo salidas por venta del kardex; si hay más de 1,000 en esos días no lista nada.
  - "Gastos por categoría" agrupa por la cuenta contable (6.1…), no por la categoría de gasto de Dinero.
  - El pre-cierre usa las advertencias del núcleo; el "conteo pendiente" sale como solicitud pendiente. No hay
    una lectura del núcleo que dé la lista "listo / falta" completa ni el descuadre por asiento antes de cerrar.
  - HECHO (0.10.0): anular un reparto y un pago a un socio en Dinero > Fondos y socios; el cierre explica los pasos
    para reabrir un mes con reparto.
  - Núcleo 0.16.0: `cerrar_mes` y `reabrir_periodo` aceptan `id_operacion` opcional; la app todavía no lo manda
    (con 0.15.0 fallaría; el reintento ya es seguro por el estado del mes).
  - Ventas por vendedor para un usuario limitado y el PDF del cierre (hoy: Imprimir y Excel).
  - Los formatos NIIF y los libros de ISV los debe validar un contador hondureño.
- HECHO (0.9.0, núcleo 0.16.0): cifras de Compras y Gastos con `totales_compras` / `totales_gastos` (con 0.15.0, como antes).

- Pantallas en construcción (con su estado vacío amable): apartados y cajas abiertas.
  HECHO (0.8.0): Reportes y cierre de mes. HECHO (0.7.0): Compras (compras, proveedores, pagar a proveedores) y Dinero (gastos, depósitos y traslados,
  pagos fijos, fondos y socios, cuadrar con el banco, proyección).
- HECHO (0.10.0, núcleo 0.16.0): aportes de capital de los socios (registrar, lista y anular) y anular un reparto o un
  pago a socio. Faltan en pantalla: guardar socios y la regla de reparto, editar o desactivar un fondo. Falta la foto
  del comprobante del aporte (el núcleo no la guarda todavía).
- Usar un fondo exige el comprobante subido a Supabase Storage (`bucketComprobantes` en config.js): sin eso la
  pantalla lo explica y no deja guardar. No probado contra Storage real.
- Cuadrar con el banco: falta crear "otro" movimiento (pide un código de cuenta) y emparejar varias filas contra
  un movimiento (pendiente en el núcleo). La lectura del CSV cubre formatos comunes; probar con los CSV reales de
  BAC, Atlántida, Ficohsa y Banpaís.
- Gastos: la foto del comprobante, sin Storage, queda solo como nombre en la descripción (como en Caja).
- HECHO (núcleo 0.16.0): `proyeccion_flujo` (la app ya la muestra al limitado), `estado_fondos` y `v_conciliacion`
  se limitan en el servidor. La app conserva sus filtros para cuando el núcleo es 0.15.0. Falta (núcleo):
  `pagos_fijos_proximos` y `pago_fijo` (la app oculta los que se pagan desde una cuenta que no ve).
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
- HECHO (núcleo 0.16.0): `v_cxp_documento`, saldos iniciales, `pago_proveedor`, `compra_linea` y
  `pago_proveedor_anulacion` se limitan en el servidor y pagar un saldo inicial exige no tener restricción. La app
  conserva su filtro (`cuentasPorPagar` y la ficha del proveedor) para el núcleo 0.15.0.
- HECHO (0.6.0): "Alertas que recibo" y el estilo nuevo en todas las pantallas. Falta: notificaciones al celular.
- Excel: los nombres con emojis se descargan tal cual (si se quitaran, al volver a subir el archivo saldrían
  como "cambios"). Solo lo impreso y lo que se manda por WhatsApp va sin emojis.
- Comprobante: todavía no lleva el logo del negocio (la ronda 2 no agrega cambios visuales a lo impreso).
- Vender no tiene un título grande (h1) arriba: la pantalla empieza con "Buscar producto o servicio".
- DECISIÓN: la pantalla de entrar muestra la marca (nombre, logo y colores) guardada en ESE equipo: en un equipo
  compartido entre empresas distintas, la pantalla de entrar muestra la marca del último negocio. Son datos
  públicos del negocio, no sensibles. En un equipo nuevo usa `nombreNegocio` de `config.js` (lo pone
  `armar_app.sh` desde la ficha) o "Mi Negocio".
- HECHO (núcleo 0.16.0): `guardar_preferencias_alertas` rechaza los tipos que el puesto no ve.
- HECHO (núcleo 0.16.0, prueba 133): cobro de un limitado "a la más vieja" solo en su sucursal y el saldo restante
  por factura (`saldo_restante_centavos`).
- Vista previa del Armador: su burbuja de logo sigue en 36 px (la app pasó a 44 px).
- HECHO (0.9.0, núcleo 0.16.0): Inicio "Lo más vendido" con `mas_vendido` (resta devoluciones; al limitado, su
  sucursal). Con núcleo 0.15.0: como antes (1,000 líneas, sin restar devoluciones).
- HECHO (núcleo 0.16.0): `donde_esta_mi_dinero` ya trae solo sus cuentas al limitado (la app conserva su filtro).
- Inicio: a un usuario restringido por sucursal no se le muestra la gráfica de 7 días (`v_ventas_por_dia` es de toda
  la empresa).
- Fotos de productos: la burbuja de "Lo más vendido" ya está lista para la miniatura.
- Fotos de comprobantes: se suben a Supabase Storage solo con `bucketComprobantes` en config.js (no probado
  contra Supabase real); en la demo no hay Storage y se guarda solo el nombre de la foto en la descripción.
- HECHO (0.10.0, núcleo 0.16.0): cambio de producto en Devoluciones (la diferencia se cobra, o se devuelve / queda
  como saldo a favor o vale). Falta: elegir vale / saldo a favor como forma de pago en Vender (para usar ese saldo
  después) y un cambio que pase el tope del cajero (hoy: lo hace quien aprueba).
- Devoluciones: la cantidad a devolver sigue en un campo `type=number` (sin coma).
- Productos y clientes se leen completos (hasta 1,000) y se buscan en el navegador; con catálogos más grandes
  hará falta una búsqueda en el servidor.
- Vender no muestra existencias por bodega ni deja cambiar el precio (el núcleo no lo permite: solo descuento).
- HECHO (0.8.0): totales de ventas en Reportes > Ventas.
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
- HECHO (núcleo 0.16.0): el servidor aplica "a la más vieja" solo en las sucursales del cajero limitado y rechaza
  aplicar a otra sucursal.
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
