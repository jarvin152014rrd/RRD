// Ajustes · "Excel y copia de mis datos" (antes Inventario > Excel). Excel de ida y vuelta: 1) descargar el Excel (columnas azules se cambian, grises
// solo informan), 2) subirlo y ver qué pasará fila por fila (importar_vista_previa: no guarda
// nada), 3) Guardar (importar_aplicar, con motivo: todo o nada). "Guardar" queda deshabilitado
// mientras haya un solo error. El archivo se lee y se arma en el navegador (js/excel.js).
import { rpc, escribir } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { h, icono, aviso, campo, conBoton, pedirMotivo, errorSimple, cajaError } from '../ui.js';
import { tarjetaCopiaDatos } from './aj_datos.js';
import { descargarExcel, leerHoja, nombreHoja } from '../excel.js';
import { olvidarDatos } from '../datos.js';

const HOJAS = [
  { hoja: 'productos', permisos: ['productos.editar'] },
  { hoja: 'categorias', permisos: ['productos.editar'] },
  { hoja: 'clientes_proveedores', permisos: ['terceros.editar'] },
  { hoja: 'existencias_iniciales', permisos: ['inventario.carga_inicial'] },
  { hoja: 'conteo_fisico', permisos: ['inventario.ajustar'] },
  { hoja: 'saldos_iniciales', permisos: ['ventas.saldo_inicial', 'compras.saldo_inicial'] },
];
const ACCION = { crear: 'Se crea', actualizar: 'Se actualiza', sin_cambios: 'Sin cambios', error: 'Error' };
const CLASE = { crear: 'etiqueta-ok', actualizar: '', sin_cambios: '', error: 'etiqueta-peligro' };

export async function mostrar(vista) {
  const E = empresaId();
  const hojas = HOJAS.filter((x) => puede(...x.permisos));
  const selHoja = h('select', { id: 'excel-hoja' }, hojas.map((x) => h('option', { value: x.hoja }, nombreHoja(x.hoja))));
  const zonaDesc = h('div', { 'aria-live': 'assertive' });
  const botonDesc = h('button', { type: 'button', class: 'boton boton-principal', id: 'excel-descargar' }, 'Descargar Excel');
  const archivo = h('input', { type: 'file', id: 'excel-archivo', accept: '.xlsx,.xls,.csv' });
  const zonaPrevia = h('div', { class: 'lista', id: 'excel-previa', 'aria-live': 'polite' });
  const zonaGuardar = h('div', { 'aria-live': 'assertive' });
  const botonGuardar = h('button', { type: 'button', class: 'boton boton-principal boton-ancho', id: 'excel-guardar', disabled: true }, 'Guardar cambios');
  let pendiente = null; // { hoja, filas } listo para guardar (sin errores)
  let plantilla = null;

  const traerPlantilla = async () => {
    if (!plantilla || plantilla.hoja !== selHoja.value) plantilla = await rpc('exportar_plantilla', { p_empresa_id: E, p_hoja: selHoja.value });
    return plantilla;
  };
  selHoja.addEventListener('change', () => { pendiente = null; botonGuardar.disabled = true; zonaPrevia.replaceChildren(); archivo.value = ''; });

  botonDesc.addEventListener('click', () => conBoton(botonDesc, zonaDesc, async () => {
    const p = await traerPlantilla();
    const nombre = `${perfilActual().empresa.nombre}_${p.hoja}_${perfilActual().empresa.hoy}.xlsx`.replace(/[^\p{L}\p{N}_.-]+/gu, '_');
    await descargarExcel(nombre, [p]);
    aviso(`Excel descargado: ${p.filas.length} fila(s).`);
  }, 'Preparando…'));

  archivo.addEventListener('change', async () => {
    pendiente = null; botonGuardar.disabled = true; zonaGuardar.replaceChildren();
    const f = archivo.files && archivo.files[0];
    if (!f) return;
    zonaPrevia.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Revisando el archivo… (todavía no se guarda nada)'));
    try {
      const p = await traerPlantilla();
      const { hojaArchivo, filas } = await leerHoja(f, p);
      if (!filas.length) { zonaPrevia.replaceChildren(errorSimple('El archivo no trae filas con datos.', 'Revise que sea el Excel descargado aquí.')); return; }
      const r = await rpc('importar_vista_previa', { p_empresa_id: E, p_hoja: p.hoja, p_filas: filas });
      pintarPrevia(f.name, hojaArchivo, filas, r);
      if (!r.errores.length && (r.resumen.crear || r.resumen.actualizar)) { pendiente = { hoja: p.hoja, filas }; botonGuardar.disabled = false; }
    } catch (err) {
      zonaPrevia.replaceChildren(err.clave || err.sinConexion || err.http ? await cajaError(err)
        : errorSimple('No se pudo leer el archivo.', 'Use el Excel descargado aquí (.xlsx) y vuelva a subirlo.'));
    }
  });

  function pintarPrevia(nombreArchivo, hojaArchivo, filas, r) {
    const res = r.resumen;
    const porFila = new Map(r.filas.map((x) => [x.fila, x]));
    const errores = new Map();
    for (const e of r.errores) errores.set(e.fila, [...(errores.get(e.fila) || []), e.texto || e.mensaje]);
    const enviadas = new Map(filas.map((x) => [x.fila, x]));
    const numeros = [...new Set([...porFila.keys(), ...errores.keys()])].sort((a, b) => a - b);
    zonaPrevia.replaceChildren(
      h('p', { class: 'ayuda' }, `Archivo: ${nombreArchivo} · hoja ${hojaArchivo} · todavía no se guardó nada`),
      h('div', { class: 'chips', id: 'excel-resumen' },
        h('span', { class: 'etiqueta etiqueta-ok' }, `${res.crear} nuevo(s)`),
        h('span', { class: 'etiqueta' }, `${res.actualizar} con cambios`),
        h('span', { class: 'etiqueta' }, `${res.sin_cambios} sin cambios`),
        h('span', { class: 'etiqueta ' + (res.error ? 'etiqueta-peligro' : 'etiqueta-ok'), dataset: { dato: 'errores' } }, `${res.error} error(es) por corregir`)),
      h('div', { class: 'tabla-envoltura' }, h('table', { class: 'tabla tabla-celular' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Fila'), h('th', {}, 'Registro'), h('th', {}, 'Qué pasará'), h('th', {}, 'Detalle'))),
        h('tbody', {}, numeros.filter((n) => errores.has(n) || (porFila.get(n) || {}).accion !== 'sin_cambios').map((n) => {
          const x = porFila.get(n) || { accion: 'error' };
          const acc = errores.has(n) ? 'error' : x.accion;
          const env = enviadas.get(n) || {};
          return h('tr', { class: acc === 'error' ? 'fila-error' : null, dataset: { fila: n } },
            h('td', { 'data-titulo': 'Fila' }, String(n)),
            h('td', { 'data-titulo': 'Registro' }, env.nombre || x.llave || env.codigo || ''),
            h('td', { 'data-titulo': 'Qué pasará' }, h('span', { class: 'etiqueta ' + CLASE[acc] }, ACCION[acc] || acc)),
            h('td', { 'data-titulo': 'Detalle' }, errores.has(n) ? errores.get(n).join(' ')
              : acc === 'crear' ? 'Registro nuevo.' : `Cambia: ${(x.cambios || []).join(', ')}.`));
        })))),
      res.error ? h('p', { class: 'mensaje mensaje-error', role: 'alert' }, `Hay ${res.error} error(es). Corríjalos en su Excel y vuelva a subirlo. Mientras haya errores no se guarda nada, así sus datos nunca quedan a medias.`)
        : !res.crear && !res.actualizar ? h('p', { class: 'mensaje mensaje-info' }, 'No hay nada que cambiar.')
          : h('p', { class: 'mensaje mensaje-ok' }, 'Todo está bien. Revise y toque "Guardar cambios".'));
  }

  botonGuardar.addEventListener('click', async () => {
    if (!pendiente) return;
    const { hoja, filas } = pendiente;
    let r = null;
    const ok = await pedirMotivo({ titulo: 'Guardar cambios del Excel', textoBoton: 'Guardar',
      explicacion: 'Se guarda todo junto o nada. El motivo queda en la bitácora y en el historial de precios.',
      accion: async (motivo) => { r = await escribir('importar_aplicar', { p_empresa_id: E, p_hoja: hoja, p_filas: filas, p_motivo: motivo }); } });
    if (!ok || !r) return;
    pendiente = null; botonGuardar.disabled = true; archivo.value = '';
    olvidarDatos('productos'); olvidarDatos('clientes');
    zonaPrevia.replaceChildren(h('p', { class: 'mensaje mensaje-ok', dataset: { dato: 'excel-guardado' } },
      `Guardado (importación #${r.numero}): ${r.resumen.crear} nuevo(s), ${r.resumen.actualizar} actualizado(s).` +
      ((r.documentos || []).length ? ` ${r.documentos.length} documento(s) creados.` : '')));
    aviso('Cambios del Excel guardados.');
  });

  vista.append(
    h('h1', { class: 'titulo-icono' }, icono('excel'), 'Excel y copia de mis datos'),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-xl1' },
      h('h2', { id: 't-xl1', class: 'paso-titulo' }, '1. Descargue su Excel'),
      h('p', { class: 'ayuda' }, 'Trae sus datos de hoy. Cambie las columnas azules (las grises son solo para que vea) y súbalo de nuevo.'),
      h('div', { class: 'dos-columnas' }, campo('Hoja', selHoja), h('div', {}, botonDesc)), zonaDesc),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-xl2' },
      h('h2', { id: 't-xl2', class: 'paso-titulo' }, '2. Súbalo y revise antes de guardar'),
      campo('Archivo de Excel', archivo, 'No se guarda nada hasta que toque "Guardar cambios".'), zonaPrevia),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-xl3' },
      h('h2', { id: 't-xl3', class: 'paso-titulo' }, '3. Guardar cambios'), zonaGuardar, botonGuardar),
    tarjetaCopiaDatos());
}
