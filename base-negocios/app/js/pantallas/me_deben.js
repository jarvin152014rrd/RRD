// Clientes · "Quién me debe" (y Caja · "Cobrar a clientes"): clientes con saldo, primero los
// que tienen más vencido. Botones: Cobrar (abre el cobro) y Cobrar por WhatsApp (mensaje amable).
// Lee cxc_para_cobrar (núcleo 0.14.0): el cajero la usa sin ventas.ver y, si está restringido,
// solo ve las facturas de su sucursal.
import { rpc } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero } from '../formato.js';
import { h, icono, titulo, filaIcono, chip, monto, estadoVacio } from '../ui.js';
import { abrirFicha, mensajeCobro, enlaceWhatsApp } from './clientes.js';

export async function mostrar(vista, ctx) {
  const r = await rpc('cxc_para_cobrar', { p_empresa_id: empresaId() });
  if (!ctx.sigueVigente()) return;
  const deben = r.clientes; // ya vienen con más vencido primero
  const tel = new Map(deben.map((c) => [c.cliente_id, c.telefono]));
  const plural = (n, uno, varios) => `${n} ${Number(n) === 1 ? uno : varios}`;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-deben' },
    titulo('h1', 'cobrar', 'Quién me debe', { id: 't-deben' }),
    deben.length ? h('p', { class: 'ayuda' }, 'Primero los que tienen más vencido.',
      r.todas_las_sucursales ? '' : ' Solo ve lo vendido al crédito en su sucursal.') : null,
    deben.length ? h('div', { class: 'lista-filas' }, deben.map((s) => filaIcono({
      icono: 'cliente_mas', color: s.vencido_centavos ? 'rojo' : 'dorado',
      titulo: h('strong', {}, s.cliente),
      detalle: `${plural(s.documentos, 'factura', 'facturas')} · 0-30: ${dinero(s.de_0_a_30)} · 31-60: ${dinero(s.de_31_a_60)} · 61-90: ${dinero(s.de_61_a_90)} · +90: ${dinero(s.mas_de_90)}`,
      derecha: [monto(dinero(s.saldo_centavos), { dato: 'saldo' }),
        s.vencido_centavos ? chip(`Vencido ${dinero(s.vencido_centavos)}`, 'rojo') : chip('Al día', 'verde')],
      abajo: h('div', { class: 'botones' },
        puede('ventas.cobrar') ? h('button', { type: 'button', class: 'boton boton-principal',
          onclick: () => abrirFicha(vista, ctx, s.cliente_id, { cobrar: true }) }, icono('cobrar'), 'Cobrar') : null,
        h('button', { type: 'button', class: 'boton', onclick: () => abrirFicha(vista, ctx, s.cliente_id) }, 'Ver'),
        h('a', { class: 'boton', target: '_blank', rel: 'noopener', dataset: { accion: 'whatsapp' },
          href: enlaceWhatsApp(tel.get(s.cliente_id), mensajeCobro(s.cliente, s.saldo_centavos, s.vencido_centavos)) },
          tel.get(s.cliente_id) ? 'Cobrar por WhatsApp' : 'WhatsApp (sin teléfono)')),
      props: { dataset: { cliente: s.cliente_id } },
    })))
      : estadoVacio({ icono: 'check_circulo', color: 'verde', titulo: 'Nadie le debe', texto: 'Todo está cobrado. Cuando venda al crédito, aquí verá quién le debe y cuánto.' })));
}
