# Procedimientos

Formato de cada procedimiento: objetivo, responsable, qué se necesita,
pasos, registro (qué evidencia queda). Si un paso falla, **se detiene** y
se anota en el registro; no se improvisa.

---

## P-01 Instalar un cliente nuevo

**Objetivo:** dejar la empresa del cliente lista para trabajar.
**Responsable:** proveedor.
**Se necesita:** proyecto de Supabase del cliente, su cadena de conexión
(Settings > Database), ficha del cliente completa y firmada por el dueño.

1. Crear el proyecto en Supabase (región más cercana). Guardar la clave de la
   base en el gestor de contraseñas, **nunca** en archivos del proyecto.
2. Aplicar el núcleo (la cadena se escribe en la terminal, no se guarda en archivos):
   `export DATABASE_URL="postgresql://postgres:CLAVE@HOST:5432/postgres"`
   `bash herramientas/migrar.sh`
   Revisar que el nombre y servidor mostrados son los del cliente y escribir
   el nombre de la base para confirmar.
3. En Supabase > Authentication > Users, crear (o invitar) al dueño con el
   correo de la ficha. Igual para el usuario del proveedor.
4. Copiar `personal/ficha.ejemplo.json` a `personal/<cliente>.json`, llenarla.
5. Probar la ficha sin crear nada (misma terminal, con DATABASE_URL puesta):
   `bash herramientas/nuevo_cliente.sh --solo-validar personal/<cliente>.json`
6. Crearla: el mismo comando sin `--solo-validar`. Anotar el id de empresa.
7. Activar la licencia (SQL Editor de Supabase):
   `INSERT INTO public.licencia (empresa_id, vence_el) VALUES ('<id>', '2026-12-31');`
8. Entrar a la app con el dueño y revisar `mi_perfil`: rol dueño, licencia activa.

**Registro:** id de empresa, versión del núcleo (`SELECT * FROM version_esquema`),
fecha, quién instaló. La bitácora guarda la creación (rol `service_role`).

---

## P-02 Actualizar el núcleo de un cliente

**Objetivo:** llevar al cliente a la versión nueva sin perder datos.
**Responsable:** proveedor. **Cuándo:** fuera del horario del negocio.

1. En tu equipo: `bash herramientas/probar.sh` debe decir `TODO OK`.
2. Leer `CHANGELOG.md`: ¿hay "cambios que rompen"? Si sí, avisar al dueño
   y actualizar la app al mismo tiempo.
3. Ver qué se va a aplicar (con `DATABASE_URL` del cliente puesta):
   `bash herramientas/migrar.sh --solo-mostrar`
4. Aplicar: `bash herramientas/migrar.sh`.
   Confirma escribiendo el nombre de la base y **respalda solo** en
   `respaldos/` antes de aplicar. Si el respaldo falla, no aplica nada.
5. Revisar: `SELECT * FROM version_esquema;` y que
   `SELECT count(*) FROM verificar_bitacora();` dé 0.
6. Entrar con un usuario de prueba y registrar/anular un asiento de prueba
   solo si el dueño lo autoriza (queda en los libros).

**Si algo falla:** cada migración es todo-o-nada; la base queda en la última
que sí se aplicó. No editar migraciones a mano. Corregir con una migración
nueva, o restaurar (P-03) si hay daño.
**Registro:** salida de `migrar.sh`, nombre del respaldo, versión final.

---

## P-03 Respaldar y restaurar

**Objetivo:** poder volver atrás si se pierde o daña información.
**Responsable:** proveedor.

Respaldar (además de los respaldos automáticos de Supabase, si el plan los tiene):
1. `pg_dump --format=custom --file=respaldos/<cliente>_<fecha>.dump "postgresql://..."`
   (`migrar.sh` lo hace solo antes de cada actualización).
   pg_dump debe ser de la misma versión que el servidor o más nueva.
2. Copiar el archivo a un lugar seguro fuera del equipo (disco cifrado o
   nube privada). Los respaldos tienen datos del cliente: **nunca a git**
   (la carpeta `respaldos/` está ignorada).
3. Una vez al mes, probar que un respaldo se puede leer:
   `pg_restore --list archivo.dump | head`.

Restaurar (**solo con autorización escrita del dueño**):
1. Nunca encima de la base en uso. Restaurar en un proyecto o base NUEVA:
   `pg_restore --no-owner --dbname="postgresql://...base_nueva" archivo.dump`
2. Revisar: `SELECT count(*) FROM verificar_bitacora();` = 0, saldos y último
   número de asiento.
3. Cambiar la app para que apunte a la base restaurada.
4. Lo registrado después del respaldo se pierde: el dueño debe volver a
   registrarlo (los `id_operacion` evitan duplicados si la app reintenta).

**Nota:** la restauración completa en Supabase (que tiene sus propios
esquemas `auth`, `storage`) solo se ha probado en la base local. Antes de
necesitarla de verdad, hacer un simulacro en un proyecto de prueba.
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
   máximo 30). Sin eso el proveedor no ve asientos, saldos ni bitácora.
3. Revisar en solo lectura. El proveedor **no registra ni corrige
   movimientos**: le indica al dueño qué hacer (por ejemplo, anular y volver
   a registrar).
4. Si es un error del núcleo: escribir una prueba que lo reproduzca, corregir
   con una migración nueva, `probar.sh` en verde, anotar en CHANGELOG y
   actualizar (P-02).
5. Al terminar, pedir al dueño que revoque el acceso
   (`revocar_acceso_soporte`) o dejar que venza solo.

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
