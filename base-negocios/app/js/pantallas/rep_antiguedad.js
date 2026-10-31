// Reportes · "Antigüedad de saldos" (app 0.12.0, núcleo 0.18.0). Solo mirar.
//   antiguedad_saldos(empresa, al, tipo): por cliente (o proveedor) lo corriente (no vencido) y lo vencido de
//   1-30, 31-60, 61-90 y más de 90 días a la fecha de corte, con totales; incluye saldos iniciales y respeta la
//   sucursal. El servidor dice si cuadra con la cuenta de Clientes (o Proveedores) de los libros.
//   Chips de color: más rojo mientras más viejo. Clic en el cliente: su estado de cuenta (Clientes).
//   Excel e Imprimir con botonesReporte (lo impreso sin íconos ni colores).
import { rpc } from '../api.js';
import { empresaId, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha } from '../formato.js';
import { h, cajaError, titulo, mensaje, tabla, estadoVacio } from '../ui.js';
import { reiniciarAlSalir } from '../datos.js';
import { hoy, inputFecha, cifraChica } from '../formularios.js';
import { botonesReporte } from '../reportes.js';
import { abrirFicha as fichaCliente } from './clientes.js';
import { abrirFicha as fichaProveedor } from './compras_proveedores.js';

// Tramos en orden (de lo más nuevo a lo más viejo) con su color: el último, el más rojo.
const TRAMOS = [
  ['corriente', 'Corriente', 'tramo-0'], ['de_1_a_30', '1 a 30', 'tramo-1'], ['de_31_a_60', '31 a 60', 'tramo-2'],
  ['de_61_a_90', '61 a 90', 'tramo-3'], ['mas_de_90', 'Más de 90', 'tramo-4'],
];
const ORDEN = { saldo: 'Mayor saldo', vencido: 'Más vencido', nombre: 'Nombre (A-Z)' };

let filtro = { al: null, tipo: 'cxc', orden: 'saldo' };
reiniciarAlSalir(() => { filtro = { al: null, tipo: 'cxc', orden: 'saldo' }; });

// Un monto de un tramo como chip de color (nada si es cero).
function chipTramo(centavos, clase, dato) {
  return Number(centavos) ? h('span', { class: `chip-color chip-tramo ${clase}`, dataset: { dato } }, dinero(centavos)) : h('span', { class: 'detalle' }, '—');
}

export async function mostrar(vista, ctx) {
  const verCxc = tieneModulo('ventas') && puede('ventas.ver', 'cobros.ver_saldos');
  const verCxp = tieneModulo('compras') && puede('compras.ver');
  if (!verCxc && filtro.tipo === 'cxc') filtro.tipo = 'cxp';
  const al = inputFecha('antiguedad-al', filtro.al || hoy());
  const selTipo = h('select', { id: 'antiguedad-tipo' },
    verCxc ? h('option', { value: 'cxc' }, 'Me deben (clientes)') : null, verCxp ? h('option', { value: 'cxp' }, 'Debo (proveedores)') : null);
  selTipo.value = filtro.tipo;
  const selOrden = h('select', { id: 'antiguedad-orden' }, Object.entries(ORDEN).map(([v, t]) => h('option', { value: v }, t)));
  selOrden.value = filtro.orden;
  const zona = h('div', { class: 'lista' });
  let r = null;
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-antig' },
    titulo('h1', 'antiguedad', 'Antigüedad de saldos', { id: 't-antig' }),
    h('p', { class: 'ayuda' }, 'Cuánto se debe y hace cuánto venció, a la fecha que elija. "Corriente" = todavía no vence.'),
    h('div', { class: 'dos-columnas filtros' },
      h('div', { class: 'campo' }, h('label', { for: 'antiguedad-al' }, 'Al día'), al),
      h('div', { class: 'campo' }, h('label', { for: 'antiguedad-tipo' }, '¿De quién?'), selTipo),
      h('div', { class: 'campo' }, h('label', { for: 'antiguedad-orden' }, 'Ordenar por'), selOrden)),
    botonesReporte('antiguedad', () => documento(r, filtro)), zona));
  al.addEventListener('change', () => { filtro.al = al.value || null; cargar(); });
  selTipo.addEventListener('change', () => { filtro.tipo = selTipo.value; cargar(); });
  selOrden.addEventListener('change', () => { filtro.orden = selOrden.value; pintar(); });

  let vez = 0;
  async function cargar() {
    const mia = ++vez;
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    try {
      const x = await rpc('antiguedad_saldos', { p_empresa_id: empresaId(), p_al: filtro.al || hoy(), p_tipo: filtro.tipo });
      if (mia !== vez || !ctx.sigueVigente()) return;
      r = x;
      pintar();
    } catch (err) {
      if (mia === vez) zona.replaceChildren(await cajaError(err));
    }
  }

  function pintar() {
    if (!r) return;
    const t = r.totales;
    const lista = ordenar(r.terceros, filtro.orden);
    const quien = r.tipo === 'cxc' ? 'Cliente' : 'Proveedor';
    const abrir = (x) => (r.tipo === 'cxc' ? fichaCliente : fichaProveedor)(vista, ctx, x.tercero_id);
    zona.replaceChildren(...[
      h('div', { class: 'cifras' },
        cifraChica(r.tipo === 'cxc' ? 'Me deben' : 'Debo', dinero(t.saldo_centavos), { dato: 'antiguedad-total' }),
        cifraChica('Vencido', dinero(t.vencido_centavos), { dato: 'antiguedad-vencido', clase: Number(t.vencido_centavos) ? 'monto-sale' : '' }),
        cifraChica('Más de 90 días', dinero(t.mas_de_90_centavos), { dato: 'antiguedad-90', clase: Number(t.mas_de_90_centavos) ? 'monto-sale' : '' })),
      r.cuadra === true ? h('p', { class: 'ayuda', dataset: { info: 'cuadra' } }, `Cuadra con la cuenta ${r.cuenta_libros} de los libros al ${fecha(r.al)}.`) : null,
      r.cuadra === false ? mensaje('error', `No cuadra con la cuenta ${r.cuenta_libros}: los libros dicen ${dinero(r.saldo_libros_centavos)}.`,
        'Avise a su contador o a soporte.', { dataset: { info: 'no-cuadra' } }) : null,
      r.solo_mis_sucursales ? mensaje('info', 'Solo sus sucursales', r.nota_sucursal, { dataset: { info: 'solo-sucursales' } }) : null,
      lista.length ? tabla({ props: { id: 'tabla-antiguedad' },
        columnas: [{ titulo: quien }, ...TRAMOS.map(([, tt]) => ({ titulo: tt, num: true })), { titulo: 'Total', num: true }],
        filas: [...lista.map((x) => [
          h('button', { type: 'button', class: 'enlace', dataset: { tercero: x.tercero_id }, 'aria-label': `Estado de cuenta de ${x.nombre}`,
            onclick: () => abrir(x) }, x.nombre),
          ...TRAMOS.map(([k, , clase]) => chipTramo(x[`${k}_centavos`], clase, `${k}-${x.tercero_id}`)),
          h('strong', { class: 'monto' }, dinero(x.saldo_centavos))]),
        [h('strong', {}, 'Total'), ...TRAMOS.map(([k]) => h('strong', { class: 'monto', dataset: { dato: `total-${k}` } }, dinero(t[`${k}_centavos`]))),
          h('strong', { class: 'monto' }, dinero(t.saldo_centavos))]] })
        : estadoVacio({ icono: 'check_circulo', color: 'verde', texto: r.tipo === 'cxc' ? 'Nadie le debe a esa fecha.' : 'No le debe a nadie a esa fecha.' }),
    ].filter(Boolean));
  }
  await cargar();
}

export function ordenar(lista, orden) {
  const l = [...(lista || [])];
  if (orden === 'nombre') return l.sort((a, b) => String(a.nombre).localeCompare(String(b.nombre), 'es'));
  if (orden === 'vencido') return l.sort((a, b) => Number(b.mas_de_90_centavos) - Number(a.mas_de_90_centavos) || Number(b.vencido_centavos) - Number(a.vencido_centavos));
  return l.sort((a, b) => Number(b.saldo_centavos) - Number(a.saldo_centavos));
}

// Documento para Excel e Imprimir (lo impreso va sin colores ni íconos).
function documento(r, f) {
  if (!r) return null;
  const cols = [{ titulo: r.tipo === 'cxc' ? 'Cliente' : 'Proveedor', tipo: 'texto' }, ...TRAMOS.map(([, t]) => ({ titulo: t === 'Corriente' ? 'Corriente' : `${t} días`, tipo: 'dinero' })),
    { titulo: 'Total', tipo: 'dinero' }];
  return { titulo: r.titulo, periodo: `al ${fecha(r.al)}`,
    notas: ['Corriente = todavía no vence. Los demás: días que lleva vencido a esa fecha.',
      r.cuadra === true ? `Cuadra con la cuenta ${r.cuenta_libros} de los libros.` : null, r.solo_mis_sucursales ? r.nota_sucursal : null].filter(Boolean),
    secciones: [{ titulo: r.titulo, columnas: cols,
      filas: ordenar(r.terceros, f.orden).map((x) => [x.nombre, ...TRAMOS.map(([k]) => x[`${k}_centavos`]), x.saldo_centavos]),
      total: ['Total', ...TRAMOS.map(([k]) => r.totales[`${k}_centavos`]), r.totales.saldo_centavos] }] };
}
