# Base (001_base)

**Qué guarda:** empresa, sucursal (establecimiento SAR), caja (punto de
emisión), roles, permisos, rol x permiso por empresa, usuarios por empresa,
módulos activos, licencia, acceso de soporte, contadores.

**Empresa:** `moneda` ISO 4217 (HNL), `pais` ISO 3166 (HN), `zona_horaria`
(validada), `fecha_inicio` (no hay asientos antes), `dias_futuro_max` (0-31,
defecto 3), `rubro`.

**Roles:** dueño (todo), admin (día a día), cajero, vendedor, proveedor
(instala; sin cifras salvo soporte temporal; nunca mueve libros).

**Funciones de ayuda:** `hoy_local(empresa?)`, `mis_empresas()`,
`empresa_actual()`, `mi_rol(empresa)`, `tiene_permiso(permiso, empresa?)`,
`licencia_activa(empresa)`, `modulo_esta_activo(empresa, modulo)`, `iso(momento)`.
Internas: `exigir_escritura`, `exigir_lectura`, `estado_licencia`, `siguiente_numero`.

**Ojo:** licencia vencida = solo lectura (consultar y exportar nunca se bloquea).
Sin fila de licencia = solo lectura.
