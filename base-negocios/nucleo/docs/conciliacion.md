# Conciliación bancaria (043_conciliacion) — módulo "conciliacion" (necesita "dinero")

**Idea:** comparar lo que dice el banco (estado de cuenta) con lo que dice el sistema
para cada cuenta de banco y cada mes. Lo que coincide queda "conciliado"; lo demás sale
como diferencia para emparejarlo o crear el movimiento que falta. **Nada se borra.**

## Pasos

1. **Cargar el estado de cuenta** — `importar_estado_cuenta(empresa, cuenta_banco, año, mes, datos, id_operacion)`
   (`conciliacion.conciliar`). La app convierte el CSV del banco en filas:
   ```json
   {"archivo":"bac_enero.csv","saldo_inicial_centavos":1000000,"saldo_final_centavos":883984,"dias_tolerancia":3,
    "filas":[{"fecha":"2026-01-22","descripcion":"PAGO ENEE","referencia":"ENEE-01","monto_centavos":-11500}]}
   ```
   - Monto con signo: **+ entra al banco, − sale**. Centavos enteros. Fechas del mismo mes.
   - Solo cuentas de dinero de tipo `banco`. Crea la conciliación del mes si no existe.
   - La misma fila cargada otra vez **no se repite** (huella: fecha, monto, referencia,
     descripción y la vez que se repite igual dentro del archivo). Reintento con el mismo
     `id_operacion` = la misma carga.
   - Si una fila está mal, no se guarda ninguna (el error dice el número de fila).
2. **Emparejamiento automático** (corre solo al cargar; `emparejar_conciliacion(conciliacion, dias?)`
   lo repite): mismo monto y fecha a ± N días (`dias_tolerancia`, 3 por defecto, 0 a 15);
   si hay varios candidatos gana el que coincide en referencia y después el de fecha más cercana.
3. **Manual** — `emparejar_manual(conciliacion, fila_banco, movimiento, motivo?)`: mismo monto,
   cualquier fecha hasta el fin del mes. Uno a uno (`YA_CONCILIADO` si ya estaba).
4. **Deshacer** — `deshacer_emparejamiento(pareja, motivo)`: motivo de 5 letras o más, solo con la
   conciliación abierta. La pareja queda "deshecha" con su motivo (no se borra).
5. **Crear lo que falta** (comisión, intereses) — `registrar_diferencia_banco(conciliacion, fila_banco, datos, id_operacion)`
   (`conciliacion.registrar`): `{"tipo":"comision_bancaria"|"interes"|"otro","cuenta":"6.1.02.05","descripcion":"...","fecha":"..."}`.
   - Sale del banco: Dr gasto / Cr banco. Entra: Dr banco / Cr ingreso. Con rastro de dinero
     (`operacion = 'diferencia_banco'`) y se empareja solo.
   - Cuentas: comisión 6.2.01.02, intereses que cobra el banco 6.2.01.01, intereses que paga
     4.2.01.01; "otro" = cuenta de detalle activa de ingresos, costos o gastos que no mueva un módulo
     (0.13.1, igual que usar un fondo: `CUENTA_INVALIDA`).
   - Fecha por defecto la del banco (mes abierto; si está cerrado, indique otra fecha).
6. **Cerrar el mes** — `cerrar_conciliacion(conciliacion, saldo_final?)`: solo un mes ya terminado,
   en orden (`CONCILIACION_EN_ORDEN`) y si cuadra (`CONCILIACION_NO_CUADRA` dice la diferencia):

   **saldo del banco = saldo del sistema − lo que está en el sistema y no en el banco + lo que está en el banco y no en el sistema**

   (todo al último día del mes; el saldo inicial de la cuenta de dinero es la apertura y no
   queda pendiente). Guarda la FOTO; cerrada ya no recibe filas ni cambios.
   Las partidas pendientes pasan solas al mes siguiente.
7. **Primera conciliación de una cuenta con historia** — `marcar_conciliados_anteriores(conciliacion, motivo)`:
   los movimientos de antes de ese mes que siguen sin pareja se dan por conciliados (tipo "anterior").

## Lecturas (`conciliacion.ver`: dueño, admin, contador)

- `ver_conciliacion(conciliacion)`: cerrada = la foto; abierta = en vivo. Trae saldo del sistema,
  `en_sistema_no_en_banco` y `en_banco_no_en_sistema` (listas y totales), saldo calculado,
  saldo del banco, diferencia, `cuadra`, `estado_cuenta_completo` (inicial + filas = final) y lo conciliado.
- Vista `v_conciliacion` (lista por cuenta y mes con filas conciliadas).
- El cajero y el vendedor no ven nada de bancos.

## Ejemplo (prueba 124, cifras a mano)

Sistema al 31/01: 1,000,000 − 11,500 − 100,000 + 50,000 = 938,500. Banco: 883,984.
Pendientes: depósito +50,000 (el banco lo acredita el 02/02); en el banco −5,750 (comisión) y +1,234
(intereses). 938,500 − 50,000 − 5,750 + 1,234 = 883,984: cuadra. Se crea la comisión (banco 932,750),
se cierra enero; en febrero se empareja el depósito a mano, se crean el cheque y los intereses y febrero
cierra sin pendientes en 913,984 = libros.

## Pendiente

- Emparejar varias filas contra un movimiento (por ejemplo varios cobros con tarjeta que el banco
  acredita juntos): hoy se hace con "crear lo que falta" o emparejando uno a uno.
- Un movimiento creado desde la conciliación no tiene función para anularlo (lo corrige el contador).
- Cuentas en otra moneda (USD).

## Sucursales (0.13.1)

Un usuario restringido por sucursal solo concilia bancos de sus sucursales o de toda la empresa
(sin sucursal): importar, emparejar (automático y a mano), deshacer, marcar anteriores, crear diferencias
y cerrar dan `SUCURSAL_NO_PERMITIDA` con el banco de otra sucursal.
