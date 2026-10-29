# Vender sin internet — guía sencilla

Para el cajero y para el dueño. App 0.14.0 (núcleo 0.20.0). El diseño completo está en `docs/SIN_INTERNET.md`.

## Antes (con internet): preparar el equipo

Hay que hacerlo **una vez en cada computadora o celular** que va a vender sin internet, con el turno de caja abierto.

1. Entre a la app con su usuario.
2. Vaya a **Ajustes > Sin internet**.
3. Ponga un nombre al equipo (por ejemplo "Caja 1 - computadora") y toque **Preparar para trabajar sin internet**.
4. Debe decir **"Este equipo guarda las ventas de forma segura"** y cuántos números quedan reservados.

Si dice algo en rojo:
- **Modo incógnito o privado:** abra la app en una ventana normal.
- **iPhone o iPad:** instale la app en la pantalla de inicio (Compartir > Agregar a inicio) y prepárela desde ahí.
- **"La hora de este equipo está mal":** corrija la fecha y hora del equipo.
- **"Su usuario no tiene permiso":** el dueño lo da en Ajustes > Sin internet ("Los cajeros pueden vender sin internet").

Mientras hay internet, el equipo actualiza solo los precios cada 15 minutos.

## Cuando se va el internet (cajero)

- Arriba sale la barra **"Sin conexión: N ventas guardadas en este equipo"**. Siga vendiendo en **Vender > Nueva venta**.
- Se cobra en **efectivo** o con **transferencia**. **Con tarjeta no.**
- Con transferencia **escriba el número de referencia** (y el banco si lo sabe). Sin referencia no deja cobrar.
- Al cobrar, la venta se guarda primero en el equipo y sale el comprobante **"Emitida sin conexión"**: imprima el
  **original y la copia** (la copia se queda en la caja).
- Si cierra la app sin internet, al abrirla de nuevo en ese mismo equipo entra sola y las ventas siguen ahí.
- **No se puede salir** de la app con ventas sin subir y sin internet: espere a que vuelva.
- Hay un tope por venta y por turno sin internet (lo pone el dueño). Sin internet no hay crédito, ni descuentos a mano,
  ni devoluciones, ni gastos.

## Cuando vuelve el internet

- Las ventas **suben solas**. La barra dice "Subiendo 3 de 8…" y después **"Todo subido"**.
- En **Vender > Ventas del día** cada venta del equipo dice **En el equipo**, **Subida** o **Con problema**.
- **Para cerrar el turno** hace falta internet: al cerrar, el equipo sube lo que falte y devuelve sus números.

## Lo que hace el dueño o el supervisor

- **Vender > Sin internet por resolver:** ventas que el servidor no pudo registrar solas (por ejemplo, un precio que no
  cuadra). El dinero ya se cobró: normalmente se **Registra como se hizo**. **Anular** deja el número anulado y el dinero
  como sobrante de caja hasta devolverlo. Siempre con motivo.
- **Dinero > Transferencias por confirmar:** revise el banco. **Llegó** (elige el banco) o **No llegó**: la venta queda
  como deuda del cliente o, si fue a Consumidor final, **del cajero** que la cobró. Si sale **"Referencia repetida"**,
  revise bien: puede ser la misma transferencia usada dos veces.
- **Ajustes > Sin internet:**
  - Reglas: cuántas horas sirven los precios, topes y tamaño del bloque de números.
  - **Equipos y números:** si se pierde o daña un equipo, **Desactivar**. Sus números quedan "por conciliar": revise las
    copias en papel, registre lo que falte y toque **Conciliar**.
  - **Ventas de otros usuarios** que quedaron en un equipo (por ejemplo, de un cajero que ya no trabaja): **Subirlas**,
    con motivo.
  - **Guardar respaldo de las ventas por subir:** un archivo con las ventas que siguen en el equipo (por si el equipo se
    va a dañar). Se sube desde otro equipo con "Subir un respaldo de otro equipo".

## Talonario de emergencia (si el sistema no se puede usar para nada)

Solo si el negocio tiene encendido el talonario (módulo de facturas de emergencia).

1. **Antes:** pregunte a su contador cómo pedir al SAR el CAI de un talonario de imprenta, con su **propio punto de
   emisión** (distinto al de las cajas).
2. El dueño o el administrador lo registra en **Vender > Talonario de emergencia > Registrar un talonario**.
3. Cuando no se puede usar el sistema, se escriben las facturas a mano en el talonario.
4. Después, en **Pasar una factura del talonario**: el número, la fecha de la copia, los productos y la forma de pago.
   El sistema revisa que el número sea del talonario, que no esté repetido, que el CAI estaba vigente y que el mes esté
   abierto. Compare el total con el de la copia.
5. Una factura arruinada: **Anular un número** (queda anulada en el libro de ventas).
6. La lista muestra cuántas van usadas, anuladas y libres, y los **números saltados** (páselos o anúlelos).
