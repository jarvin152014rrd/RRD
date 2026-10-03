# Impuestos como datos y servicios (026_impuestos_servicios)

## Impuestos (tabla `impuesto`, por empresa)

Código, nombre, porcentaje, clase (`gravado` | `exento` | `exonerado`), cuenta del impuesto por
pagar (ventas) y del crédito fiscal (compras y gastos), predeterminado, activo.

- Cada empresa nueva recibe los de su país (`interno.plantilla_impuesto`). **Honduras:** ISV15
  (15 %, predeterminado), ISV18 (18 %), EXENTO y EXONERADO (0 %); cuentas 2.1.02.01 y 1.1.04.01.
  Las empresas de antes recibieron los de Honduras (sus productos ya usaban esos códigos).
- `producto.tipo_impuesto` es el código de la tabla (antes una lista fija; los valores no cambiaron).
- `configurar_impuesto(empresa, datos, motivo)` (`impuestos.configurar`, solo el dueño): crea o
  cambia nombre, porcentaje, clase, cuentas, predeterminado, activo. El código no cambia nunca.
  Cambiar una tasa vale para lo que se registre después (cada línea de venta guarda la tasa que usó).
- La regla: `public.precio_con_tasa(precio, incluye, porcentaje, cantidad)` (la misma de 0.4.0 con la
  tasa como dato) y `public.precio_impuesto(empresa, precio, incluye, código, cantidad)`.
  `public.precio_isv` queda por compatibilidad (tasas de Honduras fijas).
- **Ventas:** calculan con la tabla y llevan cada impuesto gravado a SU cuenta por pagar.
- **Compras:** la tasa de cada línea sale de la tabla (`interno.tasa_isv` lee la de la empresa).
  El crédito fiscal sigue yendo a 1.1.04.01 (pendiente: cuenta por impuesto en compras).
- **Gastos:** `"impuesto":"ISV15"` en vez de `"isv_centavos"` calcula el crédito fiscal del total:
  total − round(total / (1 + tasa)). Ej. 115,000 → 15,000.

Otro país: el proveedor agrega su plantilla (`interno.plantilla_impuesto`) o el dueño crea los
impuestos con `configurar_impuesto`; el núcleo no cambia.

## Servicios

- `producto.tipo`: `bien` (defecto) | `servicio`. `empresa.permite_servicios` (defecto true; solo el dueño).
- Un servicio no mueve kardex (`mover_inventario` lo rechaza: `PRODUCTO_INVALIDO`), no tiene
  existencia ni bodega y no se bloquea por existencia. Impuesto igual que un bien.
- Unidades nuevas comunes: SERV, HORA, SES, MES.
- Costo estimado opcional (`"costo_estimado_centavos"` al crear o editar; tabla `servicio_costo`,
  solo la ve quien tiene `inventario.costos`): sirve para margen y comisiones; **nunca** genera asiento.
- Una venta mezcla bienes y servicios (taller: mano de obra + repuestos). La línea de servicio queda
  con costo 0 en los libros y su costo estimado aparte (`v_venta.utilidad_bruta_centavos` lo descuenta).
- Un bien con kardex no pasa a servicio; un servicio ya vendido no pasa a bien.
- `v_producto` muestra `tipo`, impuesto (nombre, porcentaje, clase) y costo estimado.
