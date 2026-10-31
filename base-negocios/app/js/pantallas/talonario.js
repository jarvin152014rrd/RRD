// Vender · "Talonario de emergencia" (app 0.14.0, núcleo 0.20.0, módulo facturas_emergencia).
// Facturas escritas a mano en un talonario de imprenta (con su propio CAI y punto de emisión), para cuando el sistema
// no se puede usar. Después se PASAN al sistema una por una con el número y la fecha de la copia; el servidor revisa
// que el número esté en el rango, que no se repita, que el CAI estaba vigente y que el mes esté abierto.
//   - Registrar el rango (dueño o administrador: talonario.administrar).
//   - Pasar una factura (talonario.registrar): productos, cliente, forma de pago; vista previa del total.
//   - Anular un número arruinado (queda ANULADO en el libro de ventas).
//   - Lista: usados, anulados, libres y huecos (números saltados antes del último usado).
import { rpc, escribir, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, fecha, aCantidad } from '../formato.js';
import { productos, clientes, filtrar } from '../datos.js';
import { h, aviso, cajaError, campo, titulo, chip, filaIcono, estadoVacio, pedirMotivo, errorSimple, mensaje } from '../ui.js';

const FORMAS = { efectivo: 'Efectivo', transferencia: 'Transferencia', tarjeta: 'Tarjeta', credito: 'Crédito' };
const hoy = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const admin = puede('talonario.administrar');
  const pasa = puede('talonario.registrar');
  let d;
  try { d = await rpc('talonarios', { p_empresa_id: E }); } catch (err) { vista.append(await cajaError(err)); return; }
  if (!ctx.sigueVigente()) return;
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  const activos = d.talonarios.filter((t) => t.activo && !t.vencido);

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-tal' },
    titulo('h1', 'documento', 'Talonario de emergencia', { id: 't-tal' }),
    h('p', { class: 'ayuda' }, 'Facturas escritas a mano cuando el sistema no se puede usar. Páselas aquí con el número y la fecha de la copia. El contador debe confirmar cómo se pide el CAI de un talonario de imprenta.'),
    pasa && activos.length ? h('div', { class: 'botones' },
      h('button', { type: 'button', class: 'boton boton-principal', id: 'tal-pasar', onclick: () => pasarFactura() }, 'Pasar una factura del talonario')) : null,
    d.talonarios.length ? d.talonarios.map(tarjetaTalonario)
      : estadoVacio({ icono: 'documento', chico: true, texto: admin ? 'Todavía no hay talonarios. Registre el rango que le dio la imprenta.' : 'Todavía no hay talonarios registrados.' }),
    admin ? h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', id: 'tal-nuevo', onclick: () => formRango() }, 'Registrar un talonario')) : null));

  function tarjetaTalonario(t) {
    const anular = pasa && t.activo ? h('button', { type: 'button', class: 'boton', dataset: { anularEn: t.talonario_id }, onclick: () => anularNumero(t) }, 'Anular un número') : null;
    const desactivar = admin && t.activo ? h('button', { type: 'button', class: 'boton boton-peligro', onclick: () => pedirMotivo({
      titulo: `Desactivar el talonario ${t.rango_desde}`, peligro: true, textoBoton: 'Desactivar',
      explicacion: 'Ya no se podrán pasar facturas de este talonario. Lo ya pasado no cambia.',
      accion: async (motivo) => { await rpc('desactivar_talonario', { p_empresa_id: E, p_talonario_id: t.talonario_id, p_motivo: motivo }); aviso('Talonario desactivado.'); recargar(); } }) }, 'Desactivar') : null;
    return h('article', { class: 'tarjeta talonario', dataset: { talonario: t.talonario_id } },
      filaIcono({ icono: 'documento', color: !t.activo ? 'neutro' : t.vencido ? 'rojo' : 'verde',
        titulo: h('strong', {}, `${t.rango_desde} a ${t.rango_hasta}`),
        detalle: `CAI ${t.cai} · vence ${fecha(t.fecha_limite_emision)} · ${t.sucursal || ''}`,
        derecha: chip(!t.activo ? 'Desactivado' : t.vencido ? 'CAI vencido' : 'Activo', !t.activo ? 'neutro' : t.vencido ? 'rojo' : 'verde') }),
      h('p', {}, 'Usados ', h('strong', { dataset: { dato: 'usados' } }, String(t.usados)), ' · Anulados ', h('strong', { dataset: { dato: 'anulados' } }, String(t.anulados)),
        ' · Libres ', h('strong', { dataset: { dato: 'libres' } }, String(t.libres))),
      t.huecos.length ? mensaje('info', `Números saltados: ${t.huecos.map((n) => String(n).padStart(8, '0')).join(', ')}`,
        'Páselos si tienen copia o anúlelos si se arruinaron.', { dataset: { dato: 'huecos' } }) : null,
      t.numeros.length ? h('ul', { class: 'lista-simple' }, t.numeros.slice(-30).reverse().map((n) => h('li', { dataset: { numero: n.numero, estado: n.estado } },
        `${n.numero_documento} · ${fecha(n.fecha)} · `, n.estado === 'anulado' ? chip('Anulado', 'rojo') : chip('Pasada', 'verde'),
        n.estado === 'anulado' ? ` ${n.motivo || ''}` : ` ${n.cliente || ''} ${n.total_centavos != null ? dinero(n.total_centavos) : ''}`))) : null,
      h('div', { class: 'botones' }, anular, desactivar));
  }

  // ---- Registrar el rango ----
  function formRango() {
    const cai = h('input', { id: 'tal-cai', type: 'text', maxlength: 60, placeholder: 'XXXXXX-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX', autocapitalize: 'characters' });
    const desde = h('input', { id: 'tal-desde', type: 'text', maxlength: 19, placeholder: '001-901-01-00000001' });
    const hasta = h('input', { id: 'tal-hasta', type: 'text', maxlength: 19, placeholder: '001-901-01-00000100' });
    const limite = h('input', { id: 'tal-limite', type: 'date' });
    const nota = h('input', { id: 'tal-nota', type: 'text', maxlength: 300 });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const guardar = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Registrar talonario');
    const id = nuevoId();
    const form = h('form', { class: 'formulario tarjeta', novalidate: true },
      h('h2', {}, 'Registrar un talonario'),
      h('p', { class: 'ayuda' }, 'Copie los datos impresos en el talonario. El punto de emisión (los 3 números del medio) es propio del talonario: no puede ser el de una caja del sistema.'),
      campo('CAI', cai), campo('Primer número', desde), campo('Último número', hasta), campo('Fecha límite de emisión', limite), campo('Nota (opcional)', nota),
      zonaError, guardar, h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      if (guardar.disabled) return;
      zonaError.replaceChildren();
      if (!cai.value.trim() || !desde.value.trim() || !hasta.value.trim() || !limite.value) { zonaError.append(errorSimple('Complete el CAI, el rango y la fecha límite.')); return; }
      guardar.disabled = true;
      try {
        await rpc('registrar_talonario', { p_empresa_id: E, p_id_operacion: id, p_datos: { cai: cai.value.trim(), rango_desde: desde.value.trim(),
          rango_hasta: hasta.value.trim(), fecha_limite_emision: limite.value, ...(nota.value.trim() ? { nota: nota.value.trim() } : {}) } });
        aviso('Talonario registrado.');
        recargar();
      } catch (err) { zonaError.append(await cajaError(err)); guardar.disabled = false; }
    });
    vista.replaceChildren(form);
    cai.focus();
  }

  // ---- Anular un número ----
  function anularNumero(t) {
    const num = h('input', { id: 'tal-anular-numero', type: 'number', min: t.desde, max: t.hasta, step: '1', inputmode: 'numeric' });
    const zona = h('div', { 'aria-live': 'assertive' });
    const seguir = h('button', { type: 'button', class: 'boton boton-peligro boton-ancho' }, 'Anular este número');
    seguir.addEventListener('click', async () => {
      const n = Number(num.value);
      zona.replaceChildren();
      if (!Number.isInteger(n) || n < t.desde || n > t.hasta) { zona.append(errorSimple(`El número va de ${t.desde} a ${t.hasta}.`)); return; }
      const ok = await pedirMotivo({ titulo: `Anular ${t.prefijo}-${String(n).padStart(8, '0')}`, peligro: true, textoBoton: 'Anular',
        explicacion: 'Queda ANULADO en el libro de ventas y nunca se vuelve a usar. Guarde el original y la copia arruinados.',
        accion: (motivo) => escribir('anular_numero_talonario', { p_empresa_id: E, p_talonario_id: t.talonario_id, p_numero: n, p_motivo: motivo }) });
      if (ok) { aviso('Número anulado.'); recargar(); }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta formulario' }, h('h2', {}, `Anular un número de ${t.rango_desde}`),
      campo('Número (solo los últimos 8 dígitos)', num), zona, seguir,
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar')));
    num.focus();
  }

  // ---- Pasar una factura ----
  async function pasarFactura() {
    const [prods, clis] = await Promise.all([productos(), clientes().catch(() => [])]);
    const lineas = [];
    let previa = null;
    const id = nuevoId();
    const tal = h('select', { id: 'tal-talonario' }, activos.map((t) => h('option', { value: t.talonario_id }, `${t.rango_desde} a ${t.rango_hasta}`)));
    const num = h('input', { id: 'tal-numero', type: 'number', step: '1', inputmode: 'numeric', placeholder: 'Ej.: 25' });
    const fec = h('input', { id: 'tal-fecha', type: 'date', value: hoy(), max: hoy() });
    const cli = h('select', { id: 'tal-cliente' }, h('option', { value: '' }, 'Consumidor final'), clis.map((c) => h('option', { value: c.id }, c.nombre)));
    const forma = h('select', { id: 'tal-forma' }, Object.entries(FORMAS).map(([k, v]) => h('option', { value: k }, v)));
    const ref = h('input', { id: 'tal-ref', type: 'text', maxlength: 60 });
    const busca = h('input', { id: 'tal-buscar', type: 'search', placeholder: 'Buscar producto por nombre o código', autocomplete: 'off' });
    const resultados = h('div', { class: 'resultados-busqueda' });
    const carrito = h('div', { id: 'tal-carrito' });
    const totales = h('div', { id: 'tal-total', 'aria-live': 'polite' });
    const zonaError = h('div', { 'aria-live': 'assertive' });
    const guardar = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'tal-guardar' }, 'Pasar la factura');

    busca.addEventListener('input', () => {
      const q = busca.value.trim();
      resultados.replaceChildren(...(q ? filtrar(prods, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((p) =>
        h('button', { type: 'button', class: 'boton resultado', dataset: { producto: p.producto_id }, onclick: () => {
          lineas.push({ producto_id: p.producto_id, nombre: p.nombre, cantidad: '1' });
          busca.value = ''; resultados.replaceChildren(); pintar(); calcular();
        } }, `${p.nombre} · ${dinero(p.precio_venta_centavos)}`)) : []));
    });
    function pintar() {
      carrito.replaceChildren(...lineas.map((l, i) => {
        const c = h('input', { type: 'text', inputmode: 'decimal', value: l.cantidad, 'aria-label': `Cantidad de ${l.nombre}`, dataset: { cantidad: i } });
        c.addEventListener('change', () => { l.cantidad = c.value; calcular(); });
        return h('div', { class: 'fila' }, h('span', {}, l.nombre), h('span', { class: 'campo' }, c,
          h('button', { type: 'button', class: 'boton', 'aria-label': `Quitar ${l.nombre}`, onclick: () => { lineas.splice(i, 1); pintar(); calcular(); } }, 'Quitar')));
      }));
    }
    function lineasServidor() {
      return lineas.map((l) => {
        const q = aCantidad(l.cantidad);
        if (q === null || q <= 0) throw errorSimple(`La cantidad de ${l.nombre} no es válida.`);
        return { producto_id: l.producto_id, cantidad: q };
      });
    }
    async function calcular() {
      previa = null;
      zonaError.replaceChildren();
      if (!lineas.length) { totales.replaceChildren(); return; }
      try {
        previa = await rpc('calcular_venta_previa', { p_empresa_id: E, p_datos: { lineas: lineasServidor(), ...(cli.value ? { cliente_id: cli.value } : {}) } });
        totales.replaceChildren(h('p', {}, 'ISV ', dinero(previa.impuesto_centavos), ' · Total ', h('strong', { dataset: { dato: 'total' } }, dinero(previa.total_centavos))),
          h('p', { class: 'ayuda' }, 'Compare con el total escrito en la copia. Si no cuadra, revise productos y cantidades.'));
      } catch (err) { totales.replaceChildren(err instanceof Node ? err : await cajaError(err)); }
    }
    cli.addEventListener('change', calcular);

    const form = h('form', { class: 'formulario tarjeta', novalidate: true },
      h('h2', {}, 'Pasar una factura del talonario'),
      campo('Talonario', tal), campo('Número de la factura (últimos 8 dígitos)', num), campo('Fecha de la copia', fec),
      campo('Cliente', cli), campo('Productos', busca), resultados, carrito, totales,
      campo('Forma de pago', forma), campo('Referencia (transferencia o tarjeta)', ref),
      zonaError, guardar, h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      if (guardar.disabled) return;
      zonaError.replaceChildren();
      try {
        const n = Number(num.value);
        if (!Number.isInteger(n) || n < 1) throw errorSimple('Escriba el número de la factura.');
        if (!fec.value) throw errorSimple('Escriba la fecha de la copia.');
        if (!lineas.length) throw errorSimple('Agregue los productos de la factura.');
        if (forma.value === 'credito' && !cli.value) throw errorSimple('Para el crédito elija el cliente.');
        if (!previa) await calcular();
        if (!previa) throw errorSimple('Revise los productos antes de seguir.');
        const t = previa.total_centavos;
        const pago = { forma: forma.value, monto_centavos: t, ...(forma.value === 'efectivo' ? { recibido_centavos: t } : {}),
          ...(ref.value.trim() && forma.value !== 'efectivo' && forma.value !== 'credito' ? { referencia: ref.value.trim() } : {}) };
        guardar.disabled = true;
        const r = await rpc('registrar_factura_talonario', { p_empresa_id: E, p_id_operacion: id, p_datos: { talonario_id: tal.value, numero: n,
          fecha: fec.value, lineas: lineasServidor(), pagos: [pago], ...(cli.value ? { cliente_id: cli.value } : {}) } });
        aviso(`Factura ${r.numero_documento} pasada · ${dinero(r.total_centavos)}`, 'ok', 6000);
        recargar();
      } catch (err) {
        zonaError.append(err instanceof Node ? err : await cajaError(err));
        guardar.disabled = false;
      }
    });
    vista.replaceChildren(form);
    num.focus();
  }
}
