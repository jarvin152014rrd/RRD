// Inicio · "Pendientes": une las aprobaciones (solo con aprobaciones.ver) y las alertas
// (alertas_activas: cada quien ve lo que sus permisos le dejan). El número sale en la
// campanita del encabezado y en la subpestaña.
import { puede } from '../sesion.js';
import { h, icono, cajaError, estadoVacio, titulo, cabezaPantalla } from '../ui.js';
import { tarjetaAlerta, leerAlertas } from './alertas.js';
import { pendientes, listaAprobaciones } from './aprobaciones.js';

async function parte(promesa) {
  try { return { ok: await promesa }; } catch (err) { return { err }; }
}

export async function mostrar(vista, ctx) {
  const verAprob = puede('aprobaciones.ver');
  const [alertas, aprob] = await Promise.all([parte(leerAlertas(verAprob)), verAprob ? parte(pendientes()) : null]);
  if (!ctx.sigueVigente()) return;
  if (!alertas.err && (!aprob || !aprob.err)) {
    window.dispatchEvent(new CustomEvent('pendientes-conteo', { detail: alertas.ok.length + (aprob ? aprob.ok.length : 0) }));
  }

  vista.append(cabezaPantalla(ctx, titulo('h1', 'pendientes', 'Pendientes', { class: 'titulo-pantalla' }),
    h('p', { class: 'ayuda' }, 'Lo que espera su decisión y los avisos del negocio.')));
  if (aprob) {
    const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-aprob' },
      h('h2', { id: 't-aprob', class: 'titulo-icono' }, icono('check_circulo'), 'Aprobaciones pendientes'));
    tarjeta.append(aprob.err ? await cajaError(aprob.err)
      : listaAprobaciones(aprob.ok, () => { if (ctx.sigueVigente()) window.dispatchEvent(new HashChangeEvent('hashchange')); }));
    vista.append(tarjeta);
  }
  const tAlertas = h('section', { class: 'tarjeta', 'aria-labelledby': 't-alertas' },
    h('h2', { id: 't-alertas', class: 'titulo-icono' }, icono('alerta'), 'Alertas'));
  if (alertas.err) tAlertas.append(await cajaError(alertas.err));
  else tAlertas.append(alertas.ok.length ? h('div', { class: 'lista-filas' }, alertas.ok.map(tarjetaAlerta))
    : estadoVacio({ icono: 'check_circulo', color: 'verde', texto: 'Todo en orden: no hay alertas.' }));
  vista.append(tAlertas);
}
