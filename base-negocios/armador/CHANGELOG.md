# Cambios del Armador

## armador 0.2.0 (2026-10-12) — núcleo 0.15.0, app 0.4.0

- **Clientes > Exportar para Supabase:** pide el User UID del dueño (y opcional el del soporte), valida el formato
  y descarga `instalar_supabase_primer_cliente_<cliente>.sql` (también queda en `dist/`) para pegar en el SQL
  Editor del proyecto real. Usa `herramientas/exportar_supabase.sh`. Sin claves dentro.
- El `config.js` del cliente lleva `modo: 'supabase'`. Prueba nueva en `probar_armador.cjs` (13).

## armador 0.1.0 (2026-10-12) — núcleo 0.14.0 (sin migraciones nuevas), app 0.3.1

- Pantalla del proveedor (`armador/`) y `herramientas/servidor_armador.js`: solo 127.0.0.1, clave del
  proveedor (huella scrypt fuera de git), nunca expone conexiones con clave.
- Cinco plantillas por rubro como datos: ferretería, salón de belleza, taller mecánico, tienda/abarrotería,
  restaurante/comedor (módulos, perfil, límites, categorías, unidades, campos extra, palabras, demo).
- Cuestionario de 15 preguntas que sugiere módulos, régimen, perfil, paquete y límites explicando por qué;
  revisa dependencias de `modulo_dependencia`.
- Armado con vista previa del menú por puesto; Crear (ficha + app.json + config.js + empresa con licencia,
  límites, marca, categorías, unidades y campos); Aplicar cambios con vista previa, confirmación e historial.
- Modo demostración por rubro (`herramientas/demo_rubro.sql`, generaliza `demo_datos.sql`).
- Lista de clientes (`lista_clientes.sh --json`) con uso/límite, marca de 80 %, licencia, núcleo y solicitudes.
- Pruebas: `herramientas/probar_armador.sh` (12 pruebas en Chromium).
