// Reportes · "Quién hizo qué" (app 0.8.0). Solo mirar.
//   bitacora_legible (núcleo 047, bitacora.ver): cada cambio en palabras sencillas ("Ana Sosa creó una venta
//   #15 · motivo: …"), con filtros por fecha, persona y tipo, de 100 en 100 ("Ver más").
//   verificar_bitacora (núcleo 002): revisa la cadena de huellas; sin problemas = nadie la cambió por fuera.
//   Es de TODA la empresa: a un usuario limitado a su sucursal no se le muestra (ver PENDIENTES).
import { leer, rpc } from '../api.js';
import { empresaId } from '../sesion.js';
import { fecha, sumarDias } from '../formato.js';
import { h, icono, cajaError, titulo, chip, estadoVacio, mensaje, filaIcono } from '../ui.js';
import { alcance, reiniciarAlSalir } from '../datos.js';
import { hoy, inputFecha } from '../formularios.js';
import { botonesReporte } from '../reportes.js';

const TIPOS = { ventas: ['Ventas y cobros', 'vender'], dinero: ['Dinero y caja', 'dinero'], inventario: ['Inventario', 'inventario'],
  productos: ['Productos y precios', 'etiqueta'], compras: ['Compras', 'compras'], usuarios: ['Usuarios y permisos', 'usuarios'],
  configuracion: ['Configuración', 'ajustes'], aprobaciones: ['Aprobaciones', 'check_circulo'], contabilidad: ['Contabilidad y cierres', 'cierre'], otros: ['Otros', 'lista'] };
let filtros = null;
const filtrosIniciales = () => ({ desde: sumarDias(hoy(), -6), hasta: hoy(), usuario_id: '', tipo: '' });
reiniciarAlSalir(() => { filtros = null; });

// Texto de una fila: "María López creó una venta #15 · motivo: …"
export const textoFila = (f) => `${f.texto}${f.motivo ? ` · motivo: ${f.motivo}` : ''}`;

export async function mostrar(vista, ctx) {
  const [al, usuarios] = await Promise.all([alcance(), leer('usuario_empresa', { empresa_id: empresaId() }, { orden: 'nombre.asc' }).catch(() => [])]);
  if (!ctx.sigueVigente()) return;
  const tarjeta = h('section', { class: 'tarjeta', 'aria-labelledby': 't-bitacora' }, titulo('h1', 'bitacora', 'Quién hizo qué', { id: 't-bitacora' }));
  vista.append(tarjeta);
  if (al.limitado) {
    tarjeta.append(estadoVacio({ icono: 'bitacora', titulo: 'La bitácora es de toda la empresa',
      texto: 'Usted trabaja solo con sus sucursales, por eso no la ve. Pídasela al dueño.' }));
    return;
  }
  if (!filtros) filtros = filtrosIniciales();
  const desde = inputFecha('bit-desde', filtros.desde, { max: hoy() });
  const hasta = inputFecha('bit-hasta', filtros.hasta, { max: hoy() });
  const persona = h('select', { id: 'bit-persona' }, h('option', { value: '' }, 'Todas las personas'),
    usuarios.filter((u) => u.rol !== 'proveedor').map((u) => h('option', { value: u.user_id }, u.nombre || 'Sin nombre')));
  persona.value = filtros.usuario_id;
  const tipo = h('select', { id: 'bit-tipo' }, h('option', { value: '' }, 'Todo'), Object.entries(TIPOS).map(([v, [t]]) => h('option', { value: v }, t)));
  tipo.value = filtros.tipo;
  const integridad = h('div', { id: 'bit-integridad', 'aria-live': 'polite' }, h('p', { class: 'cargando', role: 'status' }, 'Revisando que nadie haya cambiado la bitácora…'));
  const zona = h('div', { class: 'lista' });
  const zonaError = h('div', { 'aria-live': 'polite' });
  let filas = [];
  let siguiente = null;
  tarjeta.append(
    h('p', { class: 'ayuda' }, 'Cada cambio que se guarda queda aquí con quién, cuándo y por qué. Nadie la puede borrar ni editar.'),
    integridad,
    h('div', { class: 'filtros' },
      h('div', { class: 'dos-columnas' },
        h('div', { class: 'campo' }, h('label', { for: 'bit-desde' }, 'Desde'), desde),
        h('div', { class: 'campo' }, h('label', { for: 'bit-hasta' }, 'Hasta'), hasta),
        h('div', { class: 'campo' }, h('label', { for: 'bit-persona' }, 'Persona'), persona),
        h('div', { class: 'campo' }, h('label', { for: 'bit-tipo' }, 'Tipo'), tipo)),
      zonaError),
    botonesReporte('bitacora', () => ({ titulo: 'Quién hizo qué', periodo: `del ${fecha(filtros.desde)} al ${fecha(filtros.hasta)}`,
      notas: [persona.value ? `Persona: ${persona.selectedOptions[0].textContent}` : null, tipo.value ? `Tipo: ${TIPOS[tipo.value][0]}` : null,
        siguiente ? `Solo las primeras ${filas.length} filas; hay más con estos filtros (toque "Ver más" antes de descargar o imprimir).` : null].filter(Boolean),
      secciones: [{ titulo: 'Bitácora', columnas: [{ titulo: 'Fecha' }, { titulo: 'Hora' }, { titulo: 'Persona' }, { titulo: 'Tipo' }, { titulo: 'Qué hizo' }],
        filas: filas.map((f) => [fecha(f.fecha), f.hora, f.persona, (TIPOS[f.tipo] || [f.tipo])[0], textoFila(f)]) }] })),
    zona);
  for (const x of [desde, hasta, persona, tipo]) x.addEventListener('change', () => cargar());

  // La cadena de huellas: una fila por problema; sin filas = intacta.
  rpc('verificar_bitacora', { p_empresa_id: empresaId() }).then((r) => {
    const problemas = Array.isArray(r) ? r : [];
    integridad.replaceChildren(problemas.length
      ? mensaje('error', `La bitácora tiene ${problemas.length} ${problemas.length === 1 ? 'problema' : 'problemas'}: alguien la cambió por fuera del programa.`,
        `${problemas.slice(0, 3).map((p) => `Fila ${p.secuencia ?? '?'}: ${p.problema}`).join(' · ')}. Avise a su proveedor del programa.`, { dataset: { estado: 'rota' } })
      : h('p', { class: 'con-icono-linea', dataset: { estado: 'integra' } }, chip('Bitácora completa', 'verde'), ' Nadie la ha cambiado ni borrado por fuera del programa.'));
  }).catch(async (err) => integridad.replaceChildren(await cajaError(err)));

  function lista() {
    if (!filas.length) return estadoVacio({ icono: 'bitacora', chico: true, texto: 'No hay cambios con esos filtros.' });
    return h('div', { class: 'lista-filas', id: 'lista-bitacora' }, filas.map((f) => {
      const [t, ic] = TIPOS[f.tipo] || [f.tipo, 'lista'];
      return filaIcono({ icono: ic, color: /anuló|desactivó|borró|rechaz/.test(f.texto) ? 'rojo' : f.motivo ? 'dorado' : 'azul',
        titulo: textoFila(f), detalle: `${fecha(f.fecha)} ${f.hora.slice(0, 5)} · ${t}`, props: { dataset: { secuencia: String(f.secuencia), tipo: f.tipo } } });
    }));
  }
  async function pedir(antes) {
    return rpc('bitacora_legible', { p_empresa_id: empresaId(), p_filtros: { desde: filtros.desde, hasta: filtros.hasta, limite: 100,
      ...(filtros.usuario_id ? { usuario_id: filtros.usuario_id } : {}), ...(filtros.tipo ? { tipo: filtros.tipo } : {}), ...(antes ? { antes_de: antes } : {}) } });
  }
  async function cargar() {
    zonaError.replaceChildren();
    if (!desde.value || !hasta.value || desde.value > hasta.value) {
      zonaError.append(h('p', { class: 'ayuda texto-rojo', role: 'alert' }, 'Revise las fechas: "desde" no puede ser después de "hasta".'));
      return;
    }
    filtros = { desde: desde.value, hasta: hasta.value, usuario_id: persona.value, tipo: tipo.value };
    zona.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Cargando…'));
    let r;
    try { r = await pedir(null); } catch (err) { zona.replaceChildren(await cajaError(err)); return; }
    if (!ctx.sigueVigente()) return;
    filas = r.filas || [];
    siguiente = r.siguiente_antes_de || null;
    pintar();
  }
  function pintar() {
    const mas = siguiente ? h('button', { type: 'button', class: 'boton boton-ancho', id: 'bit-mas', onclick: async () => {
      mas.disabled = true; mas.textContent = 'Cargando…';
      try {
        const r = await pedir(siguiente);
        filas = filas.concat(r.filas || []);
        siguiente = r.siguiente_antes_de || null;
        pintar();
      } catch (err) { mas.disabled = false; mas.textContent = 'Ver más'; zona.append(await cajaError(err)); }
    } }, icono('mas'), 'Ver más') : null;
    zona.replaceChildren(h('p', { class: 'ayuda', dataset: { dato: 'bit-cantidad' } }, `${filas.length} ${filas.length === 1 ? 'cambio' : 'cambios'}${siguiente ? ' (hay más)' : ''}`), lista(), mas);
  }
  await cargar();
}
