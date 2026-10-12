// Clientes · "Quién me debe" (y Caja · "Cobrar a clientes"): clientes con saldo, primero los
// que tienen más vencido. Botones: Cobrar (abre el cobro) y Cobrar por WhatsApp (mensaje amable).
// Lee cxc_para_cobrar (núcleo 0.14.0): el cajero la usa sin ventas.ver y, si está restringido,
// solo ve las facturas de su sucursal.
import { rpc } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero } from '../formato.js';
import { h } from '../ui.js';
import { abrirFicha, mensajeCobro, enlaceWhatsApp } from './clientes.js';

export async function mostrar(vista, ctx) {
  const r = await rpc('cxc_para_cobrar', { p_empresa_id: empresaId() });
  if (!ctx.sigueVigente()) return;
  const deben = r.clientes; // ya vienen con más vencido primero
  const tel = new Map(deben.map((c) => [c.cliente_id, c.telefono]));
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-deben' },
    h('h1', { id: 't-deben' }, 'Quién me debe'),
    h('p', { class: 'ayuda' }, 'Primero los que tienen más vencido.',
      r.todas_las_sucursales ? '' : ' Solo ve lo vendido al crédito en su sucursal.'),
    deben.length ? h('div', { class: 'lista' }, deben.map((s) => h('article', { class: 'venta-fila', dataset: { cliente: s.cliente_id } },
      h('div', {}, h('strong', {}, s.cliente),
        h('span', { class: 'detalle' }, `${s.documentos} factura(s) · 0-30: ${dinero(s.de_0_a_30)} · 31-60: ${dinero(s.de_31_a_60)} · 61-90: ${dinero(s.de_61_a_90)} · +90: ${dinero(s.mas_de_90)}`),
        s.vencido_centavos ? h('span', { class: 'etiqueta etiqueta-peligro' }, `Vencido ${dinero(s.vencido_centavos)}`) : null),
      h('span', { class: 'monto', dataset: { dato: 'saldo' } }, dinero(s.saldo_centavos)),
      h('div', { class: 'botones' },
        puede('ventas.cobrar') ? h('button', { type: 'button', class: 'boton boton-principal',
          onclick: () => abrirFicha(vista, ctx, s.cliente_id, { cobrar: true }) }, 'Cobrar') : null,
        h('button', { type: 'button', class: 'boton', onclick: () => abrirFicha(vista, ctx, s.cliente_id) }, 'Ver'),
        h('a', { class: 'boton', target: '_blank', rel: 'noopener', dataset: { accion: 'whatsapp' },
          href: enlaceWhatsApp(tel.get(s.cliente_id), mensajeCobro(s.cliente, s.saldo_centavos, s.vencido_centavos)) },
          tel.get(s.cliente_id) ? 'Cobrar por WhatsApp' : 'WhatsApp (sin teléfono)')))))
      : h('p', { class: 'vacio' }, 'Nadie le debe. ¡Todo cobrado!')));
}
