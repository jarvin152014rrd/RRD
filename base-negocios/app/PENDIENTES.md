# Pendientes de la app (0.5.1)

- Pantallas en construcción: apartados, cajas abiertas, compras, dinero (salvo ¿Dónde está mi dinero?), reportes,
  proyección, "Alertas que recibo" (el núcleo ya tiene `mis_preferencias_alertas`: se puede hacer en la ronda 2).
- Rediseño ronda 2: llevar el estilo nuevo (íconos en títulos, burbujas, estados vacíos) a las demás pantallas.
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
