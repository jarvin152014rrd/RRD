# Catálogo de errores (008_catalogo_errores)

Tabla `error_catalogo (codigo, mensaje_usuario, que_hacer)`, legible por
cualquier usuario con sesión.

Cómo la usa la app: del error recibido toma lo que va antes de `:` (la
clave), busca la fila y muestra `mensaje_usuario` + `que_hacer`. Si no la
encuentra, muestra el texto original (que ya viene en español).

Regla: toda clave nueva se agrega en la misma migración que la usa. La
prueba 17 revisa todos los `RAISE EXCEPTION` de las migraciones.
