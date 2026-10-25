# Garantías (054_mayorista_garantias_cheques_antiguedad, núcleo 0.18.0) — módulo "ventas"

## Días de garantía y fecha de vencimiento

- `producto.dias_garantia` (1 a 3650; vacío = sin garantía). Se pone con `crear_producto` / `editar_producto`
  (`"dias_garantia": 90`, `null` la quita; `productos.editar`). `v_producto` la devuelve al final.
- Cada línea vendida guarda `venta_linea.garantia_dias` (los del producto en ese momento) y, **al emitirse la venta**,
  `garantia_hasta` = fecha de la venta + días. Una venta pendiente de aprobación la recibe al aprobarse (con la fecha
  de la aprobación). Después no se edita (`PROHIBIDO`). Un cambio de producto da su propia garantía a lo nuevo.
- `documento_venta` devuelve por línea `garantia_hasta` (dd/mm/aaaa) y `garantia_texto` ("Garantía hasta 25/01/2027").

## Reclamos (`garantia_reclamo`, historial `garantia_reclamo_evento`)

Estados: **recibido → en_revision → resuelto | rechazado**. Nada se borra; cada cambio queda en el historial y en la
bitácora (con su motivo). Cada reclamo es de la sucursal de su venta (un usuario limitado solo ve y trabaja los suyos).

| función | permiso | qué hace |
|---|---|---|
| `buscar_garantia(empresa, texto, solo_vigentes?)` | registrar, resolver o `ventas.ver` | líneas con garantía por factura, cliente o producto: `vigente`, `dias_restantes`, reclamos abiertos |
| `registrar_reclamo_garantia(empresa, {venta_id, linea, cantidad?, motivo, descripcion?, fecha?, autorizar_fuera_de_plazo?}, id_operacion)` | `garantias.registrar` | reclamo "recibido" |
| `cambiar_estado_reclamo(reclamo, 'en_revision' \| 'rechazado', nota, id_operacion)` | revisión: registrar o resolver; rechazo: `garantias.resolver` y motivo | |
| `resolver_reclamo_garantia(reclamo, datos, id_operacion)` | `garantias.resolver` | reparado, cambiado o devuelto |
| `documento_reclamo_garantia(reclamo)` | lectura | comprobante (la app lo imprime sin íconos ni emojis) |
| vista `v_garantia_reclamo` | lectura | reclamos con factura, producto, cliente y estado |

Permisos (los más simples): `garantias.registrar` (dueño, admin, cajero, vendedor) y `garantias.resolver` (dueño y
admin; también autoriza los reclamos fuera de plazo).

Reglas: venta emitida (una anulada no tiene garantía); línea con garantía (`GARANTIA_INVALIDA`); cantidad hasta lo
vendido menos lo devuelto; motivo obligatorio. **Fuera de plazo** (fecha del reclamo después de `garantia_hasta`):
`GARANTIA_VENCIDA`, salvo `"autorizar_fuera_de_plazo": "<motivo>"` de alguien con `garantias.resolver` (queda
`fuera_de_plazo`, quién y por qué). Un reclamo resuelto o rechazado ya no cambia.

### Resolver

```json
{"resolucion": "reparado", "nota": "Se cambió el interruptor",
 "costo_reparacion": {"cuenta_dinero_id": "...", "categoria_id": "...", "monto_centavos": 15000}}
{"resolucion": "cambiado", "cambio": {...como en registrar_devolucion; por defecto el mismo producto y cantidad...}}
{"resolucion": "devuelto", "destino": "dinero" | "saldo_favor", "cuenta_dinero_id": "..."}
```

- **reparado**: no mueve dinero por la venta; el costo de reparación (opcional) es un gasto normal (`registrar_gasto`,
  pide `gastos.registrar` y respeta su tope).
- **cambiado** y **devuelto**: usan la devolución de SIEMPRE (`registrar_devolucion`, pide `ventas.devolver`, tipos
  que permite el dueño, nota de crédito, inventario al costo, efectivo del turno propio, tope y aprobación), ligada al
  reclamo (`devolucion_id`). El motivo de la devolución dice "Garantía, reclamo #N".
- Todo junto o nada; un reintento con el mismo `id_operacion` devuelve lo mismo (las operaciones de adentro usan
  ids derivados, así no se duplican).

Nota: el producto que vuelve por garantía entra al inventario como cualquier devolución (si está dañado, se saca con un
ajuste de inventario).

Ejemplo (prueba 142): galón con 90 días vendido hoy: hasta hoy + 90. Venta del 10/01: venció el 10/04 y su reclamo
solo entra autorizado. Reparado con L 50.00 de costo: gasto aplicado desde el banco. Cambiado: entra un galón y sale
otro (inventario igual). Devuelto en dinero: salen L 450.00 del banco.
