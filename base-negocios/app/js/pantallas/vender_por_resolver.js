// Vender · "Ventas sin internet por resolver" (app 0.14.0, núcleo 0.20.0). Para el dueño y el supervisor
// (ventas.resolver_sin_internet). Una venta hecha sin internet que el servidor no pudo registrar sola (precio que
// no cuadra, número repetido, hora rara, usuario desactivado, inventario en negativo grave…) queda aquí. El dinero
// ya se cobró: se REGISTRA tal como se hizo, o se ANULA (el número queda anulado y el dinero queda como sobrante de
// caja hasta devolverlo). Siempre con motivo; queda en la bitácora.
import { rpc, escribir } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fechaHora, cantidad } from '../formato.js';
import { h, aviso, cajaError, titulo, chip, filaIcono, estadoVacio, pedirMotivo, mensaje } from '../ui.js';

const PAGOS = { efectivo: 'Efectivo', transferencia: 'Transferencia', tarjeta: 'Tarjeta' };

export async function mostrar(vista, ctx) {
  const E = empresaId();
  let todas = false;
  const zona = h('div', { id: 'lista-por-resolver' });
  const verTodas = h('input', { type: 'checkbox', id: 'vpr-todas' });
  verTodas.addEventListener('change', () => { todas = verTodas.checked; cargar(); });
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-vpr' },
    titulo('h1', 'alerta', 'Ventas sin internet por resolver', { id: 't-vpr' }),
    h('p', { class: 'ayuda' }, 'Ventas hechas sin internet que necesitan su decisión. El cliente ya pagó y se llevó la mercadería: normalmente se registran tal como se hicieron.'),
    h('label', { class: 'opcion-check' }, verTodas, ' Ver también las ya resueltas'), zona));
  await cargar();

  async function cargar() {
    let d;
    try { d = await rpc('ventas_sin_internet_por_resolver', { p_empresa_id: E, p_todas: todas }); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    if (!d.ventas.length) {
      zona.replaceChildren(estadoVacio({ icono: 'check_circulo', color: 'verde', titulo: 'Nada por resolver',
        texto: 'Todas las ventas hechas sin internet se registraron bien.' }));
      return;
    }
    zona.replaceChildren(...d.ventas.map(tarjeta));
  }

  function tarjeta(v) {
    const pendiente = v.estado === 'por_resolver';
    const botones = pendiente ? [
      h('button', { type: 'button', class: 'boton boton-principal', dataset: { registrar: v.venta_sin_internet_id },
        onclick: () => resolver(v, 'registrar') }, 'Registrar como se hizo'),
      h('button', { type: 'button', class: 'boton boton-peligro', dataset: { anular: v.venta_sin_internet_id },
        onclick: () => resolver(v, 'anular') }, 'Anular'),
    ] : null;
    return h('article', { class: 'tarjeta venta-por-resolver', dataset: { vsi: v.venta_sin_internet_id, estado: v.estado } },
      filaIcono({ icono: v.grave ? 'alerta' : 'info', color: v.grave ? 'rojo' : 'dorado',
        titulo: h('strong', {}, `${v.numero_documento || 'Sin número'} · ${dinero(v.total_centavos)}`),
        detalle: `${fechaHora(v.hora_equipo)} · ${v.usuario || ''} · ${v.equipo}${v.caja ? ' · ' + v.caja : ''}`,
        derecha: pendiente ? chip(v.grave ? 'Grave' : 'Por resolver', v.grave ? 'rojo' : 'dorado') : chip(v.estado === 'anulada' ? 'Anulada' : 'Registrada', v.estado === 'anulada' ? 'rojo' : 'verde') }),
      mensaje(v.grave ? 'error' : 'info', v.problema_texto || 'Revise esta venta.', null, { dataset: { dato: 'problema', problema: v.problema || '' } }),
      h('ul', { class: 'lista-simple' }, (v.lineas || []).map((l) => h('li', {}, `${cantidad(l.cantidad)} x ${l.nombre || 'Producto'} · ${dinero(l.total_centavos)}`))),
      h('p', { class: 'ayuda' }, 'Pagos: ', (v.pagos || []).map((p) => `${PAGOS[p.forma] || p.forma}${dinero(p.monto_centavos)}${p.referencia ? ' (ref. ' + p.referencia + ')' : ''}`).join(', ')),
      v.subido_por && v.subido_por !== v.usuario ? h('p', { class: 'ayuda' }, `Subida por ${v.subido_por}.`) : null,
      v.motivo_resolucion ? h('p', { class: 'ayuda' }, `Resuelta por ${v.resuelto_por || ''}: ${v.motivo_resolucion}`) : null,
      botones ? h('div', { class: 'botones' }, botones) : null);
  }

  async function resolver(v, accion) {
    const ok = await pedirMotivo({
      titulo: accion === 'registrar' ? `Registrar ${v.numero_documento}` : `Anular ${v.numero_documento}`,
      peligro: accion === 'anular',
      textoBoton: accion === 'registrar' ? 'Registrar' : 'Anular',
      explicacion: accion === 'registrar'
        ? 'Se registra con su fecha y precios reales, en el turno en que se hizo. Si ese mes ya está cerrado, primero hay que reabrirlo.'
        : 'El número queda ANULADO y el dinero cobrado queda como sobrante de caja hasta devolvérselo al cliente.',
      accion: (motivo) => escribir('resolver_venta_sin_internet', { p_id: v.venta_sin_internet_id, p_accion: accion, p_motivo: motivo }),
    });
    if (ok) { aviso(accion === 'registrar' ? 'Venta registrada.' : 'Venta anulada.'); cargar(); }
  }
}
