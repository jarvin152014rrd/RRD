# Límites del contrato y solicitudes al proveedor (032_limites_ficha_proveedor)

## Límites (`limite_contrato`)

Por empresa: `usuarios`, `cajas`, `sucursales`, `bodegas`. `null` = sin límite
(así quedan las empresas de antes de 0.8.0).

- Los pone **solo el proveedor**: ficha del cliente (`"limites"`) con
  `nuevo_cliente.sh` o `aplicar_ficha.sh` (por dentro `aplicar_ficha`, llave
  service_role). El dueño y el admin no tienen cómo cambiarlos.
- Cuentan solo los **activos**. El usuario del **proveedor** no cuenta.
- Crear o **reactivar** uno más allá del límite: `LIMITE_CONTRATO: Llegaste al
  máximo de tu plan. Solicita una ampliación a tu proveedor. (cajas: 1 de 1)`.
  Lo revisa un trigger en `usuario_empresa`, `caja`, `sucursal` y `bodega`, así
  vale para toda RPC de crear o reactivar (`agregar_usuario_empresa`,
  `crear_caja`, `reactivar_caja`, `crear_sucursal`, `reactivar_sucursal`,
  `crear_bodega`, `reactivar_bodega` y las que vengan).
- Dos personas agregando a la vez: el candado de la fila de límites las pone
  en fila; la segunda ve lo que hizo la primera.
- **Nunca bloquea el trabajo diario ni borra nada.** Si el proveedor baja un
  límite por debajo de lo que ya existe, nada se desactiva; solo no se pueden
  agregar más (la vista previa lo avisa).
- Lo que el proveedor instala con su llave (crear la empresa) no tiene tope.

`mi_perfil()->'limites'`: `{"usuarios": {"limite": 5, "uso": 3}, "cajas": ...}`
para que la app muestre "3 de 5" y el botón "Solicitar ampliación".

`lista_clientes.sh` muestra uso/límite de cada cliente y marca con `(!)` a
quien use el 80 % o más de algún límite.

## Solicitudes al proveedor (`solicitud_proveedor`)

- `solicitar_al_proveedor(empresa, tipo, detalle, id_operacion)`: tipo
  `ampliacion` | `modulo` | `otro`; detalle de 5 a 1000 letras. Permiso
  `proveedor.solicitar` (dueño y admin). Funciona aun con la licencia vencida
  (para pedir la renovación). Reintento con el mismo `id_operacion` = la misma solicitud.
- La leen quienes tienen `proveedor.solicitar` y el proveedor con su llave
  (`lista_clientes.sh` cuenta las pendientes en la columna FUENTE).
- `responder_solicitud_proveedor(solicitud, 'atendida' | 'rechazada', respuesta)`:
  solo la llave del proveedor, una vez. El texto de la solicitud no cambia.
- **Pendiente:** no hay aviso automático (correo o mensaje) al proveedor; hoy
  las ve en `lista_clientes.sh`.

Permisos nuevos: `proveedor.solicitar` (dueño, admin).
