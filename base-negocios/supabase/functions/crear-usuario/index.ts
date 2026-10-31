// =====================================================================
// Edge Function "crear-usuario"  (Supabase, Deno)  -  núcleo 0.15.0
//
// La llama la app (Ajustes > Usuarios > Agregar usuario) con el token de quien
// está usando la app. Pasos:
//   1. Revisa el token de quien llama (Supabase Auth: GET /auth/v1/user).
//   2. Con SU token (no con la llave secreta) pregunta a la base:
//      tiene_permiso('usuarios.administrar', empresa) y el límite de usuarios
//      del contrato (mi_perfil). Si no puede, no crea nada.
//   3. Crea el usuario en Supabase Auth con la llave service_role (sale de las
//      variables de entorno de la función; NUNCA va a la app ni a la respuesta).
//      Si el correo ya tenía cuenta, no le cambia la clave.
//   4. Lo agrega a la empresa con agregar_usuario_empresa, otra vez con el token
//      de quien llama: el núcleo aplica TODAS sus reglas (puestos, límite del
//      contrato, bitácora). Si el núcleo dice que no y el usuario lo acabamos
//      de crear en el paso 3, se borra (no queda una cuenta suelta).
//
// Recibe (JSON): { empresa_id, correo, nombre, rol, clave }
// Responde: lo que devuelve agregar_usuario_empresa + { ya_tenia_cuenta }.
// Errores: { message: "CLAVE: texto" } (la app los muestra con el catálogo).
//
// Variables de entorno (Supabase las pone solas al publicar la función):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
// Opcional: ORIGENES_PERMITIDOS = "https://mi-negocio.netlify.app" (coma entre
// varios). Sin ella responde a cualquier origen (la seguridad está en el token).
//
// Sin librerías: solo fetch, para que se pueda pegar en el editor del Dashboard.
// También corre en Node 22 (pruebas locales: app-pruebas/probar_funciones.mjs).
// =====================================================================

declare const Deno: any;
const leerEnv = (k: string): string =>
  ((globalThis as any).Deno ? Deno.env.get(k) : (globalThis as any).process?.env?.[k]) || '';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CORREO = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const PUESTOS = ['admin', 'cajero', 'vendedor', 'contador'];

function cabecerasCors(req: Request): Record<string, string> {
  const permitidos = leerEnv('ORIGENES_PERMITIDOS').split(',').map((x) => x.trim()).filter(Boolean);
  const origen = req.headers.get('origin') || '';
  const permitido = permitidos.length === 0 ? '*' : (permitidos.includes(origen) ? origen : permitidos[0]);
  return {
    'Access-Control-Allow-Origin': permitido,
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}

function responder(req: Request, estado: number, cuerpo: unknown): Response {
  return new Response(JSON.stringify(cuerpo), {
    status: estado, headers: { ...cabecerasCors(req), 'Content-Type': 'application/json' },
  });
}

// Cabeceras para hablar con Supabase con la llave secreta (solo dentro de la función).
// Las llaves nuevas "sb_secret_..." no son JWT: van solo en "apikey".
function conLlaveSecreta(llave: string): Record<string, string> {
  const h: Record<string, string> = { apikey: llave, 'Content-Type': 'application/json' };
  if (llave.startsWith('eyJ')) h.Authorization = 'Bearer ' + llave;
  return h;
}

// Llama una función de la base (RPC) con el token de QUIEN LLAMA: el núcleo decide.
async function rpcComo(url: string, apikey: string, token: string, fn: string, args: unknown) {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const texto = await r.text();
  let datos: any = null;
  try { datos = texto ? JSON.parse(texto) : null; } catch { datos = texto; }
  return { ok: r.ok, estado: r.status, datos };
}

export async function manejar(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cabecerasCors(req) });
  if (req.method !== 'POST') return responder(req, 405, { message: 'DATO_INVALIDO: use POST.' });

  const url = leerEnv('SUPABASE_URL').replace(/\/$/, '');
  const llave = leerEnv('SUPABASE_SERVICE_ROLE_KEY');
  const apikey = req.headers.get('apikey') || leerEnv('SUPABASE_ANON_KEY');
  if (!url || !llave || !apikey) {
    return responder(req, 500, { message: 'CONFIGURACION: a la función le faltan SUPABASE_URL o la llave. Avise a su proveedor.' });
  }

  // 1) ¿Quién llama?
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token || token === apikey) return responder(req, 401, { message: 'SIN_SESION: debe iniciar sesión.' });
  const yo = await fetch(`${url}/auth/v1/user`, { headers: { apikey, Authorization: 'Bearer ' + token } });
  if (!yo.ok) return responder(req, 401, { message: 'SIN_SESION: su sesión terminó; vuelva a entrar.' });

  // Datos
  let d: any;
  try { d = await req.json(); } catch { return responder(req, 400, { message: 'DATO_INVALIDO: datos ilegibles.' }); }
  const empresa = String(d?.empresa_id || '');
  const correo = String(d?.correo || '').trim().toLowerCase();
  const nombre = String(d?.nombre || '').trim().slice(0, 120);
  const rol = String(d?.rol || '');
  const clave = String(d?.clave || '');
  if (!UUID.test(empresa)) return responder(req, 400, { message: 'DATO_INVALIDO: falta la empresa.' });
  if (!CORREO.test(correo)) return responder(req, 400, { message: 'DATO_INVALIDO: escriba un correo válido.' });
  if (nombre.length < 2) return responder(req, 400, { message: 'DATO_INVALIDO: escriba el nombre.' });
  if (!PUESTOS.includes(rol)) return responder(req, 400, { message: 'DATO_INVALIDO: puesto no válido.' });
  if (clave.length < 8 || clave.length > 72) return responder(req, 400, { message: 'DATO_INVALIDO: la clave temporal lleva de 8 a 72 letras o números.' });

  // 2) Permiso y límite del contrato, preguntados con SU token.
  const permiso = await rpcComo(url, apikey, token, 'tiene_permiso', { p_codigo: 'usuarios.administrar', p_empresa_id: empresa });
  if (!permiso.ok) return responder(req, permiso.estado === 401 ? 401 : 400, permiso.datos || { message: 'ERROR: no se pudo revisar el permiso.' });
  if (permiso.datos !== true) return responder(req, 403, { message: 'SIN_PERMISO: su puesto no puede agregar usuarios.' });
  const perfil = await rpcComo(url, apikey, token, 'mi_perfil', { p_empresa_id: empresa });
  const lim = perfil.ok ? perfil.datos?.limites?.usuarios : null;
  if (lim && lim.limite !== null && lim.limite !== undefined && Number(lim.uso) >= Number(lim.limite)) {
    return responder(req, 409, { message: `LIMITE_CONTRATO: Llegaste al máximo de tu plan. Solicita una ampliación a tu proveedor. (usuarios: ${lim.uso} de ${lim.limite})` });
  }

  // 3) Crear la cuenta en Supabase Auth (llave secreta, solo aquí dentro).
  let creadoId: string | null = null;
  const alta = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST', headers: conLlaveSecreta(llave),
    body: JSON.stringify({ email: correo, password: clave, email_confirm: true, user_metadata: { nombre } }),
  });
  const altaDatos: any = await alta.json().catch(() => ({}));
  if (alta.ok) {
    creadoId = altaDatos.id || altaDatos.user?.id || null;
  } else {
    const yaExiste = alta.status === 422 && /exist|registered/i.test(String(altaDatos.error_code || altaDatos.code || altaDatos.msg || altaDatos.message || ''));
    if (!yaExiste) {
      const detalle = String(altaDatos.msg || altaDatos.message || altaDatos.error_description || 'error de Supabase Auth');
      return responder(req, 400, { message: 'DATO_INVALIDO: Supabase no aceptó la cuenta (' + detalle.slice(0, 200) + ').' });
    }
  }

  // 4) Agregarlo a la empresa con SU token: el núcleo aplica todas sus reglas.
  const agregado = await rpcComo(url, apikey, token, 'agregar_usuario_empresa',
    { p_empresa_id: empresa, p_correo: correo, p_rol: rol, p_nombre: nombre });
  if (!agregado.ok) {
    if (creadoId) {
      // Deshacer: no dejar una cuenta que no pertenece a ninguna empresa.
      await fetch(`${url}/auth/v1/admin/users/${creadoId}`, { method: 'DELETE', headers: conLlaveSecreta(llave) }).catch(() => null);
    }
    return responder(req, agregado.estado === 401 ? 401 : 400, agregado.datos || { message: 'ERROR: no se pudo agregar.' });
  }
  const r = agregado.datos && typeof agregado.datos === 'object' ? agregado.datos : { resultado: agregado.datos };
  return responder(req, 200, { ...r, ya_tenia_cuenta: !creadoId });
}

if ((globalThis as any).Deno) Deno.serve(manejar);
