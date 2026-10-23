// Vender · "Devoluciones": desde una venta (botón "Devolver" en Ventas del día o por número),
// elegir líneas y cantidades, el motivo y el destino que el dueño permite
// (devolver dinero, nota de crédito / saldo a favor, cambio por otro producto). Llama registrar_devolucion.
// Cambio de producto (app 0.10.0, núcleo 0.16.0): el cliente devuelve y se lleva otro producto. Las cifras
// (lo devuelto, el total nuevo y la diferencia) las calcula el servidor con calcular_cambio_previo; la app no
// suma dinero. Si el nuevo vale más se cobra la diferencia; si vale menos, la diferencia va a donde el dueño
// permite (dinero o saldo a favor / vale). Con un núcleo 0.15.0 la opción de cambio no se ofrece.
import { leer, escribir, rpcSiExiste, nuevoId } from '../api.js';
import { empresaId, puede } from '../sesion.js';
import { dinero, cantidad as fCantidad, aCantidad } from '../formato.js';
import { h, cajaError, errorSimple, campo, conBoton, titulo, mensaje, monto, aviso } from '../ui.js';
import { cuentasDinero, miTurno, productos, filtrar, versionNucleo, versionAlMenos } from '../datos.js';
import { vistaComprobante, nombreForma } from '../comprobante.js';

let ventaElegida = null;
export function prepararDevolucion(ventaId) { ventaElegida = ventaId; }

const DESTINO = { devolver_dinero: ['dinero', 'Devolver el dinero'], nota_credito: ['saldo_favor', 'Nota de crédito (saldo a favor o vale)'],
  cambio_producto: ['cambio', 'Cambiarlo por otro producto'] };

export async function mostrar(vista, ctx) {
  const id = ventaElegida;
  ventaElegida = null;
  if (id) return formulario(vista, ctx, id);
  // Buscar la venta por número de documento.
  const numero = h('input', { id: 'dev-numero', type: 'text', placeholder: 'T-001-001-00000012', autocomplete: 'off' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal' }, 'Buscar venta');
  const form = h('form', { class: 'formulario', novalidate: true }, campo('Número del ticket o factura', numero,
    'También puede ir a "Ventas del día" y tocar "Devolver".'), zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const r = await conBoton(boton, zonaError, () => leer('v_venta', { empresa_id: empresaId(), numero_documento: numero.value.trim().toUpperCase() }), 'Buscando…');
    if (!r) return;
    if (!r.length) { zonaError.append(errorSimple('No se encontró esa venta.', 'Revise el número (con guiones).')); return; }
    vista.replaceChildren();
    formulario(vista, ctx, r[0].venta_id);
  });
  vista.append(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-dev' }, titulo('h1', 'devolucion', 'Devolución', { id: 't-dev' }),
    h('p', { class: 'ayuda' }, 'Busque la venta por su número para devolver uno o varios productos o cambiarlos por otro.'), form));
}

async function formulario(vista, ctx, ventaId) {
  const [ventas, lineas, empresas, version] = await Promise.all([
    leer('v_venta', { venta_id: ventaId }), leer('v_venta_linea', { venta_id: ventaId }, { orden: 'linea.asc' }),
    leer('empresa', { id: empresaId() }), versionNucleo()]);
  if (!ctx.sigueVigente()) return;
  const v = ventas[0];
  if (!v) { vista.append(errorSimple('No se encontró la venta.')); return; }
  const tipos = (empresas[0] && empresas[0].devolucion_tipos) || ['devolver_dinero', 'nota_credito'];
  // El cambio de producto en pantalla necesita el núcleo 0.16.0 (calcular_cambio_previo).
  const conCambio = versionAlMenos(version, '0.16.0');
  const destinos = Object.entries(DESTINO).filter(([k]) => tipos.includes(k) && (k !== 'cambio_producto' || conCambio));

  // Cuentas de donde puede salir el dinero: la caja de su turno y las que puede ver.
  const cuentas = [];
  try {
    const t = await miTurno();
    if (t) {
      const ft = await leer('v_turno_caja', { turno_id: t.turno_id });
      if (ft[0]) cuentas.push({ id: ft[0].cuenta_dinero_id, nombre: `Mi caja (${t.caja})` });
    }
  } catch { /* sin turno */ }
  if (puede('dinero.ver')) {
    try {
      (await cuentasDinero()).filter((c) => ['efectivo_caja', 'caja_chica', 'banco'].includes(c.tipo) && !cuentas.some((x) => x.id === c.cuenta_dinero_id))
        .forEach((c) => cuentas.push({ id: c.cuenta_dinero_id, nombre: c.nombre }));
    } catch { /* sin permiso */ }
  }

  const filas = lineas.map((l) => {
    const x = h('input', { type: 'number', name: 'devolver', min: '0', max: String(Number(l.cantidad)),
      step: l.permite_fracciones === false ? '1' : 'any', inputmode: 'decimal', placeholder: '0', 'aria-label': `Cantidad a devolver de ${l.descripcion}` });
    return { l, x };
  });
  const motivo = h('textarea', { id: 'dev-motivo', maxlength: 500, minlength: 5 });
  const selDestino = h('select', { id: 'dev-destino' }, destinos.map(([, [val, texto]]) => h('option', { value: val }, texto)));
  const selCuenta = h('select', { id: 'dev-cuenta' }, cuentas.map((c) => h('option', { value: c.id }, c.nombre)));
  const zonaCuenta = campo('¿De dónde sale el dinero?', selCuenta);
  const cambio = zonaCambio();
  const pintarDestino = () => {
    const esCambio = selDestino.value === 'cambio';
    cambio.nodo.hidden = !esCambio;
    zonaCuenta.hidden = !(selDestino.value === 'dinero' || (esCambio && cambio.diferencia() === 'dinero'));
    if (esCambio) cambio.calcular();
    else cambio.cancelar();   // un cálculo que llegue tarde ya no toca la pantalla
  };
  selDestino.addEventListener('change', pintarDestino);
  filas.forEach(({ x }) => x.addEventListener('change', () => { if (selDestino.value === 'cambio') cambio.calcular(); }));
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'dev-guardar' }, 'Registrar devolución');
  const form = h('form', { class: 'formulario', novalidate: true },
    h('div', { class: 'lista' }, filas.map(({ l, x }) => h('div', { class: 'linea-devolver' },
      h('span', {}, h('strong', {}, l.descripcion), h('span', { class: 'detalle' }, `Vendido: ${fCantidad(l.cantidad)} · ${dinero(l.total_centavos)}`)),
      campo('Devolver', x)))),
    campo('Motivo', motivo, 'Mínimo 5 letras. Queda en la bitácora.'),
    destinos.length ? campo('¿Qué recibe el cliente?', selDestino,
      v.condicion === 'credito' ? 'Si la venta tiene saldo por cobrar, primero se rebaja lo que debe.' : null) : null,
    cambio.nodo, zonaCuenta, zonaError, boton);
  pintarDestino();

  // Lo que se devuelve (líneas con cantidad).
  function elegidas() { return filas.filter((f) => Number(f.x.value) > 0).map((f) => ({ linea: f.l.linea, cantidad: Number(f.x.value) })); }

  // ---------------- Cambio por otro producto ----------------
  function zonaCambio() {
    const est = { lineas: [], previa: null, clave: '', vez: 0, reloj: null, forma: 'efectivo', referencia: '', diferencia: '' };
    let lista = [];
    const buscar = h('input', { id: 'cambio-buscar', type: 'search', autocomplete: 'off', placeholder: 'Nombre, código o código de barras' });
    const resultados = h('div', { class: 'resultados', role: 'list' });
    const zonaLineas = h('div', { class: 'lista', id: 'cambio-lineas' });
    const zonaCifras = h('div', { id: 'cambio-cifras', 'aria-live': 'polite' });
    const nodo = h('fieldset', { class: 'tarjeta-interna', id: 'zona-cambio', hidden: true },
      h('legend', {}, 'Producto que se lleva'),
      campo('Buscar el producto nuevo', buscar), resultados, zonaLineas, zonaCifras);
    // Una sola carga de la lista (el foco y la primera tecla esperan la misma promesa).
    let carga = null;
    function cargar() {
      if (!carga) carga = productos().then((x) => { lista = x; }).catch(async (err) => { carga = null; zonaCifras.replaceChildren(await cajaError(err)); });
      return carga;
    }
    buscar.addEventListener('focus', cargar);
    buscar.addEventListener('input', async () => {
      await cargar();
      const q = buscar.value.trim();
      resultados.replaceChildren(...(q ? filtrar(lista, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((p) =>
        h('button', { type: 'button', class: 'resultado-producto', role: 'listitem', dataset: { producto: p.producto_id }, onclick: () => agregar(p) },
          h('span', {}, p.nombre, h('span', { class: 'detalle' }, [p.codigo, p.unidad].filter(Boolean).join(' · '))),
          h('span', { class: 'monto' }, dinero(p.precio_venta_centavos)))) : []));
      if (q && !resultados.children.length) resultados.append(h('p', { class: 'vacio' }, 'No hay productos con ese nombre o código.'));
    });
    function agregar(p) {
      const ya = est.lineas.find((l) => l.producto.producto_id === p.producto_id);
      if (ya) ya.cantidad = String(Number(ya.cantidad || 0) + 1);
      else est.lineas.push({ producto: p, cantidad: '1' });
      buscar.value = ''; resultados.replaceChildren();
      pintarLineas(); calcular();
    }
    function pintarLineas() {
      zonaLineas.replaceChildren(...est.lineas.map((l, i) => {
        const cant = h('input', { type: 'text', name: 'cantidad-nueva', inputmode: 'decimal', value: l.cantidad, 'aria-label': `Cantidad de ${l.producto.nombre}` });
        cant.addEventListener('change', () => { l.cantidad = cant.value; calcular(); });
        return h('div', { class: 'linea-devolver', dataset: { nuevo: l.producto.producto_id } },
          h('span', {}, h('strong', {}, l.producto.nombre), h('span', { class: 'detalle' }, `Precio ${dinero(l.producto.precio_venta_centavos)}`),
            h('button', { type: 'button', class: 'boton boton-peligro boton-quitar', 'aria-label': `Quitar ${l.producto.nombre}`,
              onclick: () => { est.lineas.splice(i, 1); pintarLineas(); calcular(); } }, 'Quitar')),
          campo('Cantidad', cant));
      }));
    }
    function datosPrevio() {
      const nuevas = [];
      for (const l of est.lineas) {
        const q = aCantidad(l.cantidad);
        if (q === null) return { error: `La cantidad de ${l.producto.nombre} no es válida.` };
        nuevas.push({ producto_id: l.producto.producto_id, cantidad: q });
      }
      return { lineas: elegidas(), cambio: { lineas: nuevas } };
    }
    // Pide el cálculo al servidor (con una pausa corta para no pedir en cada tecla) y pinta las cifras.
    function cancelar() { clearTimeout(est.reloj); est.vez++; est.previa = null; }
    function calcular() {
      clearTimeout(est.reloj);
      est.previa = null;
      est.reloj = setTimeout(pedir, 300);
    }
    async function pedir() {
      const datos = datosPrevio();
      if (datos.error) { zonaCifras.replaceChildren(errorSimple(datos.error)); return null; }
      if (!datos.lineas.length || !datos.cambio.lineas.length) {
        zonaCifras.replaceChildren(h('p', { class: 'ayuda' }, !datos.lineas.length ? 'Arriba, escriba cuánto devuelve.' : 'Busque y agregue el producto que se lleva.'));
        return null;
      }
      const yo = ++est.vez;
      zonaCifras.replaceChildren(h('p', { class: 'cargando', role: 'status' }, 'Calculando…'));
      let r;
      try {
        r = await rpcSiExiste('calcular_cambio_previo', { p_venta_id: ventaId, p_datos: datos });
      } catch (err) {
        if (yo === est.vez) zonaCifras.replaceChildren(await cajaError(err));
        return null;
      }
      if (yo !== est.vez) return null;
      if (r === null) {
        zonaCifras.replaceChildren(mensaje('info', 'Para cambiar productos aquí hace falta actualizar el programa (núcleo 0.16.0).',
          'Mientras tanto: registre la devolución como nota de crédito y venda el producto nuevo con ese saldo.', { dataset: { info: 'cambio-sin-nucleo' } }));
        return null;
      }
      est.previa = r; est.clave = JSON.stringify(datos);
      pintarCifras(r);
      return r;
    }
    function pintarCifras(r) {
      const partes = [
        h('div', { class: 'fila' }, h('span', {}, 'Lo que devuelve vale'), monto(dinero(r.devuelto.total_centavos), { dato: 'cambio-devuelto' })),
        Number(r.rebaja_deuda_centavos) ? h('div', { class: 'fila' }, h('span', {}, 'Primero rebaja lo que debe de esa venta'), monto(dinero(r.rebaja_deuda_centavos))) : null,
        h('div', { class: 'fila' }, h('span', {}, 'El producto nuevo vale'), monto(dinero(r.total_nuevo_centavos), { dato: 'cambio-nuevo' })),
      ];
      if (Number(r.a_cobrar_centavos) > 0) {
        partes.push(h('div', { class: 'fila fila-total' }, h('span', {}, 'El cliente paga la diferencia'),
          monto(dinero(r.a_cobrar_centavos), { sentido: 'entra', dato: 'cambio-cobrar' })));
        const formas = ['efectivo', 'tarjeta', 'transferencia'];
        const selForma = h('select', { id: 'cambio-forma' }, formas.map((f) => h('option', { value: f }, nombreForma(f))));
        selForma.value = est.forma;
        const ref = h('input', { id: 'cambio-referencia', type: 'text', maxlength: 100, value: est.referencia });
        const zonaRef = campo('Voucher o referencia (opcional)', ref);
        const pintarRef = () => { zonaRef.hidden = selForma.value === 'efectivo'; };
        selForma.addEventListener('change', () => { est.forma = selForma.value; pintarRef(); });
        ref.addEventListener('input', () => { est.referencia = ref.value; });
        pintarRef();
        partes.push(campo('¿Cómo paga la diferencia?', selForma), zonaRef);
      } else if (Number(r.a_favor_cliente_centavos) > 0) {
        partes.push(h('div', { class: 'fila fila-total' }, h('span', {}, 'Diferencia a favor del cliente'),
          monto(dinero(r.a_favor_cliente_centavos), { sentido: 'sale', dato: 'cambio-a-favor' })));
        const opciones = r.opciones_diferencia || [];
        if (!opciones.length) {
          partes.push(mensaje('error', 'El dueño no permite devolver dinero ni dejar saldo a favor.', 'Elija un producto nuevo de igual o mayor valor.'));
        } else {
          if (!opciones.some((o) => o.diferencia === est.diferencia)) est.diferencia = opciones[0].diferencia;
          partes.push(h('fieldset', { class: 'opciones', id: 'cambio-diferencia' }, h('legend', {}, '¿Qué se hace con la diferencia?'),
            opciones.map((o) => {
              const radio = h('input', { type: 'radio', name: 'cambio-diferencia', value: o.diferencia, checked: o.diferencia === est.diferencia });
              radio.addEventListener('change', () => { est.diferencia = o.diferencia; zonaCuenta.hidden = o.diferencia !== 'dinero'; });
              return h('label', {}, radio, ' ', o.texto);
            })));
        }
      } else {
        partes.push(mensaje('ok', 'Queda parejo: no se cobra ni se devuelve nada.', null, { dataset: { info: 'cambio-parejo' } }));
      }
      if (selDestino.value === 'cambio') zonaCuenta.hidden = !(Number(r.a_favor_cliente_centavos) > 0 && est.diferencia === 'dinero');
      if (r.pasa_tope) {
        partes.push(mensaje('error', `Este cambio (${dinero(r.devuelto.total_centavos)}) pasa lo que su puesto puede devolver sin aprobación.`,
          'Pídale al administrador o al dueño que lo haga, o registre la devolución como nota de crédito (queda en espera de aprobación) y venda el producto nuevo con ese saldo.',
          { dataset: { info: 'cambio-tope' } }));
      }
      zonaCifras.replaceChildren(...partes);
    }
    return {
      nodo, calcular, cancelar,
      diferencia: () => (est.previa && Number(est.previa.a_favor_cliente_centavos) > 0 ? est.diferencia : ''),
      // Datos del cambio para registrar_devolucion, con el cálculo al día (si cambió algo, se vuelve a pedir).
      async listo() {
        const datos = datosPrevio();
        if (datos.error) throw errorSimple(datos.error);
        if (!datos.cambio.lineas.length) throw errorSimple('Agregue el producto que se lleva el cliente.');
        let r = est.previa;
        if (!r || est.clave !== JSON.stringify(datos)) { clearTimeout(est.reloj); r = await pedir(); }
        if (!r) throw errorSimple('No se pudo calcular el cambio.', 'Revise los datos de arriba.');
        if (r.pasa_tope) throw errorSimple('Este cambio pasa su tope.', 'Que lo haga el administrador o el dueño.');
        // Con varias promociones en un producto, la venta exige elegir una: va la sugerida (la que más descuenta),
        // la misma con la que el servidor calculó el total de arriba.
        const c = { lineas: datos.cambio.lineas.map((l, i) => {
          const pl = (r.nuevo && r.nuevo.lineas && r.nuevo.lineas[i]) || {};
          return pl.promocion_sugerida_id ? { ...l, promocion_id: pl.promocion_sugerida_id } : l;
        }) };
        if (Number(r.a_cobrar_centavos) > 0) {
          const p = { forma: est.forma, monto_centavos: Number(r.a_cobrar_centavos) };
          if (est.forma !== 'efectivo' && est.referencia.trim()) p.referencia = est.referencia.trim();
          c.pagos = [p];
        }
        if (Number(r.a_favor_cliente_centavos) > 0) {
          if (!est.diferencia) throw errorSimple('El dueño no permite devolver dinero ni dejar saldo a favor.', 'Elija un producto de igual o mayor valor.');
          c.diferencia = est.diferencia;
        }
        return { cambio: c, previa: r };
      },
    };
  }

  const idOperacion = nuevoId();   // el mismo id en los reintentos: el servidor no duplica
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const lineasDev = elegidas();
    if (!lineasDev.length) { zonaError.append(errorSimple('Escriba cuánto se devuelve de al menos una línea.')); return; }
    if (motivo.value.trim().length < 5) { zonaError.append(errorSimple('Escriba el motivo (mínimo 5 letras).')); motivo.focus(); return; }
    const datos = { lineas: lineasDev, motivo: motivo.value.trim() };
    if (destinos.length) datos.destino = selDestino.value;
    let previa = null;
    if (datos.destino === 'cambio') {
      try {
        const x = await cambio.listo();
        datos.cambio = x.cambio; previa = x.previa;
      } catch (err) { zonaError.append(err instanceof Node ? err : await cajaError(err)); return; }
    }
    if (datos.destino === 'dinero' || (datos.cambio && datos.cambio.diferencia === 'dinero')) {
      if (!selCuenta.value) { zonaError.append(errorSimple('No hay una caja o cuenta de donde sacar el dinero.', 'Abra su turno de caja o elija nota de crédito.')); return; }
      datos.cuenta_dinero_id = selCuenta.value;
    }
    const r = await conBoton(boton, zonaError, () => escribir('registrar_devolucion', { p_venta_id: ventaId, p_datos: datos, p_id_operacion: idOperacion }));
    if (r) listo(r, previa);
  });

  async function listo(r, previa) {
    const pend = r.estado === 'pendiente_aprobacion';
    const esCambio = Boolean(r.venta_cambio_id);
    // El código del vale solo si de verdad queda saldo (en un cambio el lote puede quedar en cero).
    const vale = Number(r.saldo_favor_centavos) > 0 && r.saldo_favor && r.saldo_favor.codigo ? r.saldo_favor.codigo : null;
    let hecho;
    if (pend) hecho = `Devolución en espera de aprobación · ${dinero(r.total_centavos)}`;
    else if (esCambio) {
      hecho = `Cambio de producto guardado · devolvió ${dinero(r.total_centavos)}`
        + (previa && Number(previa.a_cobrar_centavos) ? ` · pagó ${dinero(previa.a_cobrar_centavos)} de diferencia` : '')
        + (r.dinero_centavos ? ` · sale ${dinero(r.dinero_centavos)} de la caja` : '')
        + (r.saldo_favor_centavos ? ` · ${dinero(r.saldo_favor_centavos)} ${vale ? 'en un vale' : 'a favor del cliente'}` : '');
    } else {
      hecho = `Devolución ${r.numero_documento || ''} guardada · ${dinero(r.total_centavos)}${r.dinero_centavos ? ' · sale ' + dinero(r.dinero_centavos) + ' de la caja' : ''}`;
    }
    aviso(hecho, pend ? 'info' : 'ok', 8000);
    const tarjeta = h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-devok', dataset: { resultado: esCambio ? 'cambio' : 'devolucion' } },
      titulo('h1', 'devolucion', pend ? 'Devolución esperando aprobación' : esCambio ? 'Cambio de producto listo' : `Devolución ${r.numero_documento}`, { id: 't-devok' }),
      pend ? mensaje('info', 'No se movió nada todavía.', 'El administrador o el dueño debe aprobarla.') : mensaje('ok', hecho, null, { class: 'resultado' }),
      h('div', { class: 'fila' }, h('span', {}, 'Total devuelto'), monto(dinero(r.total_centavos), { dato: 'total-devolucion' })),
      r.numero_documento && esCambio ? h('div', { class: 'fila' }, h('span', {}, 'Nota de crédito'), h('span', {}, r.numero_documento)) : null,
      r.cxc_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Rebaja de lo que debe'), monto(dinero(r.cxc_centavos))) : null,
      r.cambio_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Usado para el producto nuevo'), monto(dinero(r.cambio_centavos), { dato: 'cambio-usado' })) : null,
      previa && Number(previa.a_cobrar_centavos) ? h('div', { class: 'fila' }, h('span', {}, 'Diferencia que pagó el cliente'),
        monto(dinero(previa.a_cobrar_centavos), { sentido: 'entra', dato: 'cambio-pagado' })) : null,
      r.dinero_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Dinero devuelto (sale)'), monto(dinero(r.dinero_centavos), { sentido: 'sale', dato: 'dinero-devuelto' })) : null,
      r.saldo_favor_centavos ? h('div', { class: 'fila' }, h('span', {}, vale ? 'Queda en el vale' : 'Saldo a favor del cliente'),
        monto(dinero(r.saldo_favor_centavos), { dato: 'saldo-favor' })) : null,
      vale ? mensaje('info', `Código del vale: ${vale}`, 'Entrégueselo al cliente: lo usa en su próxima compra.', { dataset: { info: 'vale' } }) : null,
      h('div', { class: 'botones' }, h('a', { class: 'boton', href: '#/vender/ventas' }, 'Volver a ventas del día')));
    vista.replaceChildren(tarjeta);
    // Comprobante de la venta nueva del cambio (sin emojis; se imprime o se manda por WhatsApp).
    if (esCambio && !pend) {
      try {
        vista.append(h('h2', { class: 'titulo-chico' }, 'Comprobante del producto nuevo'), await vistaComprobante(r.venta_cambio_id));
      } catch (err) { vista.append(await cajaError(err)); }
    }
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-devf' },
    titulo('h1', 'devolucion', `Devolución de ${v.numero_documento || 'la venta #' + v.numero}`, { id: 't-devf' }),
    h('p', { class: 'ayuda' }, `${v.cliente_nombre || 'Consumidor final'} · Total ${dinero(v.total_centavos)}`), form));
}
