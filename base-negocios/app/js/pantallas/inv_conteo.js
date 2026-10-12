// Inventario · Conteo físico A CIEGAS: se cuenta en pantalla sin ver lo que dice el sistema
// (también en el celular, con la cámara para buscar el producto). No cambia la existencia:
// manda la hoja "conteo_fisico" (importar_vista_previa / importar_aplicar) y el servidor crea
// un ajuste PENDIENTE de aprobación por bodega con diferencias (lo aprueba admin o dueño en
// Inicio > Aprobaciones; al aprobar ajusta con la diferencia sobre la existencia de ese momento).
import { rpc, escribir } from '../api.js';
import { empresaId } from '../sesion.js';
import { h, aviso, errorSimple, campo, conBoton, pedirMotivo, cajaError } from '../ui.js';
import { filtrar } from '../datos.js';
import { escanear } from './vender.js';

export async function mostrar(vista, ctx) {
  const p = await rpc('exportar_plantilla', { p_empresa_id: empresaId(), p_hoja: 'conteo_fisico' });
  if (!ctx.sigueVigente()) return;
  const bodegas = [...new Set(p.filas.map((f) => f.bodega))];
  if (!bodegas.length) { vista.append(h('p', { class: 'vacio' }, 'No hay bodegas con productos para contar.')); return; }
  const selBodega = h('select', { id: 'conteo-bodega' }, bodegas.map((b) => h('option', { value: b }, b)));
  const buscar = h('input', { id: 'conteo-buscar', type: 'search', placeholder: 'Nombre o código', autocomplete: 'off', enterkeyhint: 'search' });
  const contado = new Map(); // "bodega|codigo" -> texto escrito (se conserva al cambiar de bodega o buscar)
  const zona = h('div', { class: 'lista', id: 'conteo-lista' });
  const cuenta = h('p', { class: 'ayuda', 'aria-live': 'polite' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'button', class: 'boton boton-principal boton-ancho', id: 'conteo-guardar' }, 'Enviar conteo a aprobación');
  const llave = (f) => `${f.bodega}|${f.codigo}`;
  const contar = () => { cuenta.textContent = `${[...contado.values()].filter((v) => v.trim()).length} producto(s) contado(s).`; };
  const pintar = () => {
    const vistas = filtrar(p.filas.filter((f) => f.bodega === selBodega.value), buscar.value, ['nombre', 'codigo']);
    zona.replaceChildren(...(vistas.length ? vistas.slice(0, 300).map((f) => {
      const inp = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', 'aria-label': `Cantidad contada de ${f.nombre}`,
        dataset: { codigo: f.codigo }, value: contado.get(llave(f)) || '', placeholder: '¿Cuántos hay?' });
      inp.addEventListener('input', () => { contado.set(llave(f), inp.value); contar(); });
      return h('div', { class: 'conteo-fila' }, h('span', {}, h('strong', {}, f.nombre), h('span', { class: 'detalle' }, ` ${f.codigo} · ${f.unidad || ''}`)), inp);
    }) : [h('p', { class: 'vacio' }, 'No hay productos con ese nombre en esta bodega.')]));
  };
  selBodega.addEventListener('change', pintar);
  buscar.addEventListener('input', pintar);
  const porCodigo = (codigo) => { buscar.value = codigo; pintar(); const i = zona.querySelector('input'); if (i) i.focus(); };
  boton.addEventListener('click', async () => {
    zonaError.replaceChildren();
    const filas = [];
    let n = 1;
    for (const f of p.filas) {
      const t = (contado.get(llave(f)) || '').trim();
      if (!t) continue;
      filas.push({ fila: ++n, codigo: f.codigo, bodega: f.bodega, cantidad_contada: t.replace(',', '.') });
    }
    if (!filas.length) { zonaError.append(errorSimple('Escriba la cantidad contada de al menos un producto.')); return; }
    // Primero la revisión (no guarda nada); si hay errores se muestran y no se envía.
    const prev = await conBoton(boton, zonaError, () => rpc('importar_vista_previa', { p_empresa_id: empresaId(), p_hoja: 'conteo_fisico', p_filas: filas }), 'Revisando…');
    if (!prev) return;
    if (prev.errores && prev.errores.length) {
      zonaError.append(errorSimple('Hay datos que corregir. No se envió nada.', prev.errores.map((e) => e.texto).join(' ')));
      return;
    }
    const ok = await pedirMotivo({ titulo: 'Enviar conteo', textoBoton: 'Enviar a aprobación',
      explicacion: `${filas.length} producto(s) contados. La existencia NO cambia hasta que el administrador o el dueño apruebe.`,
      accion: async (motivo) => { ctx.resultado = await escribir('importar_aplicar', { p_empresa_id: empresaId(), p_hoja: 'conteo_fisico', p_filas: filas, p_motivo: motivo }); } });
    if (!ok) return;
    const docs = (ctx.resultado && ctx.resultado.documentos) || [];
    aviso('Conteo enviado. Queda esperando aprobación.');
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-contok' },
      h('h1', { id: 't-contok' }, 'Conteo enviado'),
      h('p', { class: 'mensaje mensaje-ok', dataset: { dato: 'conteo-enviado' } },
        docs.length ? `Se crearon ${docs.length} ajuste(s) pendientes de aprobación. La existencia cambia cuando se aprueben (Inicio > Aprobaciones).`
          : 'Lo contado es igual a lo que hay: no hace falta ningún ajuste.'),
      h('button', { type: 'button', class: 'boton', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx).catch(async (e) => vista.append(await cajaError(e))); } }, 'Contar otra vez')));
  });
  pintar(); contar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-conteo' },
    h('h1', { id: 't-conteo' }, 'Conteo físico'),
    h('p', { class: 'ayuda' }, 'Cuente lo que hay de verdad. Aquí no se muestra lo que dice el sistema (conteo a ciegas). Deje vacío lo que no contó.'),
    h('div', { class: 'dos-columnas' }, campo('Bodega', selBodega),
      h('div', { class: 'buscar-fila' }, campo('Buscar', buscar), h('button', { type: 'button', class: 'boton', onclick: () => escanear(porCodigo, buscar) }, 'Cámara'))),
    cuenta, zona, zonaError, boton));
}
