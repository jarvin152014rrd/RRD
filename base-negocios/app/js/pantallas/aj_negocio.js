// Ajustes · Mi negocio: nombre comercial, logo y colores con vista previa y "Volver al anterior"
// (marca_empresa / configurar_marca, permiso empresa.marca: dueño y admin). Los datos fiscales
// (nombre legal y RTN) solo los ve el dueño y se cambian con el proveedor (ficha del cliente).
import { rpc } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { h, aviso, errorSimple, campo, pedirMotivo } from '../ui.js';
import { guardarMarcaLocal, aplicarMarca, contrasteConBlanco } from '../marca.js';

const BASE = { color_principal: '#0f1f3d', color_acento: '#c8972a' }; // los del tema

export async function mostrar(vista, ctx) {
  const m = await rpc('marca_empresa', { p_empresa_id: empresaId() });
  if (!ctx.sigueVigente()) return;
  const marca = m.marca || {};
  const editar = puede('empresa.marca');
  const nombre = h('input', { id: 'marca-nombre-com', type: 'text', maxlength: 80, value: marca.nombre_comercial || '', placeholder: m.nombre });
  const principal = h('input', { id: 'marca-principal', type: 'color', value: marca.color_principal || BASE.color_principal });
  const acento = h('input', { id: 'marca-acento', type: 'color', value: marca.color_acento || BASE.color_acento });
  const archivoLogo = h('input', { id: 'marca-logo-archivo', type: 'file', accept: 'image/png,image/jpeg,image/webp' });
  let logo = marca.logo || null;
  const quitarLogo = h('input', { type: 'checkbox', id: 'marca-quitar-logo' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const aviContraste = h('p', { class: 'mensaje mensaje-info', hidden: true });

  // Vista previa: una barra como el encabezado con los colores elegidos.
  const imgPrev = h('span', { class: 'marca-logo' });
  const nomPrev = h('span', {});
  const barra = h('div', { class: 'vista-tema-barra' }, imgPrev, nomPrev);
  const btnPrev = h('span', { class: 'boton boton-principal' }, 'Botón');
  const cuerpo = h('div', { class: 'vista-tema-cuerpo' }, btnPrev, h('span', { class: 'etiqueta' }, 'Etiqueta'));
  const previa = h('div', { class: 'vista-tema', id: 'marca-previa', 'aria-label': 'Vista previa' }, barra, cuerpo);
  function pintarPrevia() {
    barra.style.background = principal.value;
    btnPrev.style.background = principal.value; btnPrev.style.borderColor = principal.value;
    imgPrev.style.background = acento.value;
    nomPrev.textContent = nombre.value.trim() || m.nombre;
    const l = quitarLogo.checked ? null : logo;
    imgPrev.replaceChildren(l ? h('img', { src: l, alt: '', class: 'marca-logo-img' }) : (nombre.value.trim() || m.nombre).slice(0, 2).toUpperCase());
    const c = contrasteConBlanco(principal.value);
    aviContraste.hidden = c >= 4.5;
    aviContraste.textContent = 'Con ese color principal las letras blancas se leen mal. Elija uno más oscuro.';
  }
  for (const x of [nombre, principal, acento, quitarLogo]) x.addEventListener('input', pintarPrevia);
  quitarLogo.addEventListener('change', pintarPrevia);
  archivoLogo.addEventListener('change', () => {
    zonaError.replaceChildren();
    const f = archivoLogo.files[0];
    if (!f) return;
    if (!/^image\/(png|jpeg|webp)$/.test(f.type) || f.size > 200 * 1024) {
      zonaError.append(errorSimple('El logo debe ser PNG, JPG o WEBP de hasta 200 KB.')); archivoLogo.value = ''; return;
    }
    const lector = new FileReader();
    lector.onload = () => { logo = lector.result; quitarLogo.checked = false; pintarPrevia(); };
    lector.readAsDataURL(f);
  });
  pintarPrevia();

  async function guardar(datos, titulo) {
    let r = null;
    const ok = await pedirMotivo({ titulo, textoBoton: 'Guardar', explicacion: 'Se verá en todos los equipos del negocio.',
      accion: async (motivo) => { r = await rpc('configurar_marca', { p_empresa_id: empresaId(), p_datos: datos, p_motivo: motivo }); } });
    if (!ok || !r) return;
    guardarMarcaLocal(r);
    aviso('Listo: se guardó la marca del negocio.');
    vista.replaceChildren(); await mostrar(vista, ctx);
  }

  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre comercial (el que ven sus clientes)', nombre, `Vacío = ${m.nombre}.`),
    campo('Logo (PNG, JPG o WEBP, hasta 200 KB)', archivoLogo),
    logo ? h('label', { class: 'opcion-check' }, quitarLogo, ' Quitar el logo') : null,
    h('div', { class: 'dos-columnas' }, campo('Color principal', principal), campo('Color de acento', acento)),
    h('h2', { class: 'titulo-chico' }, 'Vista previa'), previa, aviContraste, zonaError,
    editar ? h('div', { class: 'botones' },
      h('button', { type: 'submit', class: 'boton boton-principal', id: 'marca-guardar' }, 'Guardar'),
      m.puede_volver ? h('button', { type: 'button', class: 'boton', id: 'marca-volver',
        onclick: () => guardar({ volver_anterior: true }, 'Volver a la marca anterior') }, 'Volver al anterior') : null) : null);
  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    if (contrasteConBlanco(principal.value) < 4.5) { zonaError.append(errorSimple('Elija un color principal más oscuro para que se lea bien.')); return; }
    const datos = { nombre_comercial: nombre.value.trim() || null, color_principal: principal.value, color_acento: acento.value,
      logo: quitarLogo.checked ? null : logo };
    guardar(datos, 'Guardar la marca del negocio');
  });

  vista.append(...[
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-neg' }, h('h1', { id: 't-neg' }, 'Mi negocio'), form),
    puede('empresa.configurar') ? h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fis' },
      h('h2', { id: 't-fis' }, 'Datos fiscales'),
      h('div', { class: 'fila' }, h('span', {}, 'Nombre legal'), h('span', {}, m.nombre)),
      h('div', { class: 'fila' }, h('span', {}, 'RTN'), h('span', { dataset: { dato: 'rtn' } }, m.rtn || '—')),
      h('p', { class: 'ayuda' }, 'Salen en las facturas. Para cambiarlos hable con su proveedor (quedan en la ficha del negocio).')) : null].filter(Boolean));
  // Al salir de esta pantalla sin guardar, el programa sigue con la marca guardada.
  aplicarMarca(marca);
}
