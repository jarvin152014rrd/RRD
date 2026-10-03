-- =====================================================================
-- 008_catalogo_errores.sql  -  Catálogo de errores para la app
--
-- Todo error del núcleo empieza con una CLAVE en mayúsculas seguida de
-- dos puntos:  'NO_CUADRA: el debe (100) no es igual al haber (90)...'
-- La app toma la clave (lo que va antes de ":") y busca aquí el mensaje
-- sencillo para el usuario y qué hacer. Si no la encuentra, muestra el
-- texto original.
--
-- REGLA: una migración que use una clave nueva la agrega aquí con
-- INSERT (en su propio archivo). La prueba 17 falla si falta alguna.
-- =====================================================================

CREATE TABLE public.error_catalogo (
  codigo           text PRIMARY KEY CHECK (codigo ~ '^[A-Z][A-Z_]+$'),
  mensaje_usuario  text NOT NULL,
  que_hacer        text NOT NULL
);

INSERT INTO public.error_catalogo (codigo, mensaje_usuario, que_hacer) VALUES
  ('SIN_SESION',               'No ha iniciado sesión.',                                     'Entre con su correo y contraseña.'),
  ('NO_PERTENECE',             'Su usuario no pertenece a esta empresa.',                    'Revise que eligió la empresa correcta o pida acceso al dueño.'),
  ('SIN_PERMISO',              'Su rol no tiene permiso para hacer esto.',                   'Pida al dueño que le dé el permiso.'),
  ('LICENCIA_VENCIDA',         'El sistema está en modo solo lectura.',                      'Puede consultar y exportar. Para volver a registrar, renueve la licencia con su proveedor.'),
  ('MODULO_INACTIVO',          'Esta parte del sistema no está activa para su empresa.',     'Hable con su proveedor para activarla.'),
  ('PROHIBIDO',                'Esta acción no está permitida.',                             'Nada se borra ni se edita: para corregir use anular o desactivar.'),
  ('NO_PERMITIDO',             'Esta acción no se puede hacer sobre este registro.',          'Revise el registro elegido.'),
  ('NO_EXISTE',                'Lo que busca no existe.',                                     'Revise que el dato esté bien escrito o elija otro.'),
  ('YA_EXISTE',                'Ya existe un registro con ese código.',                       'Use otro código o busque el registro que ya existe.'),
  ('DATO_INVALIDO',            'Un dato no tiene el formato correcto.',                       'Revise lo que escribió y vuelva a intentar.'),
  ('FALTA_MOTIVO',             'Falta escribir el motivo.',                                   'Escriba el motivo (mínimo 5 letras) y vuelva a intentar.'),
  ('FALTA_DESCRIPCION',        'Falta la descripción.',                                       'Escriba de qué se trata la operación.'),
  ('FALTA_ID_OPERACION',       'La operación llegó sin su código interno.',                   'Vuelva a intentar. Si se repite, avise a soporte.'),
  ('NO_CUADRA',                'El asiento no cuadra: el debe y el haber no son iguales.',    'Revise los montos de cada línea.'),
  ('LINEA_INVALIDA',           'Una línea del asiento tiene datos incorrectos.',              'Revise montos (sin decimales en centavos, sin negativos) y que cada línea vaya al debe o al haber.'),
  ('CUENTA_INVALIDA',          'La cuenta elegida no se puede usar.',                         'Elija una cuenta de detalle activa del catálogo.'),
  ('YA_ANULADO',               'Este asiento ya fue anulado.',                                'No hace falta anularlo otra vez.'),
  ('FECHA_INVALIDA',           'La fecha no es válida.',                                      'Revise la fecha.'),
  ('FECHA_ANTERIOR_AL_INICIO', 'La fecha es anterior al inicio de la empresa en el sistema.', 'Use una fecha igual o posterior a la fecha de inicio.'),
  ('FECHA_MUY_FUTURA',         'La fecha está demasiado adelante.',                           'Use la fecha de hoy o una de los próximos días.'),
  ('PERIODO_CERRADO',          'El mes de esa fecha está cerrado.',                           'Use una fecha de un mes abierto o pida al dueño reabrir el mes.'),
  ('PERIODO_INVALIDO',         'El mes o el año no son válidos.',                             'Revise el mes (1 a 12) y el año.'),
  ('MES_NO_TERMINADO',         'Ese mes todavía no ha terminado.',                            'Ciérrelo a partir del día 1 del mes siguiente.'),
  ('MES_ANTERIOR_ABIERTO',     'Hay un mes anterior con movimientos que sigue abierto.',      'Cierre primero los meses en orden.'),
  ('REABRIR_EN_ORDEN',         'Hay meses posteriores cerrados.',                             'Reabra primero el último mes cerrado, de atrás para adelante.'),
  ('SUCURSAL_INVALIDA',        'La sucursal no existe o está desactivada.',                   'Elija una sucursal activa.'),
  ('SIN_SUCURSAL_ACTIVA',      'La empresa no tiene ninguna sucursal activa.',                'Active o cree una sucursal antes de registrar.'),
  ('ZONA_INVALIDA',            'La zona horaria no existe.',                                  'Use una zona como America/Tegucigalpa.'),
  ('FICHA_INVALIDA',           'La ficha del cliente tiene un error.',                        'Corrija el campo que indica el mensaje y vuelva a intentar.'),
  ('USUARIO_NO_EXISTE',        'No hay ninguna cuenta con ese correo.',                       'Pida a la persona que se registre primero y vuelva a intentar.');

ALTER TABLE public.error_catalogo ENABLE ROW LEVEL SECURITY;
CREATE POLICY leer ON public.error_catalogo FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.error_catalogo TO authenticated, service_role;
CREATE TRIGGER no_vaciar BEFORE TRUNCATE ON public.error_catalogo
  FOR EACH STATEMENT EXECUTE FUNCTION interno.prohibir_cambios('No se permite vaciar tablas.');
