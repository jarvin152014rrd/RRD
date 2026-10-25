# Subir el sistema a Supabase (proyecto real, plan gratis)

Guía paso a paso para el dueño. Hágala con calma, en una computadora, en orden.
Tiempo: más o menos 1 hora la primera vez.

**Qué va a tener al final:** la base de datos en Supabase (con el núcleo 0.17.0), la empresa
creada con su usuario dueño, las 2 funciones de usuarios publicadas y la app en internet
(Netlify), instalada en su celular.

**Reglas de oro**
- La **contraseña de la base** y la **llave service_role / secret** son secretas: nunca en la app,
  nunca en un chat, nunca en un archivo que comparta. La **anon key** (o "publishable") sí es pública.
- Si algo sale en rojo, **no se quedó nada a medias**: lea la sección "Qué hacer si algo falla".

---

## Antes de empezar: preparar los archivos (en la computadora del proyecto)

En la carpeta `base-negocios`, abra una terminal y corra:

```bash
bash herramientas/armar_instalacion.sh
```

Debe decir `Listo: 14 partes del núcleo 0.17.0 en .../dist`. En la carpeta `dist/` quedan:
`instalar_supabase_parte01.sql` … `parte14.sql`, `verificar_instalacion.sql`, `actualizar_supabase_0.17.0.sql`
(solo para quien ya lo tenía instalado, ver más abajo) y `LEEME.txt`.
(El número de partes puede cambiar con versiones nuevas; siga el que diga.)

---

## 1. Crear la cuenta de Supabase

1. Entre a **https://supabase.com** y toque **Start your project**.
2. Regístrese con su correo (o con GitHub). Confirme el correo que le llega.

## 2. Crear el proyecto (gratis)

1. Toque **New project**. Si le pide una "organización", créela con el nombre de su negocio
   y elija el plan **Free**.
2. **Name:** el nombre del negocio (ej. `ferreteria-lopez`).
3. **Database Password:** toque **Generate a password** y **guárdela en un lugar seguro**
   (un gestor de contraseñas, o escrita en papel guardado bajo llave). La va a necesitar para
   los respaldos. No la mande por WhatsApp ni correo.
4. **Region:** la más cercana. Para Honduras y Centroamérica: **East US (North Virginia)**.
5. Toque **Create new project** y espere 1 o 2 minutos hasta que diga que está listo.

## 3. Copiar la Project URL y la anon key

1. Toque el botón **Connect** (arriba), o vaya al engranaje **Project Settings**.
2. **Project URL:** está en **Data API** (o en Connect > App Frameworks). Es como
   `https://abcd1234.supabase.co`. Cópiela en un papel o nota.
3. **anon key:** está en **API Keys**. Copie la que dice **anon public** (un texto largo que empieza
   con `eyJ`) o, si su proyecto solo muestra llaves nuevas, la **Publishable key** (`sb_publishable_…`).
4. **NO copie** la que dice `service_role` ni la `Secret key` (`sb_secret_…`).

## 4. Cerrar la puerta a desconocidos

1. Menú **Authentication** > **Sign In / Providers** (o **Settings**).
2. Apague **Allow new users to sign up** (permitir registrarse) y guarde.
   Así nadie se crea una cuenta solo; los usuarios los crea usted desde la app o el panel.

## 5. Instalar el núcleo (pegar las partes del SQL)

Repita esto con **cada parte, en orden** (01, 02, 03, …):

1. Menú izquierdo **SQL Editor** > **New query** (o el botón **+**).
2. En su computadora abra `dist/instalar_supabase_parte01.sql` con el Bloc de notas (Windows) o
   TextEdit (Mac). Seleccione todo (**Ctrl+A** / **Cmd+A**) y copie (**Ctrl+C** / **Cmd+C**).
3. Pegue en el SQL Editor (**Ctrl+V**) y toque **Run** (o **Ctrl+Enter**).
4. Si Supabase pregunta por "operaciones destructivas" o "potentially destructive", toque
   **Run this query**: es normal (las funciones traen la palabra DELETE/DROP por dentro).
5. Debe salir abajo una tabla que dice **Parte 1 de 14 lista** y "Siga con la parte 02".
6. Borre el texto del editor (o abra otro **New query**) y siga con la parte siguiente.

Cada parte tarda unos segundos. Si una sale en rojo, no siga: vea "Qué hacer si algo falla".
Si por error pega una parte dos veces, no pasa nada: lo ya instalado se salta.

## 6. Comprobar que quedó bien

1. **SQL Editor** > **New query**, pegue `dist/verificar_instalacion.sql` y **Run**.
2. Debe decir: **resultado = TODO BIEN**, **version = 0.17.0**, **migraciones = 53** (igual a
   "migraciones_esperadas"). Si dice "FALTAN PARTES", corra las que faltan en orden.

## 7. Crear el usuario dueño

1. Menú **Authentication** > **Users** > **Add user** > **Create new user**.
2. Escriba el **correo del dueño** y una **contraseña** (8 letras o más). Marque **Auto Confirm User**.
3. Toque **Create user**.
4. Toque el usuario en la lista y copie su **User UID** (un texto como
   `6d914f3e-20f7-4526-92ce-a3b6c99ae7b8`).

## 8. Crear la empresa (parte "primer cliente")

1. Arme el archivo con la ficha del cliente y el User UID del paso 7, de una de estas dos formas:
   - En la terminal: `bash herramientas/exportar_supabase.sh clientes/<cliente>/ficha.json <User UID>`
   - En el Armador: **Clientes** > **Exportar para Supabase** > pegue el User UID > **Descargar SQL**.
   Queda `dist/instalar_supabase_primer_cliente_<cliente>.sql`. (Si no puso el User UID, ábralo y
   cambie `PEGUE-AQUI-EL-ID-DEL-DUENO` por el User UID, entre las comillas.)
2. **SQL Editor** > **New query** > pegue el archivo completo > **Run**.
3. Debe salir **Empresa creada** con el id de la empresa, el nombre y la fecha de la licencia.
   Anote el id de la empresa en la ficha (`negocio.empresa_id`).

## 9. Publicar las 2 funciones de usuarios (Edge Functions)

Sirven para **agregar usuarios** con clave temporal y **cerrar la sesión de alguien a distancia**.
La llave secreta queda dentro de Supabase; la app nunca la ve.

1. Menú **Edge Functions** > **Deploy a new function** > **Via Editor**.
2. **Nombre exacto:** `crear-usuario` (con guion, en minúsculas).
3. Borre el ejemplo que trae el editor. Abra `supabase/functions/crear-usuario/index.ts` con el
   Bloc de notas, copie todo y péguelo.
4. Toque **Deploy function**. Deje **Verify JWT** encendido (viene así).
5. Repita con el nombre **`cerrar-sesion-remota`** y el archivo
   `supabase/functions/cerrar-sesion-remota/index.ts`.
6. No hay que poner llaves: Supabase les da solas `SUPABASE_URL` y la llave de servicio.

Si el panel no le deja (cambian las pantallas), use la terminal (necesita Node):
```bash
npx supabase login
npx supabase functions deploy crear-usuario --project-ref <REF>
npx supabase functions deploy cerrar-sesion-remota --project-ref <REF>
```
(`<REF>` es la parte `abcd1234` de su Project URL. Córralo dentro de `base-negocios`.)

## 10. Armar la app con su URL y su anon key

En la terminal, dentro de `base-negocios`:

```bash
bash herramientas/armar_app.sh <cliente> https://abcd1234.supabase.co <anon key>
```

Queda la carpeta `dist/app-<cliente>/`. Si por error pega la llave secreta, la herramienta se niega.

## 11. Subir la app a Netlify (gratis)

1. Entre a **https://app.netlify.com** y cree su cuenta.
2. **Add new site** (o **Add new project**) > **Deploy manually**.
3. **Arrastre la carpeta** `dist/app-<cliente>` completa al recuadro.
4. Sale un enlace como `https://nombre-raro-123.netlify.app`. Para cambiar el nombre:
   **Site configuration** > **Change site name**.
5. Para actualizar la app más adelante: arme la carpeta otra vez (paso 10) y en Netlify,
   **Deploys** > arrastre la carpeta nueva.
6. (Recomendado) En Supabase, **Authentication** > **URL Configuration** > **Site URL**: pegue su
   enlace de Netlify y guarde.
7. (Opcional, más seguro) En Supabase, **Edge Functions** > **Secrets** > agregue
   `ORIGENES_PERMITIDOS` = su enlace de Netlify (ej. `https://ferreteria-lopez.netlify.app`).

## 12. Abrirla en el celular e instalarla

1. Abra el enlace de Netlify en el celular.
2. **Android (Chrome):** menú **⋮** > **Instalar app** (o "Agregar a pantalla principal").
   **iPhone (Safari):** botón **Compartir** > **Agregar a inicio**.
3. Entre con el correo y la contraseña del dueño (paso 7).
4. Pruebe: **Ajustes > Usuarios > Agregar usuario** (cree un vendedor de prueba), entre con él en
   otro equipo, y desde el dueño toque **Cerrar sesión** en ese usuario: el otro equipo debe
   pedir entrar de nuevo.

---

## Actualizar de 0.17.0 a 0.18.0 (si YA lo tenía instalado) — precio mayorista, garantías, cheques y antigüedad

Si su Supabase ya tiene la 0.17.0, **no** vuelva a pegar las partes. Solo se pega **un archivo** (unos 175 KB).
Los datos de su negocio no se tocan.

1. **Haga un respaldo primero** (vea "Respaldos" más abajo).
2. En la carpeta `base-negocios`, en una terminal: `bash herramientas/armar_instalacion.sh`
   En `dist/` aparece **`actualizar_supabase_0.18.0.sql`**.
3. Supabase > **SQL Editor** > **New query** (arriba a la derecha: rol **postgres**).
4. Abra el archivo con el Bloc de notas, **Ctrl+A**, **Ctrl+C**, péguelo en el editor (**Ctrl+V**) y toque **Run**.
   Si pregunta por "operaciones destructivas", toque **Run this query** (es normal).
5. Abajo debe salir: **ACTUALIZADO A 0.18.0**, **version = 0.18.0** y **migraciones = 54**.
6. Suba la app nueva (0.12.0) a Netlify (pasos 10 y 11). La app vieja sigue funcionando mientras tanto.

Si sale un error en rojo, **no se cambió nada**:

| Lo que sale | Qué hacer |
|---|---|
| `FALTA_VERSION_ANTERIOR ... 053 (núcleo 0.17.0)` | Su base no tiene la 0.17.0. Pegue primero `actualizar_supabase_0.17.0.sql` y después este. |
| `FALTA_NUCLEO` | Esa base no tiene el sistema. Haga la instalación completa (paso 5). |
| `PAQUETE_VIEJO` o `MIGRACION_DISTINTA` | No siga. Avise a su proveedor. |
| `ROL_EQUIVOCADO` | Elija el rol **postgres** arriba a la derecha y vuelva a correr. |

Si lo pega dos veces no pasa nada: la segunda vez dice igual **ACTUALIZADO A 0.18.0**.

## Actualizar de 0.16.0 a 0.17.0 (versión anterior) — fotos de productos

Si su Supabase ya tiene la versión 0.16.0 (ya pegó `actualizar_supabase_0.16.0.sql` o instaló las 14 partes de
0.16.0), **no** vuelva a pegar las partes. Solo hay que pegar **un archivo**. Tarda unos segundos y los datos de su
negocio no se tocan. Las fotos quedan **apagadas**: nada cambia hasta que usted las encienda.

1. **Haga un respaldo primero** (vea "Respaldos" más abajo). Es por si acaso.
2. En la computadora del proyecto, en la carpeta `base-negocios`, abra una terminal y corra:
   `bash herramientas/armar_instalacion.sh`
   En la carpeta `dist/` aparece el archivo **`actualizar_supabase_0.17.0.sql`**.
3. Entre a Supabase > **SQL Editor** > **New query** (revise que arriba a la derecha diga el rol **postgres**).
4. Abra `actualizar_supabase_0.17.0.sql` con el Bloc de notas, seleccione todo (**Ctrl+A**), copie (**Ctrl+C**),
   péguelo en el editor (**Ctrl+V**) y toque **Run**.
5. Si Supabase pregunta por "operaciones destructivas", toque **Run this query** (es normal).
6. Abajo debe salir: **resultado = ACTUALIZADO A 0.17.0**, **version = 0.17.0**, **migraciones = 53** y
   **fotos_productos = LISTO**.
   - Si en **fotos_productos** dice **FALTA: ...**, la actualización SÍ quedó hecha; solo falta preparar el lugar
     de las fotos con unos clics: siga "Fotos de productos: crear el bucket y las políticas con clics" (abajo).
7. Suba la app nueva a Netlify (paso 10 y 11). La app vieja sigue funcionando mientras tanto (no muestra fotos).
8. Para usar fotos: en la app, **Ajustes > Mi negocio > Fotos de productos** > marque **Usar fotos de productos**
   y escriba el motivo. (También se puede encender desde la ficha del cliente o el Armador.)

Si sale un error en rojo, **no se cambió nada**:

| Lo que sale | Qué hacer |
|---|---|
| `FALTA_VERSION_ANTERIOR ... 052 (núcleo 0.16.0)` | Su base no tiene la 0.16.0. Pegue primero `actualizar_supabase_0.16.0.sql` (de la versión anterior; pídalo a su proveedor) y después este. |
| `FALTA_NUCLEO` | Esa base no tiene el sistema. Haga la instalación completa (paso 5), no la actualización. |
| `PAQUETE_VIEJO` | Su base ya tiene algo más nuevo. No haga nada y avise a su proveedor. |
| `MIGRACION_DISTINTA` | No siga. Avise a su proveedor. |
| `ROL_EQUIVOCADO` | Arriba a la derecha elija el rol **postgres** y vuelva a correr. |

Si la pega dos veces no pasa nada: la segunda vez dice igual **ACTUALIZADO A 0.17.0** sin cambiar nada.

### Fotos de productos: crear el bucket y las políticas con clics (solo si dice FALTA)

Normalmente el archivo de actualización (o la instalación) lo deja **LISTO** solo. Si `fotos_productos` dice
**FALTA**, Supabase no dejó hacerlo por SQL; hágalo así (una sola vez):

**A. El bucket (si dice "FALTA: crear el bucket")**
1. Menú izquierdo **Storage** > **New bucket**.
2. **Name:** `fotos-productos` (exacto, con guion).
3. **Public bucket:** APAGADO (muy importante: las fotos son privadas).
4. Encienda **Restrict file upload size** y ponga **1 MB**.
5. Encienda **Restrict MIME types** (o "Allowed MIME types") y escriba: `image/webp, image/jpeg`
6. Toque **Create bucket** (o **Save**).

**B. Las 4 políticas (si dice "FALTA: crear las políticas ...")**
En **Storage** > **Policies** (o en el bucket `fotos-productos` > **Policies**), en la sección **fotos-productos**
toque **New policy** > **For full customization** (o "Create a policy from scratch"). Haga una por cada fila;
en **Target roles** elija **authenticated**; copie el nombre y la definición EXACTOS; **Review** > **Save policy**.

| Policy name | Allowed operation | Policy definition (copie todo) |
|---|---|---|
| `fotos_productos_leer` | SELECT | `bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('leer')))` |
| `fotos_productos_subir` | INSERT | `bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))) AND public.ruta_foto_producto_valida(name)` |
| `fotos_productos_cambiar` | UPDATE | `bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('subir'))) AND public.ruta_foto_producto_valida(name)` |
| `fotos_productos_borrar` | DELETE | `bucket_id = 'fotos-productos' AND split_part(name, '/', 1) = ANY (ARRAY(SELECT public.empresas_fotos_productos('borrar'))) AND NOT public.foto_producto_en_uso(name)` |

(Si el panel agrega letras al final del nombre, como `fotos_productos_leer 1abc_0`, está bien. La revisión de
**LISTO** mira el nombre, la operación y que la definición sea esta: si una quedó distinta dice "FALTA: crear (o
corregir) ...": bórrela y créela otra vez copiando la definición completa.)

**C. Comprobar:** pegue otra vez `dist/verificar_instalacion.sql` > **Run**: **fotos_productos** debe decir **LISTO**.
En la app, el dueño ve en Ajustes > Mi negocio un aviso rojo si todavía falta algo.

---

## Actualizar de 0.15.0 a 0.16.0 (versión anterior)

Si usted ya instaló el sistema antes (con las partes 01 a 13 y la versión 0.15.0), **no** vuelva a pegar las
partes. Solo hay que pegar **un archivo**. Tarda unos segundos y los datos de su negocio no se tocan.

1. **Haga un respaldo primero** (vea "Respaldos" más abajo). Es por si acaso.
2. En la computadora del proyecto, en la carpeta `base-negocios`, abra una terminal y corra:
   `bash herramientas/armar_instalacion.sh`
   En la carpeta `dist/` aparece el archivo **`actualizar_supabase_0.16.0.sql`**.
3. Entre a Supabase > **SQL Editor** > **New query** (revise que arriba a la derecha diga el rol **postgres**).
4. Abra `actualizar_supabase_0.16.0.sql` con el Bloc de notas, seleccione todo (**Ctrl+A**), copie (**Ctrl+C**),
   péguelo en el editor (**Ctrl+V**) y toque **Run**.
5. Si Supabase pregunta por "operaciones destructivas", toque **Run this query** (es normal).
6. Abajo debe salir: **resultado = ACTUALIZADO A 0.16.0**, **version = 0.16.0**, **migraciones = 52**.
7. Listo. Después suba la app nueva a Netlify (paso 10 y 11). La app vieja sigue funcionando mientras tanto.

Si sale un error en rojo, **no se cambió nada**:

| Lo que sale | Qué hacer |
|---|---|
| `FALTA_VERSION_ANTERIOR` | Su base no tiene la 0.15.0 completa. Corra primero las partes que falten (paso 5) y repita. |
| `FALTA_NUCLEO` | Esa base no tiene el sistema. Haga la instalación completa (paso 5), no la actualización. |
| `PAQUETE_VIEJO` | Su base ya tiene algo más nuevo. No haga nada y avise a su proveedor. |
| `MIGRACION_DISTINTA` | No siga. Avise a su proveedor. |
| `ROL_EQUIVOCADO` | Arriba a la derecha elija el rol **postgres** y vuelva a correr. |

Si la pega dos veces no pasa nada: la segunda vez dice igual **ACTUALIZADO A 0.16.0** sin cambiar nada.

---

## Respaldos (IMPORTANTE: el plan gratis no los deja descargar)

El plan gratis de Supabase **no tiene respaldos que usted pueda descargar**. Haga uno a mano
**cada semana** (y antes de cualquier cambio grande) con `herramientas/respaldar.sh`
(ver `docs/PROCEDIMIENTOS.md`, P-03). Necesita la **contraseña de la base** (paso 2) y la cadena
de conexión del botón **Connect** > **Session pooler** (la "Direct connection" del plan gratis
solo funciona con IPv6, que muchas casas no tienen). Guarde los respaldos cifrados en dos lugares
(computadora + memoria USB o nube). Sin respaldo, si algo se pierde, no hay cómo recuperarlo.

Otros límites del plan gratis: si **nadie usa** el proyecto por 7 días, Supabase lo **pausa**
(se reactiva desde el panel con **Restore project**); 500 MB de base de datos.

---

## Qué hacer si algo falla

| Lo que sale | Qué significa | Qué hacer |
|---|---|---|
| `FALTA_PARTE_ANTERIOR` | Se saltó una parte. | Corra la parte que dice el mensaje y luego esta. |
| `ROL_EQUIVOCADO` | El SQL Editor no está como "postgres". | Arriba a la derecha del editor elija el rol **postgres** y vuelva a correr. |
| `NO_ES_SUPABASE` | No es un proyecto de Supabase. | Use el SQL Editor de su proyecto de Supabase. |
| `MIGRACION_DISTINTA` | Esa base tiene otra versión del mismo archivo. | No siga. Avise a su proveedor. |
| `PAQUETE_VIEJO` | La base ya tiene un núcleo más nuevo. | Arme el paquete con la versión actual (paso "Antes de empezar"). |
| El editor dice que el texto es muy grande, o se queda pensando y da "timeout" | La parte es muy grande para su conexión. | Arme partes más chicas: `MAX_KB=100 bash herramientas/armar_instalacion.sh` y siga desde la parte que falló (lo ya instalado se salta). |
| `WARNING: no privileges could be revoked for "public"` | Aviso normal de Supabase. | Nada. |
| `FALTA_ID_DUENO` | No pegó el User UID. | Cambie `PEGUE-AQUI-EL-ID-DEL-DUENO` por el User UID (paso 7). |
| `USUARIO_NO_EXISTE` | Ese User UID no está en Authentication > Users. | Cópielo otra vez, completo. |
| `YA_CREADA` | La empresa ya estaba creada. | Nada: no se cambió nada. |
| `FALTA_NUCLEO` / `FALTAN_PARTES` | No terminó el paso 5. | Corra las partes que faltan. |
| `FICHA_INVALIDA` | Un dato de la ficha está mal. | Corrija la ficha (el mensaje dice cuál) y exporte otra vez. |
| La app dice "Correo o contraseña incorrectos" | Clave mal escrita o usuario sin confirmar. | En Authentication > Users revise el correo; si dice "Waiting for verification", créelo otra vez con **Auto Confirm User**. |
| La app dice "No hay conexión con el servidor" con internet | URL o anon key mal copiadas, o proyecto pausado. | Revise el paso 3 y arme la app otra vez (paso 10); en Supabase toque **Restore project** si está pausado. |
| "Agregar usuario" o "Cerrar sesión" falla con "No hay conexión" | Las funciones no están publicadas o tienen otro nombre. | Paso 9: los nombres deben ser exactamente `crear-usuario` y `cerrar-sesion-remota`. Si puso `ORIGENES_PERMITIDOS`, debe ser igual a su enlace de Netlify (con `https://`, sin `/` al final). |
| `LIMITE_CONTRATO` al agregar usuario | Llegó al máximo de su plan. | Desactive a alguien o pida ampliación al proveedor. |
| Un reporte grande tarda y da error de tiempo | Supabase corta las consultas de la app a los 8 segundos. | En el SQL Editor corra una vez: `ALTER ROLE authenticated SET statement_timeout = '20s';` |
| No puedo borrar un usuario en Authentication > Users | Ese usuario tiene historial en el negocio (nada se borra). | Desactívelo desde la app (Ajustes > Usuarios > Desactivar). |
| "Security Advisor" de Supabase muestra avisos | Revisa reglas genéricas. | No toque los botones de "arreglar": la seguridad del núcleo ya está hecha a propósito. Pregunte a su proveedor. |

---

## Lista de verificación final

- [ ] Contraseña de la base guardada en lugar seguro (no en el celular sin clave, no en chats).
- [ ] "Allow new users to sign up" apagado (paso 4).
- [ ] `verificar_instalacion.sql` dice **TODO BIEN**, versión **0.17.0**, **53** migraciones y **fotos_productos = LISTO**.
- [ ] El dueño existe en Authentication > Users (confirmado).
- [ ] La empresa salió con **Empresa creada** y la licencia con su fecha.
- [ ] Edge Functions `crear-usuario` y `cerrar-sesion-remota` publicadas (Verify JWT encendido).
- [ ] La app en Netlify abre, el dueño entra y ve "Mi negocio hoy".
- [ ] Agregar un usuario de prueba funciona y "Cerrar sesión" lo saca de su otro equipo.
- [ ] La app quedó instalada en el celular.
- [ ] La llave service_role / secret **no** está en ningún archivo de la app ni en Netlify.
- [ ] Primer respaldo hecho y guardado en dos lugares; recordatorio semanal puesto.

---

## Para el técnico: diferencias entre el simulador local y Supabase real

Revisadas en la etapa 6 (núcleo 0.15.0). Se probó el paquete en un "mini Supabase" local
(`bash herramientas/probar.sh --paquete`): rol dueño **sin superusuario** (como `postgres` en
Supabase), esquema `auth` de otro dueño, `auth.uid()` con la definición de Supabase, pgcrypto en
`extensions`, cada parte en **una sola petición** como el SQL Editor; las pruebas pasan encima (140 en 0.17.0).
No se pudo probar con la imagen oficial `supabase/postgres` (Docker Hub respondió 429 y el espejo
de AWS estaba bloqueado desde este entorno) ni contra un proyecto real (sin red a supabase.co).

| Tema | Simulador | Supabase real | Qué se hizo |
|---|---|---|---|
| Roles anon/authenticated/service_role, esquema auth, auth.uid() | Los crea `simular_supabase.sql` | Ya existen | El paquete NO los crea; revisa que existan (`NO_ES_SUPABASE`). |
| Extensiones | — | pgcrypto en `extensions` | El núcleo no usa pgcrypto: `sha256()`, `md5()` y `gen_random_uuid()` son de PostgreSQL. Nada que ajustar. |
| Dueño de tablas y funciones | superusuario | `postgres` (sin superusuario) | Todo lo crea quien corre el SQL Editor (`postgres`). Probado con un rol sin superusuario: todo pasa. Ninguna tabla usa FORCE RLS (el dueño lee sus tablas desde SECURITY DEFINER). |
| `REVOKE CREATE ON SCHEMA public FROM PUBLIC` (001) | se aplica | `postgres` no es dueño de `public`: solo un WARNING | Inofensivo (anon/authenticated no pueden crear objetos por la API). |
| Permisos por defecto "generosos" en public | imitados | `ALTER DEFAULT PRIVILEGES FOR ROLE postgres` | 001 los quita para lo que crea `postgres` (verificado: anon no tiene ningún permiso en public/interno). |
| `auth.sessions` desde SECURITY DEFINER (048) | legible | `postgres` normalmente puede leerla | Si no puede, el núcleo usa el `iat` (plan B de 0.13.1). |
| Revocar sesiones de otro usuario | borrar fila | `auth.admin.signOut()` pide el token DEL usuario | Nueva `revocar_sesiones_auth` (051), solo service_role, con doble candado; si no deja borrar devuelve -1 y el cierre por base sigue valiendo. |
| FK `usuario_empresa.user_id → auth.users` | — | `postgres` tiene REFERENCES | Un usuario con historial no se puede borrar en el panel (a propósito): se desactiva. |
| API (PostgREST) | emulador | Solo expone `public` (y `graphql_public`) | `interno` nunca se expone. Cada parte hace `NOTIFY pgrst, 'reload schema'`. Todas las tablas de public tienen RLS. |
| Tiempo máximo por consulta | sin límite | `authenticated` 8 s | Documentado arriba; se sube con `ALTER ROLE` si hace falta. |
| Filas por lectura | sin límite | `max_rows` 1000 | RIESGO anotado en PENDIENTES: una lista de más de 1000 filas (ej. más de 1000 productos) llegaría cortada sin aviso. Hoy las listas grandes van por funciones con su propio límite; revisar las lecturas directas antes de clientes grandes. |
| Transacción | `migrar.sh`: una por archivo | SQL Editor: el texto entero en una | Cada parte es todo-o-nada; se probó así (`sql_una_peticion.py`). |
| Huella de migraciones | `migrar.sh` | paquete | Misma tabla `interno._migraciones` y misma sha256: después se puede seguir con `migrar.sh`. |
| Llaves nuevas (`sb_publishable_`, `sb_secret_`) | — | proyectos nuevos | La app acepta la publishable; las funciones mandan la secreta solo en `apikey` si no es JWT; `armar_app.sh` rechaza llaves secretas. |
| Actualizar una versión | `migrar.sh` | `actualizar_supabase_<versión>.sql` | Solo las migraciones nuevas, en una petición, con la misma huella; revisa que esté la anterior (`FALTA_VERSION_ANTERIOR`). Probado desde 0.15.0 instalado por partes (prueba 135) y de 0.16.0 a 0.17.0 (prueba 140). |
| Storage (0.17.0, fotos) | `storage.buckets` / `storage.objects` mínimos (`simular_supabase.sql`, `mini_supabase.sql`); el servidor de la demo imita subir, bajar y borrar con la fila COMO el usuario | El rol `postgres` del SQL Editor normalmente puede insertar en `storage.buckets` y crear políticas en `storage.objects` (Supabase lo documenta así) | La 053 lo intenta por SQL; si Supabase no lo deja (permisos que cambian), NO falla: `estado_fotos_storage()` y `verificar_instalacion.sql` dicen qué falta y arriba están los clics (prueba 140 prueba los dos casos). NO probado contra un Supabase real. |
