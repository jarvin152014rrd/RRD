// =====================================================================
// Edge Function "cerrar-sesion-remota"  (Supabase, Deno)  -  núcleo 0.15.0
//
// La llama la app (Ajustes > Usuarios > "Cerrar sesión") con el token de quien
// está usando la app. Pasos:
//   1. Revisa el token de quien llama (GET /auth/v1/user).
//   2. Con SU token llama cerrar_sesion_usuario(empresa, usuario, motivo): el
//      núcleo revisa el permiso usuarios.administrar y las reglas (no a sí
//      mismo, solo el dueño cierra a un dueño o administrador...), lo anota en
//      la bitácora y desde ya rechaza todo lo que haga esa sesión (SESION_CERRADA).
//   3. Con la llave service_role (variables de entorno; nunca sale de aquí)
//      llama revocar_sesiones_auth(usuario): borra sus sesiones de Supabase
//      Auth, así tampoco puede renovar el token. La base solo lo permite si el
//      paso 2 se hizo hace menos de 10 minutos (doble candado).
//      Nota: auth.admin.signOut() de supabase-js pide el token DEL USUARIO que
//      se cierra (no lo tenemos); por eso se revoca desde la base.
//   Si el paso 3 falla, el paso 2 ya bloquea al usuario: se responde bien con
//   un aviso.
//
// Recibe (JSON): { empresa_id, user_id, motivo }
// Responde: { usuario_id, sesion_cerrada_en, sesiones_revocadas, aviso? }
// Errores: { message: "CLAVE: texto" }.
//
// Variables de entorno (Supabase las pone solas): SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY. Opcional: ORIGENES_PERMITIDOS.
// Sin librerías (solo fetch). También corre en Node 22 para las pruebas locales.
// =====================================================================

declare const Deno: any;
const leerEnv = (k: string): string =>
  ((globalThis as any).Deno ? Deno.env.get(k) : (globalThis as any).process?.env?.[k]) || '';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

function conLlaveSecreta(llave: string): Record<string, string> {
  const h: Record<string, string> = { apikey: llave, 'Content-Type': 'application/json' };
  if (llave.startsWith('eyJ')) h.Authorization = 'Bearer ' + llave;
  return h;
}

async function rpc(url: string, cabeceras: Record<string, string>, fn: string, args: unknown) {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { ...cabeceras, 'Content-Type': 'application/json' }, body: JSON.stringify(args),
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

  let d: any;
  try { d = await req.json(); } catch { return responder(req, 400, { message: 'DATO_INVALIDO: datos ilegibles.' }); }
  const empresa = String(d?.empresa_id || '');
  const usuario = String(d?.user_id || '');
  const motivo = String(d?.motivo || '');
  if (!UUID.test(empresa) || !UUID.test(usuario)) return responder(req, 400, { message: 'DATO_INVALIDO: falta la empresa o el usuario.' });

  // 2) Cerrar con SU token: permiso, reglas y bitácora los pone el núcleo.
  const cierre = await rpc(url, { apikey, Authorization: 'Bearer ' + token }, 'cerrar_sesion_usuario',
    { p_empresa_id: empresa, p_user_id: usuario, p_motivo: motivo });
  if (!cierre.ok) return responder(req, cierre.estado === 401 ? 401 : 400, cierre.datos || { message: 'ERROR: no se pudo cerrar la sesión.' });

  // 3) Quitarle también la renovación del token (llave secreta, solo aquí).
  const revocar = await rpc(url, conLlaveSecreta(llave), 'revocar_sesiones_auth', { p_user_id: usuario });
  const r: any = { ...(cierre.datos || {}), sesiones_revocadas: revocar.ok ? revocar.datos : null };
  if (!revocar.ok || revocar.datos === -1) {
    r.aviso = 'La sesión quedó cerrada (ya no puede hacer nada), pero Supabase no dejó borrar sus sesiones: la app le pedirá entrar de nuevo.';
  }
  return responder(req, 200, r);
}

if ((globalThis as any).Deno) Deno.serve(manejar);
