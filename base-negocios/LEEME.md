# Base de Negocios — Núcleo

Base para programas de administración de negocios (Honduras, lempiras).
La app será una PWA (página web instalable) y los datos vivirán en Supabase
(PostgreSQL). **Toda la lógica de dinero corre en el servidor**, dentro de
funciones SQL que guardan todo o nada. El navegador solo muestra y llama
esas funciones.

Versión del núcleo: ver `VERSION_NUCLEO` (hoy 0.1.0, etapa 1).

## Carpetas

```
base-negocios/
├── VERSION_NUCLEO          versión del núcleo
├── nucleo/                 IGUAL para todos los clientes (no se edita por cliente)
│   ├── sql/migraciones/    cambios a la base, numerados: 001_, 002_, ...
│   └── pruebas/            pruebas automáticas + simulador de Supabase
├── personal/               lo propio de cada cliente (ficha, tema, plantillas)
├── app/                    aquí irá la PWA
└── herramientas/
    ├── probar.sh           corre todas las pruebas
    └── migrar.sh           aplica migraciones pendientes a una base
```

Qué hace cada migración:

| Archivo | Contenido |
|---|---|
| 001_base | empresa, sucursal, caja (punto de emisión), roles, permisos, usuarios, módulos, licencia |
| 002_bitacora | bitácora de auditoría (solo agregar) y bloqueo de borrados |
| 003_catalogo_cuentas | catálogo de cuentas NIIF para PYMES |
| 004_periodos | meses contables: cerrar y reabrir |
| 005_asientos | asientos de partida doble: registrar y anular |
| 006_seguridad | RLS (cada quien ve solo su empresa) y permisos |
| 007_instalacion | crear una empresa nueva lista para trabajar |

## Cómo correr las pruebas (un comando)

```bash
bash base-negocios/herramientas/probar.sh
```

Levanta un PostgreSQL 16 local en `base-negocios/.pgdata` (no se sube a git),
crea una base vacía, aplica todo y corre cada prueba en su propia copia.
Muestra `OK` o `FALLA` por prueba y al final `RESULTADO: TODO OK`.
Si algo falla, termina con error (código distinto de 0).

## Reglas de oro

1. **Nada se borra ni se edita.** Un error se corrige con un contra-asiento
   (`anular_asiento`) que guarda motivo, usuario y fecha. Ni el
   administrador de la base puede borrar asientos ni la bitácora.
2. **Dinero en centavos enteros.** L 115.00 se guarda como `11500`.
   Nunca decimales para dinero. Las cantidades sí pueden tener fracciones.
3. **Todo o nada.** Si una parte de una operación falla, no se guarda nada.
4. **Cada operación lleva un `id_operacion` (uuid).** Si se manda dos veces
   (reintento o sin internet), se guarda una sola vez.
5. **Debe = Haber, siempre.** Lo revisa la función y además la base al confirmar.
6. **Mes cerrado no recibe asientos.** Reabrir exige permiso y motivo.
7. **Cada quien ve solo su empresa** (RLS) y solo hace lo que su rol permite.
8. **Licencia vencida = solo lectura.** Consultar y exportar nunca se bloquea.
9. **El proveedor instala y actualiza, pero no registra movimientos.**
10. **Las migraciones solo van hacia adelante.** Una migración ya aplicada no
    se edita: se crea otra con el número siguiente (`migrar.sh` lo vigila).
11. **Fechas:** la fecha contable (la que cuenta para los libros) es aparte
    de la hora de registro, que la pone el servidor. Zona: America/Tegucigalpa.

## Funciones que usará la app (RPC)

| Función | Para qué | Permiso |
|---|---|---|
| `registrar_asiento(empresa, fecha, descripcion, lineas, id_operacion, sucursal?)` | registrar un asiento | asientos.registrar |
| `anular_asiento(asiento, motivo, id_operacion?, fecha?)` | contra-asiento | asientos.anular |
| `cerrar_periodo(empresa, año, mes)` | cerrar mes | periodos.cerrar |
| `reabrir_periodo(empresa, año, mes, motivo)` | reabrir mes | periodos.reabrir |
| `cambiar_permiso_rol(empresa, rol, permiso, otorgar)` | editar permisos | permisos.editar |
| `crear_empresa_inicial(nombre, rtn, dueño, proveedor?)` | instalar cliente | solo service_role |

Formato de `lineas`:
`[{"cuenta":"1.1.01.01","debe":11500},{"cuenta":"4.1.01.01","haber":10000},{"cuenta":"2.1.02.01","haber":1500}]`

Los errores empiezan con una palabra clave fácil de traducir en la app:
`NO_CUADRA`, `SIN_PERMISO`, `PERIODO_CERRADO`, `LICENCIA_VENCIDA`,
`MODULO_INACTIVO`, `YA_ANULADO`, `CUENTA_INVALIDA`, `LINEA_INVALIDA`,
`FALTA_MOTIVO`, `NO_PERTENECE`, `SIN_SESION`, `PROHIBIDO`.
