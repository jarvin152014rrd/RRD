# Pendientes de la app (0.2.0)

- Pantallas en construcción: apartados, cajas abiertas, inventario, compras, dinero, reportes, ajustes, buscar.
- Fotos de comprobantes: se suben a Supabase Storage solo con `bucketComprobantes` en config.js (no probado
  contra Supabase real); en la demo no hay Storage y se guarda solo el nombre de la foto en la descripción.
- El cajero no tiene `ventas.ver`: no ve lo que deben los clientes, así que "Cobrar a clientes" sale solo a
  quien tiene `ventas.cobrar` y `ventas.ver`. Si el dueño quiere que el cajero cobre abonos, el núcleo necesita
  una lectura de saldos para `ventas.cobrar` (decisión de negocio).
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
