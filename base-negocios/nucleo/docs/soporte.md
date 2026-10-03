# Soporte temporal (009_soporte)

- `otorgar_acceso_soporte(empresa, vence_en, motivo)` — solo el dueño.
  Motivo mínimo 5 letras; vence en el futuro y como máximo en 30 días.
  Funciona aunque la licencia esté vencida.
- `revocar_acceso_soporte(empresa, motivo)` — quita todos los vigentes.
- Mientras esté vigente, los usuarios proveedor de esa empresa tienen los
  permisos de lectura financiera (`contabilidad.ver`, `bitacora.ver`,
  `inventario.costos`, `compras.ver`, `terceros.ver`). Nunca los que mueven
  los libros. Sin soporte vigente tampoco ve clientes ni proveedores.
- Esto vale para el usuario proveedor dentro de la app. Con la llave
  `service_role` o la clave `postgres` técnicamente se lee todo: se regula
  por contrato y bitácora (PROCEDIMIENTOS P-04).
- Vence solo (se compara con la hora del servidor). No se edita ni se borra.
- Todo queda en bitácora (quién, motivo, hasta cuándo, revocación).
