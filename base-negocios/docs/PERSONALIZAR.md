# Personalizar para cada cliente

El **núcleo** (`nucleo/`) es igual para todos. Lo de cada cliente vive en
`personal/` y en los datos de su base. Así, una corrección del núcleo llega a
todos sin perder lo propio de nadie.

## Se cambia sin programar

| Qué | Dónde | Quién |
|---|---|---|
| Nombre, RTN, rubro, moneda, país, zona horaria | ficha del cliente (`personal/*.json`) al instalar | proveedor |
| Fecha de inicio en el sistema | ficha (`fecha_inicio`) | proveedor, con el dueño |
| Días al futuro permitidos para fechas (0-31, defecto 3) | ficha (`dias_futuro_max`) | proveedor |
| Módulos activos (contabilidad, ventas, inventario, compras) | ficha (`modulos`) | proveedor |
| Colores y logo | ficha (`tema`) | proveedor |
| Usuarios y su rol | app: `agregar_usuario_empresa` / `desactivar_usuario_empresa` | dueño |
| Qué puede hacer cada rol | app: `cambiar_permiso_rol` (con motivo) | dueño |
| Sucursales y cajas (punto de emisión SAR) | app: `crear_sucursal`, `crear_caja` | dueño |
| Subcuentas del catálogo | app: `crear_subcuenta` (solo de detalle) | dueño |
| Cerrar / reabrir meses | app | dueño (reabrir), admin (cerrar) |
| Acceso de soporte temporal | app: `otorgar_acceso_soporte` | solo el dueño |
| Tope de crédito que puede dar el admin; permitir inventario negativo | app: `configurar_empresa` | solo el dueño |
| Bodegas, categorías, unidades, campos extra de productos | app | dueño o admin |
| Productos y precios (con historial) | app | dueño o admin |
| Clientes y proveedores | app | dueño, admin (crédito hasta el tope); cajero y vendedor registran |
| Licencia (vencimiento, gracia, suspensión) | tabla `licencia` con la llave service_role | proveedor |

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

## Si un cliente pide algo que no cabe

1. Ver si se resuelve con lo de arriba (permisos, módulos, subcuentas).
2. Si no, ¿le sirve a más clientes? Entonces es una mejora del núcleo
   (migración nueva + prueba + CHANGELOG).
3. Si es solo para él, va en `personal/` o en la app, **sin tocar el núcleo**.
