# Bitácora (002_bitacora)

**Qué guarda:** cada alta, cambio y baja en las tablas importantes: quién
(`usuario_id`), con qué rol, cuándo (hora del servidor), qué tabla y fila,
cómo estaba antes y cómo quedó, `id_operacion` y `motivo`.

**Solo agregar:** nadie la edita, borra ni vacía (ni el superusuario, salvo
que apague los triggers a propósito).

**Huella encadenada:** cada fila tiene `secuencia` (1, 2, 3... por empresa),
`huella_anterior` y `huella` (sha256 de la fila). `verificar_bitacora(empresa?)`
devuelve una fila por problema (vacío = intacta). Detecta filas editadas,
borradas (en medio o al final) y metidas sin pasar por el sistema.

**Límite honesto:** alguien con acceso total podría rehacer TODA la cadena.
Por eso, cada mes se guarda fuera la última huella (ver PROCEDIMIENTOS P-05).

**Permiso para verla:** `bitacora.ver` (dueño, admin; proveedor solo con soporte).
