// Ajustes · Impuestos: la tabla de impuestos de la empresa. La ve quien edita productos; la cambia
// solo quien tiene impuestos.configurar (el dueño) con motivo (configurar_impuesto). Cambiar una
// tasa vale para lo que se registre después; el código nunca cambia.
import { rpc, leer } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { aPorcentaje, comaInvalida, MENSAJE_COMA } from '../formato.js';
import { h, icono, aviso, errorSimple, campo, pedirMotivo, titulo, tabla, chipEstado, chip } from '../ui.js';

const CLASES = { gravado: 'Gravado', exento: 'Exento', exonerado: 'Exonerado' };

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const lista = await leer('impuesto', { empresa_id: E }, { orden: 'orden.asc' });
  if (!ctx.sigueVigente()) return;
  const editar = puede('impuestos.configurar');
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  // En el celular cada impuesto es una tarjeta: arriba el nombre y su código.
  const tablaImp = tabla({ props: { id: 'tabla-impuestos' },
    columnas: [{ titulo: 'Nombre' }, { titulo: 'Código' }, { titulo: 'Tasa', num: true }, { titulo: 'Clase' }, { titulo: 'Predeterminado' }, { titulo: 'Activo' }]
      .concat(editar ? [{ titulo: 'Acciones', acciones: true }] : []),
    filas: lista.map((i) => [h('strong', {}, i.nombre), i.codigo, `${Number(i.porcentaje)} %`, CLASES[i.clase] || i.clase,
      i.predeterminado ? chip('Sí', 'azul') : 'No', chipEstado(i.activo ? 'activo' : 'inactivo')]
      .concat(editar ? [h('button', { type: 'button', class: 'boton', 'aria-label': `Cambiar ${i.nombre}`, onclick: () => formulario(i) }, icono('editar'), 'Cambiar')] : [])) });

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
      const p = aPorcentaje(pct.value);
      if (!codigo.value.trim() || !nombre.value.trim() || p === null) { zona.append(errorSimple(comaInvalida(pct.value) ? MENSAJE_COMA : 'Revise código, nombre y tasa (0 a 100).')); return; }
      const datos = { codigo: codigo.value.trim().toUpperCase(), nombre: nombre.value.trim(), porcentaje: p, clase: clase.value, predeterminado: pred.checked, activo: activo.checked };
      const ok = await pedirMotivo({ titulo: nuevo ? 'Crear impuesto' : `Cambiar ${datos.codigo}`, textoBoton: 'Guardar',
        explicacion: 'Vale para lo que se registre desde ahora. Lo ya vendido queda con la tasa que usó.',
        accion: (motivo) => rpc('configurar_impuesto', { p_empresa_id: E, p_datos: datos, p_motivo: motivo }) });
      if (ok) { aviso(`Impuesto guardado · ${datos.nombre} al ${datos.porcentaje} %`); recargar(); }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'impuestos', nuevo ? 'Nuevo impuesto' : `Impuesto ${i.codigo}`), form));
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-imp' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'impuestos', 'Impuestos', { id: 't-imp' }),
      editar ? h('button', { type: 'button', class: 'boton boton-principal', onclick: () => formulario(null) }, icono('mas'), 'Nuevo impuesto') : null),
    editar ? null : h('p', { class: 'ayuda' }, 'Solo el dueño cambia esta tabla.'),
    tablaImp));
}
