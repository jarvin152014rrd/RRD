// Ajustes · Mis datos: quién soy, estado de la licencia y versión; "Descargar todo" en Excel
// (productos, categorías, clientes y proveedores: lo que el usuario puede ver).
import { rpc, leer } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { fecha } from '../formato.js';
import { h, aviso, conBoton } from '../ui.js';
import { descargarExcel } from '../excel.js';

const VERSION_APP = '0.3.0';
const ESTADO = { activa: 'Activa', en_gracia: 'En días de gracia', solo_lectura: 'Solo lectura (vencida)' };

export async function mostrar(vista, ctx) {
  const p = perfilActual();
  const [ver] = await leer('version_esquema', {}, { limite: 1 }).catch(() => [null]);
  if (!ctx.sigueVigente()) return;
  const lic = p.licencia || {};
  const fila = (t, v, dato) => h('div', { class: 'fila' }, h('span', {}, t), h('span', { dataset: dato ? { dato } : null }, v));
  const zona = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'button', class: 'boton boton-principal', id: 'descargar-todo' }, 'Descargar todo (Excel)');
  boton.addEventListener('click', () => conBoton(boton, zona, async () => {
    const hojas = ['productos', 'categorias'].concat(puede('terceros.ver') ? ['clientes_proveedores'] : []);
    const plantillas = [];
    for (const hoja of hojas) plantillas.push(await rpc('exportar_plantilla', { p_empresa_id: empresaId(), p_hoja: hoja }));
    await descargarExcel(`${p.empresa.nombre}_datos_${p.empresa.hoy}.xlsx`.replace(/[^\p{L}\p{N}_.-]+/gu, '_'), plantillas);
    aviso('Descarga lista.');
  }, 'Preparando…'));
  vista.append(
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-yo' }, h('h1', { id: 't-yo' }, 'Mis datos'),
      fila('Nombre', (p.usuario && p.usuario.nombre) || '—'), fila('Correo', (p.usuario && p.usuario.correo) || '—'),
      fila('Puesto', p.rol.nombre || p.rol.codigo), fila('Negocio', p.empresa.nombre)),
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-lic' }, h('h2', { id: 't-lic' }, 'Licencia y versión'),
      fila('Licencia', ESTADO[lic.estado] || lic.estado || '—', 'licencia'),
      lic.vence_el ? fila('Vence', `${fecha(lic.vence_el)}${lic.dias !== undefined ? ` (faltan ${lic.dias} días)` : ''}`) : null,
      fila('Versión del programa', VERSION_APP, 'version-app'),
      fila('Versión del servidor', ver ? ver.version_nucleo : '—', 'version-nucleo')),
    puede('empresa.configurar', 'usuarios.administrar') ? h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-todo' },
      h('h2', { id: 't-todo' }, 'Descargar mis datos'),
      h('p', { class: 'ayuda' }, 'Un Excel con sus productos, categorías y clientes de hoy. Sus datos son suyos.'), zona, boton) : null);
}
