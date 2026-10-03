# Soporte temporal (009_soporte)

- `otorgar_acceso_soporte(empresa, vence_en, motivo)` — solo el dueño.
  Motivo mínimo 5 letras; vence en el futuro y como máximo en 30 días.
  Funciona aunque la licencia esté vencida.
- `revocar_acceso_soporte(empresa, motivo)` — quita todos los vigentes.
- Mientras esté vigente, los usuarios proveedor de esa empresa tienen los
  permisos de lectura financiera (`contabilidad.ver`, `bitacora.ver`).
  Nunca los que mueven los libros.
- Vence solo (se compara con la hora del servidor). No se edita ni se borra.
- Todo queda en bitácora (quién, motivo, hasta cuándo, revocación).
