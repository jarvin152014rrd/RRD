// Ajustes · Impuestos: la tabla de impuestos de la empresa. La ve quien edita productos; la cambia
// solo quien tiene impuestos.configurar (el dueño) con motivo (configurar_impuesto). Cambiar una
// tasa vale para lo que se registre después; el código nunca cambia.
import { rpc, leer } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { h, aviso, errorSimple, campo, pedirMotivo } from '../ui.js';

const CLASES = { gravado: 'Gravado', exento: 'Exento', exonerado: 'Exonerado' };

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const lista = await leer('impuesto', { empresa_id: E }, { orden: 'orden.asc' });
  if (!ctx.sigueVigente()) return;
  const editar = puede('impuestos.configurar');
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  const tabla = h('table', { class: 'tabla tabla-celular', id: 'tabla-impuestos' },
    h('thead', {}, h('tr', {}, ['Código', 'Nombre', 'Tasa', 'Clase', 'Predeterminado', 'Activo', ''].map((t) => h('th', {}, t)))),
    h('tbody', {}, lista.map((i) => h('tr', {},
      h('td', { 'data-titulo': 'Código' }, i.codigo), h('td', { 'data-titulo': 'Nombre' }, i.nombre),
      h('td', { 'data-titulo': 'Tasa' }, `${Number(i.porcentaje)} %`), h('td', { 'data-titulo': 'Clase' }, CLASES[i.clase] || i.clase),
      h('td', { 'data-titulo': 'Predeterminado' }, i.predeterminado ? 'Sí' : 'No'), h('td', { 'data-titulo': 'Activo' }, i.activo ? 'Sí' : 'No'),
      h('td', {}, editar ? h('button', { type: 'button', class: 'boton', onclick: () => formulario(i) }, 'Cambiar') : null)))));

  function formulario(i) {
    const nuevo = !i;
    const codigo = h('input', { id: 'imp-codigo', type: 'text', maxlength: 20, value: i ? i.codigo : '', disabled: !nuevo });
    const nombre = h('input', { id: 'imp-nombre', type: 'text', maxlength: 60, value: i ? i.nombre : '' });
    const pct = h('input', { id: 'imp-pct', type: 'text', inputmode: 'decimal', value: i ? String(Number(i.porcentaje)) : '' });
    const clase = h('select', { id: 'imp-clase' }, Object.entries(CLASES).map(([k, v]) => h('option', { value: k }, v)));
    clase.value = i ? i.clase : 'gravado';
    const pred = h('input', { type: 'checkbox', checked: i ? i.predeterminado : false });
    const activo = h('input', { type: 'checkbox', checked: i ? i.activo : true });
    const zona = h('div', { 'aria-live': 'assertive' });
    const form = h('form', { class: 'formulario', novalidate: true }, campo('Código', codigo, nuevo ? 'No se cambia después.' : null), campo('Nombre', nombre),
      campo('Tasa (%)', pct), campo('Clase', clase), h('label', { class: 'opcion-check' }, pred, ' Es el predeterminado para productos nuevos'),
      h('label', { class: 'opcion-check' }, activo, ' Activo'), zona,
      h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Siguiente'),
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      zona.replaceChildren();
      const p = Number(pct.value.replace(',', '.'));
      if (!codigo.value.trim() || !nombre.value.trim() || !Number.isFinite(p) || p < 0 || p > 100) { zona.append(errorSimple('Revise código, nombre y tasa (0 a 100).')); return; }
      const datos = { codigo: codigo.value.trim().toUpperCase(), nombre: nombre.value.trim(), porcentaje: p, clase: clase.value, predeterminado: pred.checked, activo: activo.checked };
      const ok = await pedirMotivo({ titulo: nuevo ? 'Crear impuesto' : `Cambiar ${datos.codigo}`, textoBoton: 'Guardar',
        explicacion: 'Vale para lo que se registre desde ahora. Lo ya vendido queda con la tasa que usó.',
        accion: (motivo) => rpc('configurar_impuesto', { p_empresa_id: E, p_datos: datos, p_motivo: motivo }) });
      if (ok) { aviso('Impuesto guardado.'); recargar(); }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, h('h1', {}, nuevo ? 'Nuevo impuesto' : `Impuesto ${i.codigo}`), form));
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-imp' },
    h('div', { class: 'titulo-con-boton' }, h('h1', { id: 't-imp' }, 'Impuestos'),
      editar ? h('button', { type: 'button', class: 'boton boton-principal', onclick: () => formulario(null) }, 'Nuevo impuesto') : null),
    editar ? null : h('p', { class: 'ayuda' }, 'Solo el dueño cambia esta tabla.'),
    h('div', { class: 'tabla-envoltura' }, tabla)));
}
