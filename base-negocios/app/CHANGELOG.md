# Cambios de la app

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
