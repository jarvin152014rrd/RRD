// Solicitudes pendientes de aprobación (vista v_aprobacion) con Aprobar / Rechazar.
// Resolver llama resolver_aprobacion con motivo e id_operacion (el servidor revisa topes y permisos).
// Desde app 0.5.0 se muestran en Inicio (tarjeta Pendientes) y en Inicio > Pendientes.
import { leer, escribir } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fechaHora } from '../formato.js';
import { h, aviso, pedirMotivo, filaIcono, estadoVacio } from '../ui.js';

const ROL = { dueno: 'dueño', admin: 'administrador', cajero: 'cajero', vendedor: 'vendedor', contador: 'contador' };
const TIPO = { venta: 'Venta por aprobar', gasto: 'Gasto', descuento: 'Descuento', credito: 'Venta al crédito', anulacion_venta: 'Anular venta',
  devolucion: 'Devolución', uso_fondo: 'Uso de fondo', conteo: 'Conteo de mercadería', conteo_fisico: 'Conteo de mercadería' };
// Ícono y color por tipo: rojo = sale dinero; dorado = importante; azul = información.
const ICONO = { gasto: ['recibo', 'rojo'], descuento: ['impuestos', 'dorado'], credito: ['clientes', 'azul'],
  anulacion_venta: ['anular', 'rojo'], devolucion: ['devolucion', 'rojo'], uso_fondo: ['capas', 'dorado'],
  conteo: ['conteo', 'azul'], conteo_fisico: ['conteo', 'azul'] };

// Permiso que el núcleo exige para resolver cada tipo (resolver_aprobacion y sus funciones internas).
// Quien no lo tiene (p. ej. el contador) ve la solicitud sin botones.
const PERMISO = { gasto: 'gastos.aprobar', uso_fondo: 'fondos.aprobar', venta: 'ventas.aprobar', descuento: 'ventas.aprobar',
  credito: 'ventas.aprobar', devolucion: 'ventas.aprobar', anulacion_venta: 'ventas.anular',
  conteo: 'inventario.ajustar', conteo_fisico: 'inventario.ajustar' };
export function puedeResolver(tipo) { return Boolean(PERMISO[tipo]) && puede(PERMISO[tipo]); }

export async function pendientes() {
  return leer('v_aprobacion', { empresa_id: empresaId(), estado: 'pendiente' }, { orden: 'solicitado_en.asc', limite: 100 });
}

// Lista con botones. alCambiar() se llama después de aprobar o rechazar.
export function listaAprobaciones(filas, alCambiar) {
  if (!filas.length) return estadoVacio({ icono: 'check_circulo', color: 'verde', texto: 'No hay solicitudes esperando su decisión.' });
  return h('div', { class: 'lista-filas' }, filas.map((a) => {
    const quien = `${a.solicitante || 'Alguien'}${a.rol_solicitante ? ` (${ROL[a.rol_solicitante] || a.rol_solicitante})` : ''}`;
    const resolver = (aprobar) => pedirMotivo({
      titulo: aprobar ? 'Aprobar solicitud' : 'Rechazar solicitud',
      explicacion: `${TIPO[a.tipo] || a.tipo} por ${dinero(a.monto_centavos)}: ${a.descripcion}`,
      textoBoton: aprobar ? 'Aprobar' : 'Rechazar',
      peligro: !aprobar,
      accion: (motivo) => escribir('resolver_aprobacion', { p_aprobacion_id: a.aprobacion_id, p_aprobar: aprobar, p_motivo: motivo }),
    }).then((hecho) => {
      if (hecho) {
        aviso(`${aprobar ? 'Solicitud aprobada' : 'Solicitud rechazada'} · ${TIPO[a.tipo] || a.tipo} ${dinero(a.monto_centavos)}`);
        window.dispatchEvent(new Event('pendientes-cambiaron'));
        alCambiar();
      }
    });
    const [ic, color] = ICONO[a.tipo] || ['pendientes', 'azul'];
    return filaIcono({
      icono: ic, color,
      titulo: [h('strong', {}, `${TIPO[a.tipo] || a.tipo} · `), h('span', { class: 'monto' }, dinero(a.monto_centavos))],
      detalle: [a.descripcion, h('br'), `Pide: ${quien} · ${fechaHora(a.solicitado_en)}`,
        a.falta_segunda_aprobacion ? ' · falta la segunda aprobación' : ''],
      abajo: puedeResolver(a.tipo) ? h('div', { class: 'botones' },
        h('button', { type: 'button', class: 'boton boton-principal', onclick: () => resolver(true) }, 'Aprobar'),
        h('button', { type: 'button', class: 'boton', onclick: () => resolver(false) }, 'Rechazar'))
        : h('p', { class: 'ayuda', dataset: { info: 'espera-aprobacion' } }, 'Espera aprobación del dueño o de quien tenga permiso para aprobarla.'),
      props: { class: 'solicitud', dataset: { aprobacion: a.aprobacion_id } },
    });
  }));
}

// La pantalla sola ya no está en el menú: Pendientes la reemplaza (la ruta vieja lleva allí).
export async function mostrar(vista, ctx) {
  const { mostrar: pantalla } = await import('./pendientes.js');
  return pantalla(vista, ctx);
}
