// Inicio · "Mi negocio hoy": resumen_hoy, ¿dónde está mi dinero?, aprobaciones y alertas.
// Cada parte sale solo si el servidor la manda (permisos); si una falla, las demás siguen.
import { rpc } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo } from '../sesion.js';
import { dinero, fechaLarga, porcentaje } from '../formato.js';
import { h, cajaError } from '../ui.js';
import { tarjetaAlerta } from './alertas.js';
import { pendientes, listaAprobaciones } from './aprobaciones.js';

function cifra(dato, titulo, centavos, nota, notaPeligro = false) {
  return h('div', { class: 'tarjeta', dataset: { dato } },
    h('p', { class: 'cifra-titulo' }, titulo),
    h('p', { class: 'cifra-valor' }, dinero(centavos)),
    nota ? h('p', { class: 'cifra-nota' + (notaPeligro ? ' peligro' : '') }, nota) : null);
}

function comparar(texto, ayer, pct) {
  return `${texto} ${dinero(ayer)}${pct !== null && pct !== undefined ? ` · ${porcentaje(pct)}` : ''}`;
}

function tarjetasResumen(r) {
  const t = [];
  if (r.ventas_hoy) t.push(cifra('ventas_hoy', 'Ventas de hoy', r.ventas_hoy.total_centavos,
    comparar('Ayer', r.ventas_hoy.ayer_centavos, r.ventas_hoy.porcentaje)));
  if (r.ganancia_hoy) t.push(cifra('ganancia_hoy', '¿Cuánto gané hoy?', r.ganancia_hoy.ganancia_bruta_centavos,
    comparar('Ayer', r.ganancia_hoy.ayer_centavos, r.ganancia_hoy.porcentaje)));
  if (r.ganancia_mes) t.push(cifra('ganancia_mes', 'Ganancia del mes', r.ganancia_mes.ganancia_centavos,
    `Ya cobrada: ${dinero(r.ganancia_mes.ganancia_cobrada_centavos)} · gastos ${dinero(r.ganancia_mes.gastos_centavos)}`));
  if (r.dinero) t.push(cifra('dinero', 'Dinero disponible', r.dinero.disponible_centavos,
    r.dinero.por_confirmar_centavos ? `+ ${dinero(r.dinero.por_confirmar_centavos)} por confirmar` : 'Todo confirmado'));
  if (r.te_deben) t.push(cifra('te_deben', 'Te deben', r.te_deben.total_centavos,
    r.te_deben.vencido_centavos ? `${dinero(r.te_deben.vencido_centavos)} vencido` : 'Nada vencido', r.te_deben.vencido_centavos > 0));
  if (r.debes) t.push(cifra('debes', 'Debes a proveedores', r.debes.total_centavos,
    r.debes.vencido_centavos ? `${dinero(r.debes.vencido_centavos)} vencido` : 'Nada vencido', r.debes.vencido_centavos > 0));
  return t;
}

function tarjetaDinero(d) {
  const transito = (d.en_transito && d.en_transito.depositos) || [];
  const dias = transito.length ? Math.max(...transito.map((t) => t.dias || 0)) : 0;
  const filas = (d.cuentas || []).filter((c) => c.activa !== false).map((c) => h('div', { class: 'fila' },
    h('span', {}, c.nombre,
      c.tipo === 'transito' && dias ? [' ', h('span', { class: 'etiqueta' }, `hace ${dias} días`)] : null,
      c.numero_enmascarado || c.banco
        ? h('span', { class: 'detalle' }, [c.banco, c.numero_enmascarado].filter(Boolean).join(' ')) : null),
    h('span', { class: 'monto' + (c.saldo_centavos < 0 ? ' peligro' : '') }, dinero(c.saldo_centavos))));
  filas.push(h('div', { class: 'fila fila-total' }, h('span', {}, 'Total'),
    h('span', { class: 'monto', dataset: { dato: 'total_dinero' } }, dinero(d.total_centavos))));
  return h('section', { class: 'tarjeta columna-ancha', 'aria-labelledby': 't-donde' },
    h('h2', { id: 't-donde' }, '¿Dónde está mi dinero hoy?'), ...filas);
}

async function parte(promesa) {
  try { return { ok: await promesa }; } catch (err) { return { err }; }
}

export async function mostrar(vista, ctx) {
  const perfil = perfilActual();
  const e = empresaId();
  const verDinero = tieneModulo('dinero') && puede('dinero.ver');
  const verAprob = puede('aprobaciones.ver');

  const [resumen, donde, alertas, aprob] = await Promise.all([
    parte(rpc('resumen_hoy', { p_empresa_id: e })),
    verDinero ? parte(rpc('donde_esta_mi_dinero', { p_empresa_id: e })) : null,
    parte(rpc('alertas_activas', { p_empresa_id: e })),
    verAprob ? parte(pendientes()) : null,
  ]);
  if (!ctx.sigueVigente()) return;

  const nombre = (perfil.usuario.nombre || '').split(' ')[0];
  vista.append(h('div', { class: 'saludo' },
    h('h1', {}, nombre ? `Hola, ${nombre}` : 'Hola'),
    h('p', {}, `${fechaLarga(perfil.empresa.hoy)} · ${perfil.empresa.nombre}`)));

  // Cifras del día
  if (resumen.err) vista.append(await cajaError(resumen.err));
  const r = resumen.ok || {};
  if (r.frase) vista.append(h('p', { class: 'tarjeta frase', dataset: { dato: 'frase' } }, r.frase));
  const cifras = tarjetasResumen(r);
  if (cifras.length) vista.append(h('div', { class: 'cifras' }, cifras));
  else {
    // Puesto sin cifras del negocio (ej. vendedor): atajos a lo que sí puede hacer.
    const atajos = (ctx.menu || []).filter((p) => ['vender', 'clientes', 'inventario', 'caja'].includes(p.id))
      .flatMap((p) => p.subs.slice(0, 2).map((s) => h('a', { class: 'boton boton-ancho', href: `#/${p.id}/${s.id}` }, s.titulo)));
    if (atajos.length) vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-atajos' },
      h('h2', { id: 't-atajos' }, '¿Qué quiere hacer?'), h('div', { class: 'atajos' }, atajos)));
  }

  // Dinero y aprobaciones lado a lado
  const fila = h('div', { class: 'columnas' });
  if (donde) {
    if (donde.err) fila.append(h('section', { class: 'tarjeta columna-ancha' }, await cajaError(donde.err)));
    else fila.append(tarjetaDinero(donde.ok));
  }
  if (aprob) {
    const tarjeta = h('section', { class: 'tarjeta columna-angosta', 'aria-labelledby': 't-aprob-inicio' },
      h('h2', { id: 't-aprob-inicio' }, 'Aprobaciones pendientes'));
    const recargar = async () => {
      // Al aprobar cambia el dinero y las cifras: se vuelve a pintar todo Inicio.
      if (ctx.sigueVigente()) window.dispatchEvent(new HashChangeEvent('hashchange'));
    };
    tarjeta.append(aprob.err ? await cajaError(aprob.err) : listaAprobaciones(aprob.ok, recargar));
    fila.append(tarjeta);
  }
  if (fila.children.length) vista.append(fila);

  // Alertas
  const tAlertas = h('section', { class: 'tarjeta', 'aria-labelledby': 't-alertas-inicio' },
    h('h2', { id: 't-alertas-inicio' }, 'Alertas'));
  if (alertas.err) tAlertas.append(await cajaError(alertas.err));
  else {
    const lista = (alertas.ok && alertas.ok.alertas) || [];
    tAlertas.append(lista.length ? h('div', { class: 'lista' }, lista.slice(0, 6).map(tarjetaAlerta))
      : h('p', { class: 'vacio' }, 'Todo en orden: no hay alertas.'));
    if (lista.length > 6) tAlertas.append(h('a', { class: 'boton', href: '#/inicio/alertas' }, `Ver las ${lista.length} alertas`));
  }
  vista.append(tAlertas);
}
