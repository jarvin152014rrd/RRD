# Convenciones del núcleo

Reglas para que todo el código se vea y funcione igual. Si algo nuevo no
cabe en estas reglas, se discute antes de programarlo.

## Nombres
- Todo en **español, sin tildes ni ñ** en nombres de tablas, columnas y
  funciones: `dueno`, `anio`, `sucursal`, `asiento_linea`.
- Tablas en **singular**: `empresa`, `cuenta`, `periodo`.
- Columnas que apuntan a otra tabla: `<tabla>_id` (`empresa_id`, `cuenta_id`).
- Sí/no: palabra que se lea como pregunta: `activa`, `es_detalle`, `suspendida`.
- Funciones que la app llama (RPC): verbo + cosa: `registrar_asiento`,
  `cerrar_periodo`, `crear_caja`. Parámetros con `p_` (`p_empresa_id`).
- Esquema `public`: lo que ve la app (con RLS). Esquema `interno`: lo
  privado (plantillas, contadores, funciones de ayuda). Nunca se expone.

## Dinero y cantidades
- Dinero **siempre en centavos enteros** (`bigint`), columnas terminadas en
  `_centavos`. L 115.00 = `11500`. Nunca `numeric` ni decimales para dinero.
- Tope por monto: 9,007,199,254,740,991 (el mayor entero exacto en JavaScript).
- Cantidades (unidades, kilos) sí pueden llevar decimales.
- Moneda de la empresa: código ISO 4217 (`HNL`, `USD`).

## Fechas y horas
- Columnas de momento (fecha + hora) terminan en **`_en`**: `creado_en`,
  `registrado_en`, `vence_en`, `revocado_en`. Tipo `timestamptz`. Las pone
  el servidor con `now()`, nunca el navegador.
- Columnas de solo fecha terminan en `fecha_...` o `_el`: `fecha_contable`,
  `fecha_inicio`, `vence_el`. Tipo `date`.
- "Hoy" siempre con `hoy_local(empresa)` (zona de la empresa).
- Todo lo que se exporta (JSON, CSV, reportes) va en **ISO 8601**:
  `2026-01-31` y `2026-01-31T18:00:00Z` (UTC, con `iso()`).
- País: ISO 3166-1 de 2 letras (`HN`).

## Permisos
- Formato **`modulo.accion`**, en minúsculas: `asientos.registrar`,
  `contabilidad.ver`, `usuarios.administrar`.
- `es_movimiento = true` si mueve los libros (el proveedor nunca lo tiene).
- `es_financiero = true` si deja leer cifras (el proveedor solo con soporte
  temporal vigente).
- Toda función que escribe empieza con `interno.exigir_escritura(...)`;
  toda función que lee cifras, con `interno.exigir_lectura(...)`.

## Errores
- Todo `RAISE EXCEPTION` empieza con una CLAVE en mayúsculas y dos puntos:
  `'NO_CUADRA: el debe ... '`. La clave va en `error_catalogo` con su
  mensaje sencillo y qué hacer (en la misma migración que la usa).

## Funciones
- `SECURITY DEFINER` siempre con `SET search_path = ''` y nombres completos
  (`public.asiento`), para que nadie "cuele" objetos.
- Cada RPC nueva: `REVOKE` de todos y `GRANT` solo a quien la usa.
- Lo que cambia algo con motivo usa `set_config('app.motivo', ..., true)`
  para que lo tome la bitácora, y lo limpia al terminar.

## Migraciones
- Archivo `NNN_nombre.sql` (tres dígitos): `012_ventas.sql`.
- Una migración **aplicada en un cliente no se edita nunca**: se crea la
  siguiente. `migrar.sh` lo detecta por la huella (sha256) del archivo.
- Cada migración corre completa o nada (una transacción).
- Toda tabla nueva en `public`: RLS activado, política de lectura, trigger
  `no_vaciar`, y si guarda datos del negocio: `auditar` y `no_borrar`.
- Cada cambio lleva su prueba en `nucleo/pruebas/prueba_NN_que_prueba.sql`
  (o `.sh`). La primera línea `-- PRUEBA:` / `# PRUEBA:` dice qué prueba.

## Versiones (VERSION_NUCLEO)
- MAYOR.MENOR.ARREGLO. ARREGLO: corrección sin cambios de uso. MENOR:
  funciones o columnas nuevas. MAYOR: algo deja de funcionar como antes.
- Cada versión se anota en `CHANGELOG.md`.
