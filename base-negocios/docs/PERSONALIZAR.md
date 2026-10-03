# Personalizar para cada cliente

El **núcleo** (`nucleo/`) es igual para todos. Lo de cada cliente vive en
`personal/` y en los datos de su base. Así, una corrección del núcleo llega a
todos sin perder lo propio de nadie.

## Se cambia sin programar

| Qué | Dónde | Quién |
|---|---|---|
| Nombre, RTN, rubro, moneda, país, zona horaria | ficha del cliente (`clientes/<cliente>/ficha.json`, `negocio`) al instalar | proveedor |
| Fecha de inicio en el sistema | ficha (`fecha_inicio`) | proveedor, con el dueño |
| Días al futuro permitidos para fechas (0-31, defecto 3) | ficha (`dias_futuro_max`) | proveedor |
| Módulos activos (contabilidad, ventas, inventario, compras, dinero; fiscal_hn en `regimen_fiscal`) | ficha (`modulos` con true/false) y `aplicar_ficha.sh` (P-09) | proveedor |
| Licencia y límites del contrato (usuarios, cajas, sucursales, bodegas) | ficha (`licencia`, `limites`) y `aplicar_ficha.sh` | proveedor |
| Vendedor que cobra (sí/no) | `configurar_empresa` (`vendedor_cobra`); el perfil pequeño lo sugiere | dueño |
| Colores y logo | ficha (`tema`) | proveedor |
| Usuarios y su rol | app: `agregar_usuario_empresa` / `desactivar_usuario_empresa` | dueño (admin: solo cajero y vendedor) |
| Usuario contador (solo lectura, ve costos) | app: `agregar_usuario_empresa(..., 'contador')` | solo el dueño |
| Qué puede hacer cada rol | app: `cambiar_permiso_rol` (con motivo) | dueño |
| Sucursales y cajas (punto de emisión SAR) | app: `crear_sucursal`, `crear_caja`, `reactivar_*` | dueño o admin |
| Subcuentas del catálogo | app: `crear_subcuenta` (solo de detalle) | dueño |
| Cerrar / reabrir meses | app | dueño (reabrir), admin (cerrar) |
| Acceso de soporte temporal | app: `otorgar_acceso_soporte` | solo el dueño |
| Tope de crédito que puede dar el admin; permitir inventario negativo; si los precios nuevos incluyen ISV (defecto: sí) | app: `configurar_empresa` | solo el dueño |
| Si el precio de un producto incluye ISV | app: `editar_producto` con motivo (queda en el historial de precios) | dueño o admin (productos.precios) |
| Bodegas, categorías, unidades, campos extra de productos | app | dueño o admin |
| Productos y precios (con historial) | app | dueño o admin |
| Clientes y proveedores | app | dueño, admin (crédito hasta el tope); cajero y vendedor registran |
| Cuentas de dinero (cajas, bancos, caja chica y su fondo fijo), categorías de gasto, pagos fijos | app | dueño o admin |
| Saldos iniciales de las cuentas de dinero | app: `registrar_saldo_inicial_dinero` | solo el dueño |
| Topes por puesto (gasto sin aprobación y hasta cuánto aprueba; defecto admin L 5,000) | app: `configurar_tope_rol` | solo el dueño |
| Días de un depósito en tránsito antes de la alerta (defecto 3) | app: `configurar_empresa` | solo el dueño |
| Perfil de tamaño al instalar (pequeno, mediano, grande) | ficha (`perfil`) | proveedor, con el dueño |
| Cambiar de perfil (con vista previa) | app: `vista_previa_perfil` y `aplicar_perfil` (con motivo) | solo el dueño |
| Turnos de caja obligatorios, contabilidad visible en el menú, doble aprobación | app: `configurar_empresa` | solo el dueño |
| Saldo negativo de cada caja o banco (no permitir, permitir con alerta, sobregiro hasta un monto) | app: `configurar_saldo_negativo` (con motivo) | solo el dueño |
| Asistente de arranque (saltar o volver a pendiente un paso) | app: `estado_arranque`, `marcar_paso_arranque` | dueño o admin |
| Empezar una caja o banco en cero (sin saldo inicial) | app: `empezar_cuenta_en_cero` | solo el dueño |
| Licencia (vencimiento, gracia, suspensión) | tabla `licencia` con la llave service_role | proveedor |

## Perfiles por tamaño (cómo usarlos)

Un perfil es solo una configuración de inicio; el núcleo es el mismo para todos.

1. Al instalar, poner en la ficha `"perfil": "pequeno"` (o `mediano`, `grande`).
   Si la ficha no trae `"modulos"`, se activan los que sugiere el perfil; si los
   trae, mandan los de la ficha (los módulos pagados los decide el proveedor).
2. Después, el dueño puede ver qué cambiaría otro perfil con
   `vista_previa_perfil(empresa, 'mediano')` y aplicarlo con
   `aplicar_perfil(empresa, 'mediano', 'motivo')`. Queda en la bitácora.
3. Un perfil nunca borra datos ni activa o desactiva módulos. Si sugiere un
   módulo que no está activo, la vista previa lo avisa: se pide al proveedor.
4. Cada ajuste se puede cambiar luego por separado (`configurar_empresa`,
   `configurar_tope_rol`, `configurar_saldo_negativo`).
5. Los valores de cada perfil viven en `interno.plantilla_perfil*`: si hay que
   cambiarlos para TODOS, va en una migración nueva. Detalle en `nucleo/docs/arranque.md`.

## No se toca NUNCA (ni por un cliente "especial")

- Las migraciones de `nucleo/sql/migraciones/` ya aplicadas. Si algo hay que
  cambiar, se hace una migración nueva **para todos**.
- Las reglas de oro: nada se borra ni se edita, dinero en centavos,
  todo-o-nada, `id_operacion`, debe = haber, mes cerrado no recibe asientos.
- La bitácora, sus triggers y su huella. Nunca se desactivan los triggers.
- RLS y permisos de tablas (`006_seguridad`). La app nunca escribe tablas
  directo: solo llama funciones.
- Que el proveedor no mueva los libros ni vea cifras sin acceso de soporte.
- Los códigos de cuenta existentes del catálogo (se puede renombrar o
  desactivar una cuenta, nunca cambiar su código, tipo o naturaleza).
- La llave `service_role` jamás va en la app ni en `personal/`.
- Las cuentas que usan los módulos (1.1.03.01, 2.1.01.01, 3.3.01.03 Saldos de
  apertura, 1.1.02.04 Diferencias de caja...). Están en `interno.cuenta_sistema`
  (y `interno.cuenta_sistema_empresa` si el código ya era del cliente); no se
  renombran a mano. Las subcuentas de las cuentas de dinero tampoco reciben
  asientos manuales.

## Lo que el proveedor puede ver (dicho con honestidad)

Dentro de la app, el usuario proveedor no ve cifras, costos, compras ni
clientes y proveedores, salvo con el acceso de soporte temporal que da el
dueño. Pero quien tiene la llave `service_role` o la clave `postgres` del
proyecto (las usa el proveedor para instalar, actualizar y respaldar)
**técnicamente puede leer todo** la base. Eso no se bloquea con código: se
regula por **contrato** (solo usarlas para P-01, P-02 y P-03), por la
**bitácora con huella** (P-05) y porque el dueño puede **cambiar esas claves**
en Supabase cuando quiera. Ver `docs/PROCEDIMIENTOS.md` P-04.

## Si un cliente pide algo que no cabe

1. Ver si se resuelve con lo de arriba (permisos, módulos, subcuentas).
2. Si no, ¿le sirve a más clientes? Entonces es una mejora del núcleo
   (migración nueva + prueba + CHANGELOG).
3. Si es solo para él, va en `personal/` o en la app, **sin tocar el núcleo**.
