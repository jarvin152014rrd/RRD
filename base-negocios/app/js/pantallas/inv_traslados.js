// Inventario · Traslados entre bodegas o sucursales (trasladar_inventario) y confirmación de
// recepción de lo que viene de otra sucursal (pendientes_entre_sucursales /
// confirmar_recepcion_traslado: solo quien trabaja en la sucursal destino).
import { rpc, leer, escribir } from '../api.js';
import { empresaId, perfilActual } from '../sesion.js';
import { fecha, cantidad, aCantidad, comaInvalida, MENSAJE_COMA } from '../formato.js';
import { h, aviso, errorSimple, campo, conBoton, confirmar, cajaError, titulo, filaIcono, chip, estadoVacio } from '../ui.js';
import { filtrar } from '../datos.js';

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const [bodegas, exist, pend] = await Promise.all([
    leer('bodega', { empresa_id: E, activa: true }, { orden: 'codigo.asc' }),
    leer('v_existencia', { empresa_id: E }, { orden: 'nombre.asc', limite: 1000 }),
    rpc('pendientes_entre_sucursales', { p_empresa_id: E }).catch(() => ({ mercaderia: [] }))]);
  if (!ctx.sigueVigente()) return;
  const opcion = (b) => h('option', { value: b.id }, `${b.codigo} · ${b.nombre}`);
  const origen = h('select', { id: 'tras-origen' }, bodegas.map(opcion));
  const destino = h('select', { id: 'tras-destino' }, bodegas.map(opcion));
  if (bodegas[1]) destino.value = bodegas[1].id;
  const buscar = h('input', { id: 'tras-buscar', type: 'search', placeholder: 'Producto a trasladar', autocomplete: 'off' });
  const sugerencias = h('div', { class: 'lista' });
  const lineas = []; // { producto_id, nombre, codigo, unidad, hay, input }
  const zonaLineas = h('div', { class: 'lista', id: 'tras-lineas' });
  const nota = h('input', { id: 'tras-nota', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Trasladar');
  const enOrigen = () => exist.filter((x) => x.bodega_id === origen.value && Number(x.cantidad) > 0);
  const pintarSug = () => {
    if (!buscar.value.trim()) { sugerencias.replaceChildren(); return; }
    sugerencias.replaceChildren(...filtrar(enOrigen(), buscar.value, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((x) =>
      h('button', { type: 'button', class: 'boton', onclick: () => agregar(x) }, `${x.nombre} · hay ${cantidad(x.cantidad)} ${x.unidad || ''}`)));
  };
  const pintarLineas = () => zonaLineas.replaceChildren(...(lineas.length ? lineas.map((l, i) => h('div', { class: 'conteo-fila' },
    h('span', {}, h('strong', {}, l.nombre), h('span', { class: 'detalle' }, ` ${l.codigo} · hay ${cantidad(l.hay)} ${l.unidad || ''}`),
      h('button', { type: 'button', class: 'boton', 'aria-label': `Quitar ${l.nombre}`, onclick: () => { lineas.splice(i, 1); pintarLineas(); } }, 'Quitar')), l.input))
    : [estadoVacio({ icono: 'traslado', chico: true, texto: 'Busque y agregue los productos que va a trasladar.' })]));
  function agregar(x) {
    if (!lineas.some((l) => l.producto_id === x.producto_id)) {
      lineas.push({ producto_id: x.producto_id, nombre: x.nombre, codigo: x.codigo, unidad: x.unidad, hay: x.cantidad,
        input: h('input', { type: 'text', inputmode: 'decimal', 'aria-label': `Cantidad de ${x.nombre}`, placeholder: 'Cantidad' }) });
    }
    buscar.value = ''; pintarSug(); pintarLineas();
    lineas[lineas.length - 1].input.focus();
  }
  buscar.addEventListener('input', pintarSug);
  origen.addEventListener('change', () => { lineas.length = 0; pintarLineas(); pintarSug(); });
  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'dos-columnas' }, campo('Sale de', origen), campo('Llega a', destino)),
    campo('Buscar producto', buscar), sugerencias, zonaLineas, campo('Nota (opcional)', nota), zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    if (origen.value === destino.value) { zonaError.append(errorSimple('Elija bodegas distintas.')); return; }
    const ls = lineas.map((l) => ({ producto_id: l.producto_id, cantidad: aCantidad(l.input.value) }));
    if (!ls.length || ls.some((l) => l.cantidad === null)) {
      zonaError.append(errorSimple(lineas.some((l) => comaInvalida(l.input.value)) ? MENSAJE_COMA : 'Escriba una cantidad mayor que cero en cada producto.')); return;
    }
    const txt = `${ls.length} producto(s) de ${origen.selectedOptions[0].textContent} a ${destino.selectedOptions[0].textContent}.`;
    if (!await confirmar({ titulo: 'Trasladar mercadería', texto: txt, textoBoton: 'Sí, trasladar' })) return;
    const r = await conBoton(boton, zonaError, () => escribir('trasladar_inventario', { p_empresa_id: E, p_bodega_origen_id: origen.value,
      p_bodega_destino_id: destino.value, p_fecha: perfilActual().empresa.hoy, p_lineas: ls, p_nota: nota.value.trim() || null }), 'Trasladando…');
    if (!r) return;
    aviso(`Traslado #${r.numero || ''} guardado · ${ls.length} producto(s) de ${origen.selectedOptions[0].textContent} a ${destino.selectedOptions[0].textContent}`);
    vista.replaceChildren(); mostrar(vista, ctx).catch(async (e) => vista.append(await cajaError(e)));
  });
  pintarLineas();
  const merc = (pend.mercaderia || []);
  vista.append(...[
    merc.length ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-rec' },
      titulo('h2', 'traslado', 'Mercadería en camino desde otra sucursal', { id: 't-rec' }),
      merc.map((m) => filaIcono({ icono: 'traslado', color: 'dorado',
        titulo: h('strong', {}, `Traslado #${m.numero}: ${m.de} → ${m.a}`),
        detalle: `${fecha(m.fecha)} · ${m.lineas} producto(s) · hace ${m.dias} día(s)`,
        derecha: chip('En camino', 'dorado'),
        abajo: m.puedo_recibir ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton boton-principal', 'aria-label': `Confirmar recepción del traslado #${m.numero}`, onclick: async (ev) => {
          if (!await confirmar({ titulo: 'Confirmar recepción', texto: `¿Llegó el traslado #${m.numero}? Si llegó menos, anótelo y haga un conteo.`, textoBoton: 'Sí, llegó' })) return;
          const z = h('div'); ev.target.after(z);
          const r = await conBoton(ev.target, z, () => escribir('confirmar_recepcion_traslado', { p_documento_id: m.documento_id }));
          if (r) { aviso(`Recepción confirmada · traslado #${m.numero}`); vista.replaceChildren(); mostrar(vista, ctx); }
        } }, 'Confirmar recepción')) : h('p', { class: 'ayuda' }, 'Lo recibe la otra sucursal.') }))) : null,
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-tras' }, titulo('h1', 'traslado', 'Trasladar mercadería', { id: 't-tras' }),
      bodegas.length < 2 ? estadoVacio({ icono: 'traslado', titulo: 'Necesita dos bodegas',
        texto: 'Para trasladar mercadería hacen falta al menos dos bodegas (por ejemplo, la tienda y la bodega de atrás).',
      }) : form)].filter(Boolean));
}
