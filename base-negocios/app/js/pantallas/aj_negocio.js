// Ajustes · Mi negocio: nombre comercial, logo y colores con vista previa y "Volver al anterior"
// (marca_empresa / configurar_marca, permiso empresa.marca: dueño y admin). Los datos fiscales
// (nombre legal y RTN) solo los ve el dueño y se cambian con el proveedor (ficha del cliente).
import { rpc } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { h, icono, aviso, errorSimple, campo, pedirMotivo, titulo, burbuja, chip, mensaje } from '../ui.js';
import { guardarMarcaLocal, aplicarMarca, textoSobre, iniciales } from '../marca.js';

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
  const aviContraste = h('div', { 'aria-live': 'polite' });

  // Vista previa EN VIVO: el mismo encabezado de la app (mismas clases) con los colores elegidos,
  // antes de guardar. Los colores se ponen solo dentro de la vista previa (aplicarMarca con raíz propia),
  // con el mismo contraste automático que tendrá la app.
  const prevLogo = h('div', { class: 'marca-logo', 'aria-hidden': 'true' });
  const prevNombre = h('span', { class: 'marca-nombre' });
  const previa = h('div', { class: 'vista-marca', id: 'marca-previa', role: 'img', 'aria-label': 'Vista previa del encabezado con su logo y colores' },
    h('div', { class: 'encabezado vista-marca-encabezado' },
      h('div', { class: 'encabezado-fila' }, h('div', { class: 'marca' }, prevLogo, prevNombre),
        h('div', { class: 'quien' }, h('span', { class: 'campana' }, icono('campana'), h('span', { class: 'campana-numero' }, '3')),
          h('span', { class: 'boton boton-claro' }, 'Salir'))),
      h('div', { class: 'pestanas' }, [['inicio', 'Inicio', true], ['vender', 'Vender'], ['caja', 'Caja'], ['clientes', 'Clientes']]
        .map(([i, t, on]) => h('span', { class: 'pestana', 'aria-current': on ? 'page' : null }, icono(i), h('span', {}, t))))),
    h('div', { class: 'vista-marca-cuerpo' },
      h('span', { class: 'boton boton-principal' }, icono('vender'), 'Botón principal'), h('span', { class: 'boton' }, 'Otro botón'),
      burbuja('estrella', 'acento'), chip('Entra dinero', 'verde'), chip('Sale dinero', 'rojo'), chip('Importante', 'dorado')));
  function pintarPrevia() {
    aplicarMarca({ color_principal: principal.value, color_acento: acento.value }, previa);
    const n = nombre.value.trim() || m.nombre;
    prevNombre.textContent = n;
    const l = quitarLogo.checked ? null : logo;
    prevLogo.replaceChildren(l ? h('img', { src: l, alt: '', class: 'marca-logo-img' }) : iniciales(n));
    // Contraste automático: si el color es muy claro, las letras de encima se ponen oscuras.
    const oscuro = textoSobre(principal.value) !== '#ffffff';
    aviContraste.replaceChildren(oscuro ? mensaje('info', 'Su color principal es claro: las letras de encima se ponen oscuras para que se lean bien.',
      null, { dataset: { info: 'contraste' } }) : '');
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
    aviso(`Marca guardada · ${r.marca && r.marca.nombre_comercial ? r.marca.nombre_comercial : r.nombre || 'su negocio'} ya se ve con su logo y colores`);
    vista.replaceChildren(); await mostrar(vista, ctx);
  }

  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre comercial (el que ven sus clientes)', nombre, `Vacío = ${m.nombre}.`),
    campo('Logo (PNG, JPG o WEBP, hasta 200 KB)', archivoLogo),
    logo ? h('label', { class: 'opcion-check' }, quitarLogo, ' Quitar el logo') : null,
    h('div', { class: 'dos-columnas' }, campo('Color principal', principal), campo('Color de acento', acento)),
    titulo('h2', 'sol', 'Así se verá (antes de guardar)', { class: 'titulo-chico' }), previa, aviContraste,
    h('p', { class: 'ayuda' }, 'Su marca cambia el color principal y el de acento. Los colores de los avisos (verde, rojo, dorado y azul) no cambian, para que siempre signifiquen lo mismo.'),
    zonaError,
    editar ? h('div', { class: 'botones' },
      h('button', { type: 'submit', class: 'boton boton-principal', id: 'marca-guardar' }, 'Guardar'),
      m.puede_volver ? h('button', { type: 'button', class: 'boton', id: 'marca-volver',
        onclick: () => guardar({ volver_anterior: true }, 'Volver a la marca anterior') }, 'Volver al anterior') : null) : null);
  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const datos = { nombre_comercial: nombre.value.trim() || null, color_principal: principal.value, color_acento: acento.value,
      logo: quitarLogo.checked ? null : logo };
    guardar(datos, 'Guardar la marca del negocio');
  });

  vista.append(...[
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-neg' }, titulo('h1', 'tienda', 'Mi negocio', { id: 't-neg' }), form),
    puede('empresa.configurar') ? h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fis' },
      titulo('h2', 'documento', 'Datos fiscales', { id: 't-fis' }),
      h('div', { class: 'fila' }, h('span', {}, 'Nombre legal'), h('span', {}, m.nombre)),
      h('div', { class: 'fila' }, h('span', {}, 'RTN'), h('span', { dataset: { dato: 'rtn' } }, m.rtn || '—')),
      h('p', { class: 'ayuda' }, 'Salen en las facturas. Para cambiarlos hable con su proveedor (quedan en la ficha del negocio).')) : null].filter(Boolean));
  // Al salir de esta pantalla sin guardar, el programa sigue con la marca guardada.
  aplicarMarca(marca);
}
