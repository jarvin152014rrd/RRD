# Instalación (007_instalacion)

`crear_empresa_inicial(ficha jsonb)` — solo `service_role`. La ficha se
describe en `personal/ficha.schema.json`; la función la vuelve a validar
(campos desconocidos, RTN, moneda, país, zona, fecha de inicio, días,
módulos, dueño registrado) y responde `FICHA_INVALIDA: <campo>: ...` o
`USUARIO_NO_EXISTE`.

Crea: empresa, sucursal 001, caja 001, dueño (y proveedor), permisos por
defecto, módulos (contabilidad siempre) y catálogo. **No** crea licencia:
queda en solo lectura hasta activarla.

Herramienta: `herramientas/nuevo_cliente.sh [--solo-validar] ficha.json`.
