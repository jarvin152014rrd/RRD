# Procedimientos

Formato de cada procedimiento: objetivo, responsable, qué se necesita,
pasos, registro (qué evidencia queda). Si un paso falla, **se detiene** y
se anota en el registro; no se improvisa.

**Regla de secretos (todos los procedimientos):**
- La clave de la base **nunca** se escribe en un comando, en un `export` ni
  en un archivo del proyecto (queda en el historial de la terminal y se ve
  con `ps`). Las herramientas reciben la cadena **sin clave** y la piden
  sin mostrarla (`read -s`); la guardan en un archivo temporal con permisos
  600 que se borra al terminar.
- Cadena de ejemplo (sin clave): `postgresql://postgres@db.<ref>.supabase.co:5432/postgres`
  (`<ref>` = referencia del proyecto: Settings > General de Supabase).
- Si la terminal ya tiene `DATABASE_URL` o `PGHOST/PGDATABASE`, la
  herramienta lo **avisa y lo muestra**: léalo antes de confirmar.
- Para confirmar se escribe un identificador único: la **referencia del
  proyecto de Supabase**, o el **nombre de la empresa** que ya está en la base.
- `SIN_PREGUNTAR=1` y `SIN_RESPALDO=1` solo valen con la base local de
  pruebas (el socket de `base-negocios/.pgdata`, o el que se declare en
  `BASE_LOCAL_SOCKET`). `localhost` o `127.0.0.1` NO cuentan como locales:
  por un túnel pueden ser la base de un cliente.

---

## P-01 Instalar un cliente nuevo

**Objetivo:** dejar la empresa del cliente lista para trabajar.
**Responsable:** proveedor.
**Se necesita:** proyecto de Supabase del cliente, su referencia y la clave de
la base (en el gestor de contraseñas), ficha del cliente firmada por el dueño,
gpg o age instalado (para el respaldo cifrado, ver P-03).

1. Crear el proyecto en Supabase (región más cercana). Guardar la clave de la
   base en el gestor de contraseñas, **nunca** en archivos del proyecto.
2. Aplicar el núcleo (pide la clave sin mostrarla):
   `bash herramientas/migrar.sh "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"`
   Revisar que el servidor mostrado es el del cliente y escribir la
   referencia del proyecto para confirmar. Pide también la frase del
   respaldo cifrado (o use la llave age, P-03).
3. En Supabase > Authentication > Users, crear (o invitar) al dueño con el
   correo de la ficha. Igual para el usuario del proveedor.
4. Copiar `personal/ficha.ejemplo.json` a `personal/<cliente>.json`, llenarla.
5. Probar la ficha sin crear nada:
   `bash herramientas/nuevo_cliente.sh --solo-validar personal/<cliente>.json "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"`
6. Crearla: el mismo comando sin `--solo-validar`. Anotar el id de empresa.
7. Activar la licencia (SQL Editor de Supabase):
   `INSERT INTO public.licencia (empresa_id, vence_el) VALUES ('<id>', '2026-12-31');`
8. Entrar a la app con el dueño y revisar `mi_perfil`: rol dueño, licencia activa.
9. Si el cliente ya traía contabilidad o existencias, seguir P-07 antes de
   activar inventario o compras.

**Registro:** id de empresa, versión del núcleo (`SELECT * FROM version_esquema`),
fecha, quién instaló. La bitácora guarda la creación (rol `service_role`).

---

## P-02 Actualizar el núcleo de un cliente

**Objetivo:** llevar al cliente a la versión nueva sin perder datos.
**Responsable:** proveedor. **Cuándo:** fuera del horario del negocio.

1. En tu equipo: `bash herramientas/probar.sh` debe decir `TODO OK`.
2. Leer `CHANGELOG.md`: ¿hay "cambios que rompen"? Si sí, avisar al dueño
   y actualizar la app al mismo tiempo.
3. Ver qué se va a aplicar:
   `bash herramientas/migrar.sh --solo-mostrar "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"`
4. Aplicar: el mismo comando sin `--solo-mostrar`. Confirma con la
   referencia del proyecto y **respalda cifrado** en `respaldos/` antes de
   aplicar. Si el respaldo falla, no aplica nada.
5. Revisar: `SELECT * FROM version_esquema;` y que
   `SELECT count(*) FROM verificar_bitacora();` dé 0.
6. (Desde 0.4.0) Revisar que no haya existencias en 0 con valor (datos de
   antes de 0.4.0): `SELECT * FROM inventario_saldo WHERE cantidad = 0 AND valor_centavos <> 0;`
   Si sale algo, se corrige solo en el siguiente movimiento de ese producto
   y bodega que lo deje en 0; mientras tanto esa bodega no se puede desactivar.
7. Entrar con un usuario de prueba y registrar/anular un asiento de prueba
   solo si el dueño lo autoriza (queda en los libros).

**Si algo falla:** cada migración es todo-o-nada; la base queda en la última
que sí se aplicó. No editar migraciones a mano. Corregir con una migración
nueva, o restaurar (P-03) si hay daño.
**Registro:** salida de `migrar.sh`, nombre del respaldo, versión final.

---

## P-03 Respaldar y restaurar (cifrado)

**Objetivo:** poder volver atrás si se pierde o daña información, sin que un
respaldo robado deje ver los datos del cliente.
**Responsable:** proveedor.

**Cómo se cifra** (lo hace la herramienta; nunca queda copia sin cifrar):
- **age con llave pública (recomendado):** una sola vez, `age-keygen -o llave_respaldos.txt`;
  guardar ese archivo (la llave PRIVADA) fuera del equipo, en el gestor de
  contraseñas o un USB cifrado. Para respaldar solo hace falta la llave
  pública (`age1...`, aparece en el archivo):
  `RESPALDO_AGE_DESTINATARIO=age1... bash herramientas/respaldar.sh "postgresql://..."`
  → `respaldos/<ref>_<fecha>.dump.age`. Sin la llave privada nadie lo abre.
- **gpg simétrico (AES256):** si no hay llave age, la herramienta pide una
  frase (2 veces, mínimo 12 letras). Guárdela en el gestor de contraseñas:
  sin ella el respaldo no se puede abrir. → `.dump.gpg`.
  Para automatizar: `RESPALDO_CLAVE_ARCHIVO=/ruta/frase.txt` (permisos 600).
- Sin age ni gpg: avisa y exige escribir `SIN CIFRAR`. No lo use con datos reales.

Respaldar (además de los respaldos automáticos de Supabase, si el plan los tiene):
1. `bash herramientas/respaldar.sh "postgresql://postgres@db.<ref>.supabase.co:5432/postgres"`
   (`migrar.sh` lo hace solo antes de cada actualización).
   pg_dump debe ser de la misma versión que el servidor o más nueva.
2. Copiar el archivo a un lugar seguro fuera del equipo (disco cifrado o
   nube privada). **Nunca a git** (la carpeta `respaldos/` está ignorada).
3. Una vez al mes, hacer el simulacro P-06.

Descifrar a mano (solo para revisar; mejor use `restaurar.sh`, que no deja copia descifrada):
- `.age`: `age -d -i llave_respaldos.txt archivo.dump.age | pg_restore --list | head`
- `.gpg`: `gpg --decrypt archivo.dump.gpg | pg_restore --list | head` (pide la frase)

Restaurar (**solo con autorización escrita del dueño**):
1. Nunca encima de la base en uso. Crear una base o proyecto NUEVO y vacío.
2. `bash herramientas/restaurar.sh respaldos/archivo.dump.gpg "postgresql://postgres@HOST:5432/base_nueva"`
   (para `.age`: `RESPALDO_AGE_IDENTIDAD=llave_respaldos.txt bash herramientas/restaurar.sh ...`).
   Se niega si la base de destino ya tiene el núcleo. Restaura todo o nada y
   al final muestra la versión, `verificar_bitacora()` (debe ser 0) y cuántas
   empresas, asientos y movimientos de kardex hay.
3. Comparar con el último reporte: saldos (`saldo_cuentas`), valor del
   inventario y CxP por proveedor.
4. Cambiar la app para que apunte a la base restaurada.
5. Lo registrado después del respaldo se pierde: el dueño debe volver a
   registrarlo (los `id_operacion` evitan duplicados si la app reintenta).

**Supabase real:** el respaldo completo incluye los esquemas propios de
Supabase (`auth`, `storage`...). Restaurar en un proyecto Supabase NUEVO
choca con esos esquemas, que ya existen. Lo probado hasta hoy es restaurar
en PostgreSQL 16 (prueba 56). Antes de necesitarlo de verdad, hacer el
simulacro P-06 en un proyecto de prueba de Supabase y anotar los pasos.
**Registro:** archivo usado, fecha, quién autorizó, resultado de la revisión.

---

## P-04 Atender una solicitud de soporte

**Objetivo:** ayudar al cliente sin ver ni tocar sus datos más de lo necesario.
**Responsable:** proveedor; autoriza el dueño.

1. El cliente reporta: qué hacía, qué mensaje salió (la CLAVE del error, ej.
   `PERIODO_CERRADO`) y cuándo. Buscar la clave en `error_catalogo`: muchas
   veces el "qué hacer" lo resuelve sin acceso.
2. Si hace falta ver cifras: el **dueño** da acceso desde la app
   (`otorgar_acceso_soporte`) con motivo y vencimiento corto (horas o días;
   máximo 30). Sin eso, el usuario proveedor de la app no ve asientos,
   saldos, bitácora, costos, compras ni clientes y proveedores.
3. Revisar en solo lectura. El proveedor **no registra ni corrige
   movimientos**: le indica al dueño qué hacer (por ejemplo, anular y volver
   a registrar).
4. Si es un error del núcleo: escribir una prueba que lo reproduzca, corregir
   con una migración nueva, `probar.sh` en verde, anotar en CHANGELOG y
   actualizar (P-02).
5. Al terminar, pedir al dueño que revoque el acceso
   (`revocar_acceso_soporte`) o dejar que venza solo.

**Lo que el sistema NO puede impedir (dicho con honestidad):** las reglas de
arriba valen para el usuario proveedor DENTRO de la app. Quien tiene la llave
`service_role` del proyecto o la clave `postgres` de la base (el proveedor
las usa para instalar y actualizar) **técnicamente puede leer todo**, y con
la clave `postgres` podría hasta apagar protecciones. Eso no se puede
bloquear con código; se controla así:
- **Contrato** firmado con el dueño: el proveedor solo usa esas llaves para
  instalar, actualizar, respaldar y restaurar (P-01, P-02, P-03), nunca
  para leer o cambiar datos del negocio.
- **Bitácora a prueba de manos**: todo cambio queda con su huella; P-05
  guarda la última huella fuera de la base para que no se pueda rehacer.
- El dueño puede **cambiar la clave de la base y la llave service_role**
  en Supabase cuando quiera (y debe hacerlo si cambia de proveedor).
- El proveedor guarda esas llaves solo en su gestor de contraseñas.

**Registro:** la bitácora guarda quién dio el acceso, el motivo, hasta cuándo
y cuándo se revocó. Anotar el caso y la solución.

---

## P-05 Revisión mensual

1. Licencias por vencer (`SELECT * FROM licencia ORDER BY vence_el`).
2. `SELECT * FROM verificar_bitacora();` en cada cliente: debe salir vacío.
   Si sale algo, **no tocar nada**, sacar un respaldo y avisar al dueño.
3. Guardar fuera de la base la huella de la última fila de bitácora de cada
   empresa (`SELECT empresa_id, max(secuencia), (array_agg(huella ORDER BY secuencia DESC))[1] FROM bitacora GROUP BY 1`).
   Así, aun alguien con acceso total no puede rehacer la cadena sin que se note.
4. Hacer el simulacro P-06 con el respaldo más reciente.

---

## P-06 Simulacro de restauración (mensual)

**Objetivo:** comprobar que los respaldos de verdad se pueden restaurar y
que lo restaurado es igual al original. **Responsable:** proveedor.

1. Respaldar el cliente (P-03) y anotar, en la base en uso, estas cifras:
   `SELECT codigo, saldo_final_centavos FROM saldo_cuentas('<empresa>', NULL, current_date) WHERE saldo_final_centavos <> 0;`
   `SELECT sum(valor_centavos) FROM inventario_saldo;`
   `SELECT sum(saldo_centavos) FROM v_cxp_proveedor;`
   `SELECT empresa_id, max(secuencia) FROM bitacora GROUP BY 1;`
2. Crear una base vacía de prueba (PostgreSQL 16 local, o un proyecto de
   Supabase de prueba) y restaurar ahí con `restaurar.sh` (P-03).
3. Confirmar: `verificar_bitacora()` = 0 y las mismas cifras del paso 1.
4. Registrar un asiento de prueba en la base restaurada: debe tomar el
   número siguiente y `verificar_bitacora()` seguir en 0.
5. Borrar la base de prueba (es una copia; los datos reales no se tocan).

La prueba automática `prueba_56_respaldo_restauracion.sh` hace estos mismos
pasos en local (gpg y age) cada vez que se corre `probar.sh`.
**Registro:** fecha, archivo, cifras comparadas, resultado.

---

## P-07 Activar inventario o compras en una empresa que ya tiene saldos

**Objetivo:** que el kardex y las cuentas por pagar empiecen cuadrados con la
contabilidad. **Responsable:** dueño (asientos) y proveedor (activar).

Si 1.1.03.01 (inventario) o 2.1.01.01 (proveedores) tienen saldo que el
módulo no conoce, activar el módulo da `MODULO_CON_SALDO`. Pasos:
1. Asiento manual que pasa ese saldo a 3.3.01.03 "Saldos de apertura":
   inventario: Dr 3.3.01.03 / Cr 1.1.03.01; proveedores: Dr 2.1.01.01 / Cr 3.3.01.03.
2. Activar el módulo (`modulo_activo`).
3. Cargar el detalle: existencias con `cargar_saldo_inicial` (Dr 1.1.03.01 /
   Cr apertura) y cada factura pendiente con `registrar_saldo_inicial_cxp`
   (Dr apertura / Cr 2.1.01.01).
4. Revisar que 3.3.01.03 quede en 0. Si no, la diferencia es lo que no se
   contó: el contador decide con el dueño (ajuste o capital).

Si la empresa usa otro código porque 3.3.01.03 ya era suyo, el mensaje de
error dice cuál (3.3.01.04...).

---

## P-08 Empezar a usar el módulo "dinero"

**Objetivo:** que cada lugar con dinero tenga su cuenta y su saldo real, con
rastro desde el primer día. **Responsable:** dueño (saldos), admin (cuentas),
proveedor (activar el módulo).

1. Activar el módulo `dinero` (ficha o `modulo_activo`). Si 1.1.02.04
   (diferencias de caja) tiene saldo que no explica, da `MODULO_CON_SALDO`.
2. Crear las cuentas de dinero (`crear_cuenta_dinero`): cada banco (el número
   completo solo sirve para enmascararlo: se guardan 4 dígitos), la caja chica
   con su fondo fijo, la caja fuerte o caja general. La caja de cada punto de
   emisión se crea sola al abrir su primer turno.
3. El dueño carga el saldo de cada una con `registrar_saldo_inicial_dinero`
   (con el estado de cuenta del banco o el conteo del efectivo, y su foto).
   Si ese dinero ya estaba en los libros en 1.1.01.01/02/03 (cuentas de la
   plantilla, sin rastro), usar `"contrapartida": "1.1.01.01"` para pasarlo;
   si no, va contra Saldos de apertura.
4. Revisar `donde_esta_mi_dinero`: "otras_cuentas_efectivo_sin_rastro" debe
   quedar vacío (o explicado por el contador).
5. Fijar los topes por puesto (`configurar_tope_rol`) y los días de alerta de
   depósitos en tránsito (`configurar_empresa`), crear categorías de gasto y
   pagos fijos.

**Registro:** fecha, cuentas creadas, saldos iniciales con su comprobante
(quedan en bitácora con usuario y hora).
