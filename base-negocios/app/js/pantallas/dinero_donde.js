// Dinero · "¿Dónde está mi dinero?" (donde_esta_mi_dinero, permiso dinero.ver): saldo de cada
// caja y banco, lo que está en tránsito y el total. Antes estaba dentro de Inicio (app 0.4.0).
// app 0.10.0 (núcleo 0.16.0): debajo, las ENTRADAS de dinero de los socios este mes (aportes de capital,
// aportes_socios), que no son ganancia. Con un núcleo 0.15.0 esa parte no se muestra.
import { rpc, rpcSiExiste } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha } from '../formato.js';
import { h, icono, chip, burbuja, cajaError, mensaje, filaIcono, monto } from '../ui.js';
import { hoy } from '../formularios.js';

// Ícono y color por tipo de cuenta (azul = información; dorado = por confirmar).
const TIPO = {
  efectivo_caja: ['caja', 'azul'], caja_chica: ['billetes', 'azul'], banco: ['banco', 'azul'],
  transito: ['deposito', 'dorado'], pos_por_liquidar: ['reloj', 'dorado'], transferencia_por_confirmar: ['reloj', 'dorado'],
  cheques_por_depositar: ['cheque', 'dorado'],   // núcleo 0.18.0: cheques recibidos, todavía no es efectivo
};

// sucursales: null = ve todas; lista de ids = usuario limitado a esas sucursales (mi_estado_sesion).
// donde_esta_mi_dinero (núcleo 0.15.0) trae las cuentas de TODA la empresa: a un usuario limitado
// solo se le muestran las de sus sucursales y las de toda la empresa (sin sucursal, como el banco),
// y el total es la suma de esas. (Arreglo de fondo pendiente en el núcleo: ver PENDIENTES.)
export function tarjetaDinero(d, sucursales = null) {
  const ve = (c) => !sucursales || !c.sucursal_id || sucursales.includes(c.sucursal_id);
  const transito = (d.en_transito && d.en_transito.depositos) || [];
  const dias = transito.length ? Math.max(...transito.map((t) => t.dias || 0)) : 0;
  // Las cuentas desactivadas que todavía tienen saldo SÍ salen (marcadas): el total del servidor las incluye.
  const cuentas = (d.cuentas || []).filter((c) => (c.activa !== false || Number(c.saldo_centavos) !== 0) && ve(c));
  const total = sucursales ? cuentas.reduce((x, c) => x + (Number(c.saldo_centavos) || 0), 0) : d.total_centavos;
  const filas = cuentas.map((c) => {
    const [ic, color] = TIPO[c.tipo] || ['dinero', 'azul'];
    return h('div', { class: 'fila-icono' }, burbuja(ic, c.saldo_centavos < 0 ? 'rojo' : color, { class: 'burbuja-chica' }),
      h('div', { class: 'fila-icono-texto' },
        h('div', { class: 'fila-icono-titulo' }, c.nombre,
          c.tipo === 'transito' && dias ? [' ', chip(`hace ${dias} días`, 'dorado')] : null,
          c.activa === false ? [' ', chip('Desactivada', 'neutro')] : null),
        c.numero_enmascarado || c.banco
          ? h('div', { class: 'fila-icono-detalle' }, [c.banco, c.numero_enmascarado].filter(Boolean).join(' ')) : null,
        c.tipo === 'cheques_por_depositar' && d.cheques_por_depositar ? h('div', { class: 'fila-icono-detalle', dataset: { dato: 'cheques-detalle' } },
          `${d.cheques_por_depositar.cantidad} ${d.cheques_por_depositar.cantidad === 1 ? 'cheque' : 'cheques'} por depositar · no es efectivo todavía`
          + (d.cheques_por_depositar.posfechados_centavos ? ` · ${dinero(d.cheques_por_depositar.posfechados_centavos)} posfechados` : '')) : null),
      h('span', { class: 'monto' + (c.saldo_centavos < 0 ? ' peligro' : '') }, dinero(c.saldo_centavos)));
  });
  filas.push(h('div', { class: 'fila fila-total' }, h('span', {}, 'Total'), h('span', { class: 'monto' }, dinero(total))));

  // App 0.15.0 (idea de RRD: "¿Dónde está el dinero de verdad?"): arriba el total grande y tres grupos que se
  // entienden de un vistazo. Los grupos solo SUMAN las cuentas de abajo (no calculan nada nuevo).
  const suma = (tipos) => cuentas.filter((c) => tipos.includes(c.tipo)).reduce((x, c) => x + (Number(c.saldo_centavos) || 0), 0);
  const hay = (tipos) => cuentas.some((c) => tipos.includes(c.tipo));
  const otros = cuentas.filter((c) => !Object.prototype.hasOwnProperty.call(TIPO, c.tipo)).reduce((x, c) => x + (Number(c.saldo_centavos) || 0), 0);
  const grupos = [
    ['billetes', 'Efectivo en cajas', ['efectivo_caja', 'caja_chica'], 'Billetes y monedas del negocio', 'efectivo'],
    ['banco', 'En bancos', ['banco'], 'Cuentas de banco', 'bancos'],
    ['reloj', 'En camino', ['transito', 'pos_por_liquidar', 'transferencia_por_confirmar', 'cheques_por_depositar'],
      'Depósitos, tarjetas, transferencias y cheques que aún no llegan', 'en_camino'],
  ].filter(([, , tipos]) => hay(tipos)).map(([ic, nombre, tipos, ayuda, dato]) => {
    const v = suma(tipos) + (dato === 'efectivo' ? otros : 0);
    return h('div', { class: 'dinero-grupo', dataset: { grupo: dato } },
      h('div', { class: 'dinero-grupo-cabeza' }, icono(ic), h('span', {}, nombre)),
      h('p', { class: 'dinero-grupo-monto monto' + (v < 0 ? ' peligro' : '') }, dinero(v)),
      h('p', { class: 'dinero-grupo-ayuda' }, ayuda));
  });
  const portada = h('div', { class: 'dinero-portada' },
    h('h1', { id: 't-donde', class: 'titulo-icono' }, icono('banco'), '¿Dónde está mi dinero hoy?'),
    h('p', { class: 'dinero-total monto', dataset: { dato: 'total_dinero' } }, dinero(total)),
    h('p', { class: 'dinero-total-ayuda' }, 'Todo el dinero del negocio, sumando cada caja, banco y lo que viene en camino.'),
    grupos.length ? h('div', { class: 'dinero-grupos' }, grupos) : null);
  return h('section', { class: 'tarjeta tarjeta-dinero', 'aria-labelledby': 't-donde' },
    portada,
    sucursales ? mensaje('info', 'Usted ve solo el dinero de sus sucursales.',
      'Más las cuentas de toda la empresa, como el banco. El total es la suma de lo que aparece aquí.', { dataset: { info: 'solo-sucursales' } }) : null,
    h('h2', { class: 'titulo-chico dinero-detalle-titulo' }, 'Cuenta por cuenta'),
    ...filas);
}

// Aportes de capital de los socios que entraron este mes (lista; el servidor ya filtra por sucursal).
export function tarjetaAportesMes(a, desde) {
  const lista = ((a && a.aportes) || []).filter((x) => !x.anulada && x.fecha >= desde);
  if (!lista.length) return null;
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-aportes-mes', id: 'aportes-mes' },
    h('h2', { id: 't-aportes-mes', class: 'titulo-icono' }, icono('sube'), 'Entró de los socios este mes'),
    h('p', { class: 'ayuda' }, 'Aportes de capital: el dinero ya está sumado en la cuenta donde entró. Es dinero de los socios, no es ganancia.'),
    lista.map((x) => filaIcono({ icono: 'sube', color: 'verde', titulo: h('strong', {}, `Aporte de ${x.socio}`),
      detalle: [fecha(x.fecha), x.cuenta ? `entró a ${x.cuenta}` : null, x.nota].filter(Boolean).join(' · '),
      derecha: monto(dinero(x.monto_centavos), { sentido: 'entra', signo: '+' }), props: { dataset: { aporteMes: x.aporte_id } } })));
}

export async function mostrar(vista, ctx) {
  try {
    const conAportes = puede('fondos.ver') && tieneModulo('fondos');
    const [d, estado, aportes] = await Promise.all([rpc('donde_esta_mi_dinero', { p_empresa_id: empresaId() }),
      rpc('mi_estado_sesion', { p_empresa_id: empresaId() }),
      // Solo los del mes (núcleo 0.16.0: desde el día 1).
      conAportes ? rpcSiExiste('aportes_socios', { p_empresa_id: empresaId(), p_desde: hoy().slice(0, 8) + '01' }).catch(() => null) : null]);
    if (!ctx.sigueVigente()) return;
    const limitado = estado && estado.todas_las_sucursales === false;
    vista.append(tarjetaDinero(d, limitado ? (estado.sucursales || []).map((x) => x.sucursal_id) : null));
    const extra = tarjetaAportesMes(aportes, hoy().slice(0, 8) + '01');
    if (extra) vista.append(extra);
  } catch (err) {
    vista.append(await cajaError(err));
  }
}
