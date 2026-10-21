// Dinero · "¿Dónde está mi dinero?" (donde_esta_mi_dinero, permiso dinero.ver): saldo de cada
// caja y banco, lo que está en tránsito y el total. Antes estaba dentro de Inicio (app 0.4.0).
import { rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero } from '../formato.js';
import { h, icono, chip, burbuja, cajaError } from '../ui.js';

// Ícono y color por tipo de cuenta (azul = información; dorado = por confirmar).
const TIPO = {
  efectivo_caja: ['caja', 'azul'], caja_chica: ['billetes', 'azul'], banco: ['banco', 'azul'],
  transito: ['deposito', 'dorado'], pos_por_liquidar: ['reloj', 'dorado'], transferencia_por_confirmar: ['reloj', 'dorado'],
};

export function tarjetaDinero(d) {
  const transito = (d.en_transito && d.en_transito.depositos) || [];
  const dias = transito.length ? Math.max(...transito.map((t) => t.dias || 0)) : 0;
  const filas = (d.cuentas || []).filter((c) => c.activa !== false).map((c) => {
    const [ic, color] = TIPO[c.tipo] || ['dinero', 'azul'];
    return h('div', { class: 'fila-icono' }, burbuja(ic, c.saldo_centavos < 0 ? 'rojo' : color, { class: 'burbuja-chica' }),
      h('div', { class: 'fila-icono-texto' },
        h('div', { class: 'fila-icono-titulo' }, c.nombre,
          c.tipo === 'transito' && dias ? [' ', chip(`hace ${dias} días`, 'dorado')] : null),
        c.numero_enmascarado || c.banco
          ? h('div', { class: 'fila-icono-detalle' }, [c.banco, c.numero_enmascarado].filter(Boolean).join(' ')) : null),
      h('span', { class: 'monto' + (c.saldo_centavos < 0 ? ' peligro' : '') }, dinero(c.saldo_centavos)));
  });
  filas.push(h('div', { class: 'fila fila-total' }, h('span', {}, 'Total'),
    h('span', { class: 'monto', dataset: { dato: 'total_dinero' } }, dinero(d.total_centavos))));
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-donde' },
    h('h1', { id: 't-donde', class: 'titulo-icono' }, icono('banco'), '¿Dónde está mi dinero hoy?'), ...filas);
}

export async function mostrar(vista, ctx) {
  try {
    const d = await rpc('donde_esta_mi_dinero', { p_empresa_id: empresaId() });
    if (!ctx.sigueVigente()) return;
    vista.append(tarjetaDinero(d));
  } catch (err) {
    vista.append(await cajaError(err));
  }
}
