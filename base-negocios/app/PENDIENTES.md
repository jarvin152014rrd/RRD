# Pendientes de la app (0.3.0)

- Pantallas en construcción: apartados, cajas abiertas, compras, dinero, reportes, buscar, "Alertas que recibo".
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
- Contador de alertas y aprobaciones en las subpestañas; notificaciones al celular.
- Meta de ventas del día en Inicio (el núcleo aún no la tiene).
- Al fallar Aprobar porque otro ya resolvió, la lista se refresca solo al volver a entrar a Inicio.
- Letra IBM Plex se baja de Google Fonts; sin internet usa la del sistema. Evaluar incluirla en la app.
- Tokens: el de renovación se guarda en el navegador (como Supabase) para no pedir la clave cada vez;
  revocar tokens en Supabase al cerrar sesión a distancia necesita la Edge Function (pendiente del núcleo).
- Probar en Supabase real (la demo usa un emulador local de PostgREST/Auth).
- **Alta de usuarios con clave en Supabase real:** falta publicar la Edge Function `crear-usuario` (la app ya la
  llama en `/functions/v1/crear-usuario` con el token del usuario; en la demo la imita `servidor_app.js`, donde la
  clave de todos es la de la demo). Debe crear el usuario de Auth con la llave service_role SOLO dentro de la
  función y llamar `agregar_usuario_empresa` como quien la llama (ver `nucleo/docs/usuarios.md`); si el núcleo
  rechaza (límite del contrato), borrar el usuario recién creado. Tampoco hay "reactivar usuario" ni
  "restablecer contraseña" en pantalla (usuario_empresa no guarda el correo).
- Cobro del cajero restringido por sucursal: la app manda a qué facturas va el abono (solo las de su sucursal); el
  servidor todavía no rechaza un cobro "a la más vieja" que caiga en otra sucursal si alguien lo llama por fuera.
- Cajas y bancos: cargar el saldo inicial de una cuenta YA creada (solo al crearla); editar nombre/fondo fijo.
- Inventario: crear categorías, unidades, campos extra y bodegas en pantalla (hoy: Excel de categorías o SQL);
  carga inicial de existencias en pantalla (hoy: hoja "Existencias iniciales" del Excel); anular ajustes/traslados.
- Excel: los productos se leen hasta 1,000 y el archivo hasta 5,000 filas (límite del servidor).
- Reglas y topes: guardar varios topes a la vez son llamadas separadas; si una falla, las anteriores quedan guardadas.
- La tabla de permisos deja marcar al contador permisos que mueven libros; el servidor lo rechaza con mensaje.
- Fotos de logo: se guardan dentro de la base (hasta 200 KB); con Storage convendría guardarlas allá.
