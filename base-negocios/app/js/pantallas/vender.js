// Vender · "Nueva venta" (computadora y celular).
// La app NO calcula la venta: cada cambio del carrito pide calcular_venta_previa (misma regla que
// registrar_venta) para mostrar totales, ISV, promociones sugeridas y si el descuento pide aprobación.
// Cobrar llama registrar_venta con un id_operacion que se conserva mientras el carrito no cambie
// (si se corta el internet y se vuelve a tocar Cobrar, el servidor reconoce la misma venta).
import { rpc, escribir, nuevoId } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo } from '../sesion.js';
import { dinero, cantidad as fCantidad, aCentavos, paraCampo } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, dialogo } from '../ui.js';
import { productos, clientes, miTurno, filtrar, olvidarDatos } from '../datos.js';
import { vistaComprobante, nombreForma } from '../comprobante.js';
import { abrirTurnoDialogo } from './caja_turno.js';

export async function mostrar(vista, ctx) {
  await armarCarrito(vista, ctx, { modo: 'venta' });
}

// Quién puede recibir dinero: ventas.cobrar, o el vendedor si la empresa tiene "vendedor que cobra".
export function puedeCobrar() {
  const e = perfilActual().empresa;
  return puede('ventas.cobrar') || (e.vendedor_cobra === true && puede('ventas.vender'));
}

// Lector de códigos con la cámara (BarcodeDetector del navegador). Si no existe, lo dice.
export async function escanear(alCodigo, campoCodigo) {
  if (!('BarcodeDetector' in window) || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    aviso('Este navegador no puede leer códigos con la cámara. Escriba el código o use un lector de códigos.', 'info');
    if (campoCodigo) campoCodigo.focus();
    return;
  }
  const video = h('video', { class: 'camara-video', playsinline: true, muted: true, autoplay: true });
  const { dlg, cerrar } = dialogo('Apunte al código de barras', video,
    h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => cerrar() }, 'Cerrar')));
  let flujo = null;
  let activo = true;
  dlg.addEventListener('close', () => { activo = false; if (flujo) flujo.getTracks().forEach((t) => t.stop()); });
  try {
    flujo = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch {
    cerrar();
    aviso('No se pudo abrir la cámara. Dé permiso a la cámara o escriba el código.', 'info');
    return;
  }
  video.srcObject = flujo;
  const detector = new window.BarcodeDetector();
  const vuelta = async () => {
    if (!activo) return;
    try {
      const r = await detector.detect(video);
      if (r.length) { cerrar(); alCodigo(r[0].rawValue); return; }
    } catch { /* cuadro sin imagen todavía */ }
    setTimeout(vuelta, 250);
  };
  vuelta();
}

// Carrito compartido por "Nueva venta" (modo 'venta') y "Cotizaciones" (modo 'cotizacion').
export async function armarCarrito(vista, ctx, { modo, alTerminar = null }) {
  const perfil = perfilActual();
  const cobra = modo === 'venta' && puedeCobrar() && tieneModulo('dinero');
  const formas = cobra ? ['efectivo', 'tarjeta', 'transferencia', 'credito', 'mixto'] : ['credito'];
  const [lista, listaClientes] = await Promise.all([productos(), clientes().catch(() => [])]);
  if (!ctx.sigueVigente()) return;

  const estado = {
    lineas: [], descFactura: '', clienteId: '', forma: formas[0], recibido: '', referencia: '',
    mixto: { efectivo: '', tarjeta: '', transferencia: '', credito: '' }, previa: null, errorPrevia: null, idOperacion: null,
  };
  let turno = null;
  let vez = 0;      // para ignorar respuestas viejas de la previa
  let reloj = null;
  const raiz = h('div', { class: 'vender' }); // data-calculando mientras el servidor calcula

  // ---------------- Buscar ----------------
  const buscar = h('input', { id: 'buscar-producto', type: 'search', autocomplete: 'off', enterkeyhint: 'search',
    placeholder: 'Nombre, código o código de barras', 'aria-describedby': 'ayuda-buscar' });
  const resultados = h('div', { class: 'resultados', role: 'list' });
  const zonaBuscar = h('div', { 'aria-live': 'polite' });
  const botonCamara = h('button', { type: 'button', class: 'boton', onclick: () => escanear(porCodigo, buscar) }, 'Cámara');

  function pintarResultados() {
    const q = buscar.value.trim();
    resultados.replaceChildren(...(q ? filtrar(lista, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((p) =>
      h('button', { type: 'button', class: 'resultado-producto', role: 'listitem', onclick: () => agregar(p) },
        h('span', {}, p.nombre, h('span', { class: 'detalle' }, [p.codigo, p.tipo === 'servicio' ? 'Servicio' : null, p.unidad].filter(Boolean).join(' · '))),
        h('span', { class: 'monto' }, dinero(p.precio_venta_centavos)))) : []));
    if (q && !resultados.children.length) resultados.append(h('p', { class: 'vacio' }, 'No hay productos con ese nombre o código.'));
  }
  async function porCodigo(codigo) {
    const c = String(codigo || '').trim();
    if (!c) return;
    const igual = (x) => x && x.toUpperCase() === c.toUpperCase();
    let p = lista.find((x) => igual(x.codigo) || igual(x.codigo_barras));
    if (!p) {
      const encontrados = filtrar(lista, c, ['nombre', 'codigo', 'codigo_barras']);
      if (encontrados.length === 1) p = encontrados[0];
    }
    if (!p) {
      try {
        const r = await rpc('buscar_producto_por_codigo', { p_empresa_id: empresaId(), p_codigo: c });
        if (r && r.encontrado && r.producto) p = lista.find((x) => x.producto_id === r.producto.id);
      } catch { /* sin resultado */ }
    }
    zonaBuscar.replaceChildren();
    if (p) agregar(p);
    else zonaBuscar.append(errorSimple(`No se encontró el código "${c}".`, 'Revise el código o busque por nombre.'));
  }
  buscar.addEventListener('input', pintarResultados);
  buscar.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') { ev.preventDefault(); porCodigo(buscar.value); } // lector USB: escribe + Enter
  });

  // ---------------- Carrito ----------------
  const carrito = h('div', { class: 'carrito' });
  function agregar(p) {
    const ya = estado.lineas.find((l) => l.producto.producto_id === p.producto_id);
    if (ya) ya.cantidad = String(Number(ya.cantidad || 0) + 1);
    else estado.lineas.push({ producto: p, cantidad: '1', descPct: '', promocionId: null, elegida: false });
    buscar.value = '';
    resultados.replaceChildren();
    zonaBuscar.replaceChildren();
    cambio();
    buscar.focus();
  }

  function pintarCarrito() {
    if (!estado.lineas.length) {
      carrito.replaceChildren(h('p', { class: 'vacio' }, 'Busque un producto o servicio para empezar.'));
      return;
    }
    const previa = estado.previa;
    carrito.replaceChildren(...estado.lineas.map((l, i) => {
      const p = l.producto;
      const pl = previa && previa.lineas ? previa.lineas[i] : null;
      const promos = (pl && pl.promociones) || [];
      const cant = h('input', { name: 'cantidad', type: 'number', min: p.permite_fracciones ? '0.001' : '1',
        step: p.permite_fracciones ? '0.001' : '1', inputmode: p.permite_fracciones ? 'decimal' : 'numeric', value: l.cantidad,
        'aria-label': `Cantidad de ${p.nombre}` });
      cant.addEventListener('change', () => { l.cantidad = cant.value; if (!l.elegida) l.promocionId = null; cambio(); });
      const partes = [
        h('div', { class: 'linea-nombre' }, h('strong', {}, p.nombre),
          h('span', { class: 'detalle' }, [p.tipo === 'servicio' ? 'Servicio · no mueve inventario' : p.codigo,
            p.impuesto_clase === 'gravado' ? `${p.impuesto || p.tipo_impuesto} ${p.precio_incluye_isv ? 'incluido' : 'aparte'}` : 'Exento',
            p.permite_fracciones ? `por ${p.unidad}, admite decimales` : null].filter(Boolean).join(' · '))),
        h('div', { class: 'linea-datos' },
          campo('Cantidad', cant),
          h('div', { class: 'campo' }, h('span', { class: 'etiqueta-campo' }, 'Precio'), h('span', { class: 'monto valor-campo' }, dinero(p.precio_venta_centavos))),
          promos.length ? null : (() => {
            const d = h('input', { name: 'descuento', type: 'number', min: '0', max: '100', step: '0.01', inputmode: 'decimal',
              value: l.descPct, placeholder: '0' });
            d.addEventListener('change', () => { l.descPct = d.value; cambio(); });
            return campo('Desc. %', d);
          })(),
          h('div', { class: 'campo' }, h('span', { class: 'etiqueta-campo' }, 'Total'),
            h('span', { class: 'monto valor-campo', dataset: { dato: 'total-linea' } }, pl ? dinero(pl.total_centavos) : '…')),
          h('button', { type: 'button', class: 'boton boton-peligro boton-quitar', 'aria-label': `Quitar ${p.nombre}`,
            onclick: () => { estado.lineas.splice(i, 1); cambio(); } }, 'Quitar')),
      ];
      if (promos.length === 1) partes.push(h('p', { class: 'promo-una' }, `Promoción: ${promos[0].nombre} (−${dinero(promos[0].descuento_centavos)})`));
      if (promos.length > 1) {
        const elegida = l.promocionId || (pl && pl.promocion_id);
        const nombreGrupo = 'promo-' + i;
        partes.push(h('fieldset', { class: 'promos' },
          h('legend', {}, `${promos.length} promociones aplican. Elija una (no se suman):`),
          promos.map((x, k) => {
            const radio = h('input', { type: 'radio', name: nombreGrupo, value: x.promocion_id, checked: x.promocion_id === elegida });
            radio.addEventListener('change', () => { l.promocionId = x.promocion_id; l.elegida = true; cambio(); });
            return h('label', { class: 'promo-opcion' }, radio, ` ${x.nombre} (−${dinero(x.descuento_centavos)})`,
              k === 0 ? h('span', { class: 'etiqueta etiqueta-ok' }, 'Sugerida: la que más descuenta') : null);
          })));
      }
      return h('article', { class: 'linea-carrito', dataset: { producto: p.producto_id } }, ...partes);
    }));
  }

  // ---------------- Cliente, totales y pago ----------------
  const selCliente = h('select', { id: 'cliente' }, h('option', { value: '' }, 'Consumidor final'),
    listaClientes.filter((c) => c.activo).map((c) => h('option', { value: c.id }, c.nombre + (c.rtn ? ` · RTN ${c.rtn}` : ''))));
  selCliente.addEventListener('change', () => { estado.clienteId = selCliente.value; cambio(false); });
  const descFactura = h('input', { id: 'descuento-factura', type: 'number', min: '0', max: '100', step: '0.01', inputmode: 'decimal', placeholder: '0' });
  descFactura.addEventListener('change', () => { estado.descFactura = descFactura.value; cambio(); });
  const totales = h('div', { class: 'totales', 'aria-live': 'polite' });
  const zonaTurno = h('div', {});
  const zonaPago = h('div', { class: 'zona-pago' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const botonCobrar = h('button', { id: 'cobrar', type: 'button', class: 'boton boton-principal boton-grande boton-ancho' }, '');

  function total() { return estado.previa ? estado.previa.total_centavos : null; }

  function pintarTotales() {
    const pv = estado.previa;
    if (estado.errorPrevia) { totales.replaceChildren(estado.errorPrevia); }
    else if (!pv) { totales.replaceChildren(h('p', { class: 'vacio' }, 'Total L 0.00')); }
    else {
      totales.replaceChildren(...[
        h('div', { class: 'suma' }, h('span', {}, 'Subtotal sin ISV'), h('span', { class: 'monto' }, dinero(pv.subtotal_centavos))),
        h('div', { class: 'suma' }, h('span', {}, 'Descuento'), h('span', { class: 'monto', dataset: { dato: 'descuento' } }, dinero(pv.descuento_centavos))),
        (pv.desglose_impuestos || []).filter((d) => d.clase === 'gravado').map((d) =>
          h('div', { class: 'suma' }, h('span', {}, d.nombre), h('span', { class: 'monto', dataset: { dato: 'isv-' + d.codigo } }, dinero(d.impuesto_centavos)))),
        pv.exento_centavos ? h('div', { class: 'suma' }, h('span', {}, 'Exento'), h('span', { class: 'monto' }, dinero(pv.exento_centavos))) : null,
        h('div', { class: 'suma suma-total' }, h('span', {}, 'Total'), h('span', { class: 'monto', dataset: { dato: 'total' } }, dinero(pv.total_centavos))),
        pv.descuento_pide_aprobacion ? h('p', { class: 'mensaje mensaje-info aviso-tope', role: 'status' },
          `El descuento pasa su tope (${pv.tope_descuento_porcentaje} %). Puede seguir: la venta quedará esperando la aprobación del administrador o del dueño.`) : null].flat().filter(Boolean));
    }
    botonCobrar.textContent = modo === 'venta' ? `Cobrar ${pv ? dinero(pv.total_centavos) : ''}`.trim() : 'Guardar cotización';
  }

  function pintarPago() {
    if (modo !== 'venta') { zonaPago.replaceChildren(); return; }
    const t = total();
    const botones = h('div', { class: 'formas', role: 'radiogroup', 'aria-label': 'Forma de pago' }, formas.map((f) =>
      h('button', { type: 'button', class: 'forma' + (estado.forma === f ? ' forma-on' : ''), role: 'radio',
        'aria-checked': estado.forma === f ? 'true' : 'false', dataset: { forma: f },
        onclick: () => { estado.forma = f; cambio(false); } }, f === 'mixto' ? 'Mixto' : nombreForma(f))));
    const detalle = h('div', { class: 'forma-detalle' });
    if (estado.forma === 'efectivo') {
      const rec = h('input', { id: 'recibido', type: 'text', inputmode: 'decimal', autocomplete: 'off', value: estado.recibido,
        placeholder: t !== null ? paraCampo(t) : '' });
      const vuelto = h('p', { class: 'vuelto', 'aria-live': 'polite' });
      // Solo para mostrar mientras escribe; el vuelto que vale es el que devuelve el servidor.
      const pintarVuelto = () => {
        const r = aCentavos(rec.value);
        vuelto.replaceChildren();
        if (rec.value.trim() === '' || t === null) return;
        if (r === null) vuelto.append(h('span', { class: 'peligro' }, 'Escriba solo números, por ejemplo 500 o 500.50'));
        else if (r < t) vuelto.append(h('span', { class: 'peligro' }, `Falta ${dinero(t - r)}`));
        else vuelto.append('Vuelto: ', h('strong', { class: 'monto', dataset: { dato: 'vuelto' } }, dinero(r - t)));
      };
      rec.addEventListener('input', () => { estado.recibido = rec.value; pintarVuelto(); });
      detalle.append(campo('Recibido del cliente (L)', rec, 'Déjelo vacío si le pagan exacto.'), vuelto);
      pintarVuelto();
    } else if (estado.forma === 'tarjeta' || estado.forma === 'transferencia') {
      const ref = h('input', { id: 'referencia', type: 'text', maxlength: 100, value: estado.referencia });
      ref.addEventListener('input', () => { estado.referencia = ref.value; });
      detalle.append(campo(estado.forma === 'tarjeta' ? 'Número de voucher (opcional)' : 'Referencia de la transferencia (opcional)', ref,
        estado.forma === 'transferencia' ? 'La transferencia queda "por confirmar" hasta que se vea en el banco.' : null));
    } else if (estado.forma === 'credito') {
      const cli = listaClientes.find((c) => c.id === estado.clienteId);
      detalle.append(h('p', { class: 'ayuda' }, cli ? `Se carga a la cuenta de ${cli.nombre} (plazo ${cli.plazo_dias || 0} días).`
        : 'Para vender al crédito elija el cliente arriba.'));
    } else if (estado.forma === 'mixto') {
      for (const f of ['efectivo', 'tarjeta', 'transferencia', 'credito']) {
        const x = h('input', { type: 'text', inputmode: 'decimal', name: 'mixto-' + f, value: estado.mixto[f], placeholder: '0.00' });
        x.addEventListener('input', () => { estado.mixto[f] = x.value; pintarFalta(); });
        detalle.append(campo(nombreForma(f) + ' (L)', x));
      }
      const falta = h('p', { class: 'vuelto', 'aria-live': 'polite' });
      const pintarFalta = () => {
        const suma = Object.values(estado.mixto).reduce((s, v) => s + (aCentavos(v) || 0), 0);
        falta.textContent = t === null ? '' : suma === t ? 'Las formas de pago cuadran con el total.'
          : suma < t ? `Falta repartir ${dinero(t - suma)}` : `Se pasa por ${dinero(suma - t)}`;
      };
      detalle.append(falta);
      pintarFalta();
    }
    zonaPago.replaceChildren(h('h3', { class: 'titulo-chico' }, 'Forma de pago'), botones, detalle);
  }

  async function pintarTurno() {
    zonaTurno.replaceChildren();
    if (!cobra || !puede('caja.turno')) return;
    try { turno = await miTurno(); } catch { turno = null; }
    if (turno) {
      zonaTurno.append(h('p', { class: 'ayuda', dataset: { dato: 'turno' } }, `Turno ${turno.numero} abierto · ${turno.caja}`));
    } else if (perfil.empresa.turnos_obligatorios) {
      zonaTurno.append(h('div', { class: 'mensaje mensaje-info' },
        h('p', {}, h('strong', {}, 'No tiene turno de caja abierto.')),
        h('p', {}, 'Para cobrar en efectivo abra su turno (cuente el fondo de la caja).'),
        h('button', { type: 'button', class: 'boton', onclick: async () => { if (await abrirTurnoDialogo()) pintarTurno(); } }, 'Abrir turno')));
    }
  }

  // ---------------- Previa (servidor) ----------------
  function lineasServidor() {
    return estado.lineas.map((l) => {
      const x = { producto_id: l.producto.producto_id, cantidad: Number(l.cantidad) };
      if (l.promocionId) x.promocion_id = l.promocionId;
      const d = Number(l.descPct);
      if (l.descPct !== '' && d > 0 && !l.promocionId) x.descuento_porcentaje = d;
      return x;
    });
  }
  function descuentoFactura() {
    const d = Number(estado.descFactura);
    return estado.descFactura !== '' && d > 0 ? { porcentaje: d } : null;
  }

  async function recalcular() {
    const mia = ++vez;
    raiz.dataset.calculando = 'si';
    estado.errorPrevia = null;
    if (!estado.lineas.length) { estado.previa = null; pintarTodo(); delete raiz.dataset.calculando; return; }
    const mala = estado.lineas.find((l) => !(Number(l.cantidad) > 0));
    if (mala) {
      estado.previa = null;
      estado.errorPrevia = errorSimple(`La cantidad de "${mala.producto.nombre}" debe ser mayor que cero.`);
      pintarTodo();
      delete raiz.dataset.calculando;
      return;
    }
    try {
      const pv = await rpc('calcular_venta_previa', { p_empresa_id: empresaId(),
        p_datos: { lineas: lineasServidor(), descuento_factura: descuentoFactura() } });
      if (mia !== vez) return;
      // Varias promociones y nadie eligió: se usa la sugerida (y se manda explícita al cobrar).
      pv.lineas.forEach((pl, i) => {
        const l = estado.lineas[i];
        if (l && pl.promociones && pl.promociones.length > 1 && !l.promocionId) l.promocionId = pl.promocion_id;
        if (l && pl.promociones && pl.promociones.length) l.descPct = '';
      });
      estado.previa = pv;
    } catch (err) {
      if (mia !== vez) return;
      estado.previa = null;
      estado.errorPrevia = await cajaError(err);
    }
    pintarTodo();
    if (mia === vez) delete raiz.dataset.calculando;
  }

  function pintarTodo() { pintarCarrito(); pintarTotales(); pintarPago(); }

  // Algo cambió: el próximo cobro es otra operación. recalcularTambien=false si no cambia el monto.
  function cambio(recalcularTambien = true) {
    estado.idOperacion = null;
    zonaError.replaceChildren();
    if (!recalcularTambien) { pintarPago(); return; }
    raiz.dataset.calculando = 'si';
    clearTimeout(reloj);
    reloj = setTimeout(recalcular, 200);
    pintarCarrito();
  }

  // ---------------- Cobrar / guardar ----------------
  function pagos() {
    const t = total();
    const f = estado.forma;
    if (f === 'efectivo') {
      const r = estado.recibido.trim() === '' ? t : aCentavos(estado.recibido);
      if (r === null) throw errorSimple('Lo recibido no es un monto válido.', 'Escriba solo números, por ejemplo 500 o 500.50');
      if (r < t) throw errorSimple(`Lo recibido es menos que el total (faltan ${dinero(t - r)}).`);
      return [{ forma: 'efectivo', monto_centavos: t, recibido_centavos: r }];
    }
    if (f === 'tarjeta' || f === 'transferencia') {
      return [{ forma: f, monto_centavos: t, ...(estado.referencia.trim() ? { referencia: estado.referencia.trim() } : {}) }];
    }
    if (f === 'credito') {
      if (!estado.clienteId) throw errorSimple('Para vender al crédito elija el cliente.', 'El "Consumidor final" no puede llevar crédito.');
      return [{ forma: 'credito', monto_centavos: t }];
    }
    const lista2 = [];
    for (const [forma, v] of Object.entries(estado.mixto)) {
      if (String(v).trim() === '') continue;
      const c = aCentavos(v);
      if (c === null) throw errorSimple(`El monto de ${nombreForma(forma)} no es válido.`);
      if (c > 0) lista2.push({ forma, monto_centavos: c });
    }
    if (!lista2.length) throw errorSimple('Escriba cuánto se paga con cada forma.');
    if (lista2.some((x) => x.forma === 'credito') && !estado.clienteId) throw errorSimple('Para la parte al crédito elija el cliente.');
    return lista2;
  }

  botonCobrar.addEventListener('click', async () => {
    if (botonCobrar.disabled) return; // doble clic: el segundo no hace nada
    botonCobrar.disabled = true;
    botonCobrar.textContent = modo === 'venta' ? 'Cobrando…' : 'Guardando…';
    zonaError.replaceChildren();
    let listo = false;
    try {
      if (!estado.lineas.length) throw errorSimple('Agregue al menos un producto.');
      clearTimeout(reloj);
      if (raiz.dataset.calculando || !estado.previa) await recalcular(); // nunca cobrar con un total viejo
      if (!estado.previa) throw errorSimple('Revise los datos del carrito antes de seguir.');
      const datos = { lineas: lineasServidor() };
      if (descuentoFactura()) datos.descuento_factura = descuentoFactura();
      if (estado.clienteId) datos.cliente_id = estado.clienteId;
      if (modo === 'venta') datos.pagos = pagos();
      if (!estado.idOperacion) estado.idOperacion = nuevoId();
      if (modo === 'venta') {
        const r = await escribir('registrar_venta', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: estado.idOperacion });
        olvidarDatos('productos');
        listo = true;
        await terminado(r);
      } else {
        const r = await escribir('crear_cotizacion', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: estado.idOperacion });
        listo = true;
        aviso(`Cotización #${r.numero} guardada por ${dinero(r.total_centavos)}.`);
        if (alTerminar) alTerminar(r);
      }
    } catch (err) {
      zonaError.append(err instanceof Node ? err : await cajaError(err));
    } finally {
      if (!listo) { botonCobrar.disabled = false; pintarTotales(); }
    }
  });

  async function terminado(r) {
    const cli = listaClientes.find((c) => c.id === r.cliente_id);
    const nueva = h('a', { class: 'boton', href: '#/vender/nueva', onclick: (ev) => { ev.preventDefault(); reiniciar(); } }, 'Nueva venta');
    if (r.estado === 'pendiente_aprobacion') {
      vista.replaceChildren(h('section', { class: 'tarjeta', 'aria-labelledby': 't-pend' },
        h('h1', { id: 't-pend' }, `Venta #${r.numero} esperando aprobación`),
        h('div', { class: 'mensaje mensaje-info', dataset: { dato: 'pendiente' } },
          h('p', {}, h('strong', {}, 'La venta quedó pendiente de aprobación.')),
          h('p', {}, `Total ${dinero(r.total_centavos)}. Todavía no se cobró ni salió mercadería. Cuando el administrador o el dueño la apruebe, se emite sola con estas formas de pago.`)),
        h('div', { class: 'botones' }, nueva)));
      return;
    }
    const cabeza = h('div', { class: 'mensaje mensaje-ok venta-lista', role: 'status' },
      h('p', {}, h('strong', {}, `Venta lista: ${r.numero_documento}`)),
      r.vuelto_centavos ? h('p', { class: 'vuelto-grande' }, 'Vuelto: ', h('strong', { class: 'monto', dataset: { dato: 'vuelto-final' } }, dinero(r.vuelto_centavos))) : null);
    vista.replaceChildren(cabeza, h('p', { class: 'cargando' }, 'Preparando el comprobante…'));
    try {
      const comp = await vistaComprobante(r.venta_id, { telefono: cli && cli.telefono, extra: [nueva] });
      vista.replaceChildren(cabeza, comp);
    } catch (err) {
      vista.replaceChildren(cabeza, await cajaError(err), h('div', { class: 'botones' }, nueva));
    }
  }

  function reiniciar() {
    vista.replaceChildren();
    armarCarrito(vista, ctx, { modo, alTerminar });
  }

  // ---------------- Armado ----------------
  raiz.append(
    h('div', { class: 'vender-izq' },
      h('section', { class: 'tarjeta', 'aria-label': 'Buscar' },
        h('label', { for: 'buscar-producto', class: 'etiqueta-grande' }, 'Buscar producto o servicio'),
        h('div', { class: 'buscar-fila' }, buscar, botonCamara),
        h('p', { class: 'ayuda', id: 'ayuda-buscar' }, 'Con lector de códigos: apunte y listo (escribe el código y Enter).'),
        zonaBuscar, resultados),
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-carrito' },
        h('h2', { id: 't-carrito' }, modo === 'venta' ? 'Artículos' : 'Artículos de la cotización'), carrito)),
    h('aside', { class: 'vender-der tarjeta', 'aria-label': 'Cobro' },
      zonaTurno,
      campo('Cliente', selCliente, modo === 'venta' ? 'Opcional. El crédito necesita cliente.' : null),
      totales,
      campo('Descuento a toda la factura (%)', descFactura, 'Solo va a las líneas sin promoción ni otro descuento.'),
      zonaPago,
      !cobra && modo === 'venta' ? h('p', { class: 'mensaje mensaje-info' },
        'Usted puede vender al crédito o hacer una cotización. El cobro en efectivo, tarjeta o transferencia lo hace el cajero.') : null,
      zonaError, botonCobrar));
  vista.append(raiz);
  pintarTodo();
  pintarTurno();
  buscar.focus();
}
