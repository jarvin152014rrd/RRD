// Solicitudes pendientes de aprobación (vista v_aprobacion) con Aprobar / Rechazar.
// Resolver llama resolver_aprobacion con motivo e id_operacion (el servidor revisa topes y permisos).
import { leer, escribir } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, fechaHora } from '../formato.js';
import { h, aviso, pedirMotivo, cajaError } from '../ui.js';

const ROL = { dueno: 'dueño', admin: 'administrador', cajero: 'cajero', vendedor: 'vendedor', contador: 'contador' };
const TIPO = { gasto: 'Gasto', descuento: 'Descuento', credito: 'Venta al crédito', anulacion_venta: 'Anular venta',
  devolucion: 'Devolución', uso_fondo: 'Uso de fondo', conteo: 'Conteo de mercadería' };

export async function pendientes() {
  return leer('v_aprobacion', { empresa_id: empresaId(), estado: 'pendiente' }, { orden: 'solicitado_en.asc', limite: 100 });
}

// Lista con botones. alCambiar() se llama después de aprobar o rechazar.
export function listaAprobaciones(filas, alCambiar) {
  if (!filas.length) return h('p', { class: 'vacio' }, 'No hay solicitudes esperando su decisión.');
  return h('div', { class: 'lista' }, filas.map((a) => {
    const quien = `${a.solicitante || 'Alguien'}${a.rol_solicitante ? ` (${ROL[a.rol_solicitante] || a.rol_solicitante})` : ''}`;
    const resolver = (aprobar) => pedirMotivo({
      titulo: aprobar ? 'Aprobar solicitud' : 'Rechazar solicitud',
      explicacion: `${TIPO[a.tipo] || a.tipo} por ${dinero(a.monto_centavos)}: ${a.descripcion}`,
      textoBoton: aprobar ? 'Aprobar' : 'Rechazar',
      peligro: !aprobar,
      accion: (motivo) => escribir('resolver_aprobacion', { p_aprobacion_id: a.aprobacion_id, p_aprobar: aprobar, p_motivo: motivo }),
    }).then((hecho) => {
      if (hecho) { aviso(aprobar ? 'Solicitud aprobada.' : 'Solicitud rechazada.'); alCambiar(); }
    });
    return h('article', { class: 'solicitud', dataset: { aprobacion: a.aprobacion_id } },
      h('p', {}, h('strong', {}, `${TIPO[a.tipo] || a.tipo} · `), h('span', { class: 'monto' }, dinero(a.monto_centavos))),
      h('p', {}, a.descripcion),
      h('p', { class: 'ayuda' }, `Pide: ${quien} · ${fechaHora(a.solicitado_en)}`,
        a.falta_segunda_aprobacion ? ' · falta la segunda aprobación' : ''),
      h('div', { class: 'botones' },
        h('button', { type: 'button', class: 'boton boton-principal', onclick: () => resolver(true) }, 'Aprobar'),
        h('button', { type: 'button', class: 'boton', onclick: () => resolver(false) }, 'Rechazar')));
  }));
}

export async function mostrar(vista, ctx) {
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-aprob' }, h('h1', { id: 't-aprob' }, 'Aprobaciones pendientes'));
  vista.append(tarjeta);
  const pintar = async () => {
    const zona = h('div', {});
    try { zona.append(listaAprobaciones(await pendientes(), pintar)); } catch (err) { zona.append(await cajaError(err)); }
    tarjeta.replaceChildren(tarjeta.firstChild, zona);
  };
  await pintar();
}
