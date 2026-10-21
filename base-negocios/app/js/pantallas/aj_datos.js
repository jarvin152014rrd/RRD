// Ajustes · "Mi cuenta" (antes "Mis datos"): quién soy, estado de la licencia y versión, y
// "Alertas que recibo" (app 0.6.0: mis_preferencias_alertas / guardar_preferencias_alertas del
// núcleo 0.12; cada quien elige las suyas, solo de los tipos que su puesto puede ver). La copia de los datos en Excel ("Descargar
// todo") está en Ajustes > "Excel y copia de mis datos"; quien no ve esa subpestaña (le falta
// excel.importar o el módulo) la tiene aquí: el cliente SIEMPRE puede sacar sus datos.
import { rpc, leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { fecha } from '../formato.js';
import { h, icono, aviso, conBoton, estadoVacio, cajaError, titulo, chip, mensaje } from '../ui.js';
import { descargarExcel } from '../excel.js';
import { hayEnMenu } from '../menu.js';

export const VERSION_APP = '0.6.1';
const ESTADO = { activa: 'Activa', en_gracia: 'En días de gracia', solo_lectura: 'Solo lectura (vencida)' };

// "Descargar todo" (productos, categorías, clientes y proveedores: lo que el usuario puede ver).
// Lo usa la pantalla de Excel. Devuelve null si el usuario no tiene permiso.
export function tarjetaCopiaDatos(clase = '') {
  if (!puede('empresa.configurar', 'usuarios.administrar')) return null;
  const p = perfilActual();
  const zona = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'button', class: 'boton boton-principal', id: 'descargar-todo' }, 'Descargar todo (Excel)');
  boton.addEventListener('click', () => conBoton(boton, zona, async () => {
    const hojas = ['productos', 'categorias'].concat(puede('terceros.ver') ? ['clientes_proveedores'] : []);
    const plantillas = [];
    for (const hoja of hojas) plantillas.push(await rpc('exportar_plantilla', { p_empresa_id: empresaId(), p_hoja: hoja }));
    await descargarExcel(`${p.empresa.nombre}_datos_${p.empresa.hoy}.xlsx`.replace(/[^\p{L}\p{N}_.-]+/gu, '_'), plantillas);
    aviso(`Descarga lista · ${plantillas.length} hoja(s) en Excel`);
  }, 'Preparando…'));
  return h('section', { class: ('tarjeta ' + clase).trim(), 'aria-labelledby': 't-todo', id: 'copia-datos' },
    h('h2', { id: 't-todo', class: 'titulo-icono' }, icono('descargar'), 'Copia de mis datos'),
    h('p', { class: 'ayuda' }, 'Un Excel con sus productos, categorías y clientes de hoy. Sus datos son suyos.'), zona, boton);
}

export async function mostrar(vista, ctx) {
  const p = perfilActual();
  const [ver] = await leer('version_esquema', {}, { limite: 1 }).catch(() => [null]);
  if (!ctx.sigueVigente()) return;
  const lic = p.licencia || {};
  const fila = (t, v, dato) => h('div', { class: 'fila' }, h('span', {}, t), h('span', { dataset: dato ? { dato } : null }, v));
  // (append no salta los null: se filtran para que no salga el texto "null")
  vista.append(...[
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-yo' }, h('h1', { id: 't-yo', class: 'titulo-icono' }, icono('cuenta'), 'Mi cuenta'),
      fila('Nombre', (p.usuario && p.usuario.nombre) || '—'), fila('Correo', (p.usuario && p.usuario.correo) || '—'),
      fila('Puesto', p.rol.nombre || p.rol.codigo), fila('Negocio', p.empresa.nombre)),
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-lic' }, h('h2', { id: 't-lic', class: 'titulo-icono' }, icono('candado'), 'Licencia y versión'),
      fila('Licencia', ESTADO[lic.estado] || lic.estado || '—', 'licencia'),
      lic.vence_el ? fila('Vence', `${fecha(lic.vence_el)}${lic.dias !== undefined ? ` (faltan ${lic.dias} días)` : ''}`) : null,
      fila('Versión del programa', VERSION_APP, 'version-app'),
      fila('Versión del servidor', ver ? ver.version_nucleo : '—', 'version-nucleo')),
    hayEnMenu(ctx.menu || [], 'ajustes', 'excel') ? null : tarjetaCopiaDatos('tarjeta-angosta'),
    await tarjetaAlertas()].filter(Boolean));
}

// "Alertas que recibo": una casilla por tipo de alerta que su puesto puede ver (por defecto todas).
// Solo cambia lo que ESTA persona ve en Inicio > Pendientes y en la campanita; a los demás no.
async function tarjetaAlertas() {
  const sec = h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-mis-alertas', id: 'mis-alertas' },
    titulo('h2', 'campana', 'Alertas que recibo', { id: 't-mis-alertas' }));
  let lista;
  try { lista = await rpc('mis_preferencias_alertas', { p_empresa_id: empresaId() }); } catch (err) { sec.append(await cajaError(err)); return sec; }
  if (!Array.isArray(lista) || !lista.length) {
    sec.append(estadoVacio({ icono: 'campana', chico: true, texto: 'Con su puesto no le llega ningún tipo de alerta.' }));
    return sec;
  }
  const marcas = lista.map((t) => ({ t, c: h('input', { type: 'checkbox', checked: t.recibir !== false, dataset: { alerta: t.tipo },
    'aria-describedby': `alerta-desc-${t.tipo}` }) }));
  const cuenta = h('span', {});
  const pintarCuenta = () => {
    const n = marcas.filter((m) => m.c.checked).length;
    cuenta.replaceChildren(chip(`Recibe ${n} de ${marcas.length}`, n === marcas.length ? 'verde' : n === 0 ? 'rojo' : 'dorado', { dataset: { dato: 'alertas-recibe' } }));
  };
  marcas.forEach((m) => m.c.addEventListener('change', pintarCuenta));
  pintarCuenta();
  const zona = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'button', class: 'boton boton-principal boton-ancho', id: 'alertas-guardar' }, 'Guardar mis alertas');
  boton.addEventListener('click', async () => {
    zona.replaceChildren();
    const cambios = Object.fromEntries(marcas.filter((m) => m.c.checked !== (m.t.recibir !== false)).map((m) => [m.t.tipo, m.c.checked]));
    if (!Object.keys(cambios).length) { zona.append(mensaje('info', 'No cambió nada.')); return; }
    const r = await conBoton(boton, zona, () => rpc('guardar_preferencias_alertas', { p_empresa_id: empresaId(), p_datos: cambios }));
    if (!r) return;
    // Lo que respondió el servidor es lo que vale.
    for (const m of marcas) { const x = (r || []).find((y) => y.tipo === m.t.tipo); if (x) { m.t.recibir = x.recibir; m.c.checked = x.recibir; } }
    pintarCuenta();
    const n = marcas.filter((m) => m.c.checked).length;
    aviso(`Alertas guardadas · recibe ${n} de ${marcas.length}`);
    window.dispatchEvent(new Event('pendientes-cambiaron')); // la campanita vuelve a contar
  });
  sec.append(
    h('p', { class: 'ayuda' }, 'Elija qué avisos le salen en Inicio > Pendientes y en la campanita. Solo cambia lo que usted ve.'),
    cuenta,
    h('div', { class: 'lista-alertas' }, marcas.map(({ t, c }) => h('label', { class: 'opcion-alerta' }, c,
      h('span', {}, h('strong', {}, t.nombre), h('span', { class: 'detalle', id: `alerta-desc-${t.tipo}` }, t.descripcion))))),
    zona, boton);
  return sec;
}
