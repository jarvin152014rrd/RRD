# Pendientes de la app (0.1.0)

- Pantallas en construcción: vender, caja, clientes, inventario, compras, dinero, reportes, ajustes, buscar.
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
