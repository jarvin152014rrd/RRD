// Vender · "Nueva venta" (computadora y celular).
// La app NO calcula la venta: cada cambio del carrito pide calcular_venta_previa (misma regla que
// registrar_venta) para mostrar totales, ISV, promociones sugeridas y si el descuento pide aprobación.
// Cobrar llama registrar_venta con un id_operacion que se conserva mientras el carrito no cambie
// (si se corta el internet y se vuelve a tocar Cobrar, el servidor reconoce la misma venta).
// App 0.14.0 (núcleo 0.20.0, docs/SIN_INTERNET.md):
//   * modo sin internet (la app abrió sin conexión): productos, clientes y la cuenta salen de la foto del catálogo
//     guardada en el equipo (js/calculo_local.js); solo efectivo o transferencia; la venta se guarda en la cola.
//   * caja con números reservados en ESTE equipo (G2): toda venta de contado pasa por la cola (número del bloque) y
//     se sube enseguida; si el servidor no contesta, queda guardada y se imprime "Emitida sin conexión".
import { rpc, escribir, nuevoId } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo, modoSinInternet } from '../sesion.js';
import * as si from '../sin_internet.js';
import { precioConTasa } from '../calculo_local.js';
import { dinero, cantidad as fCantidad, aCentavos, paraCampo } from '../formato.js';
import { h, icono, aviso, cajaError, errorSimple, campo, dialogo, titulo, estadoVacio, mensaje, chip } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { productos, clientes, miTurno, filtrar, olvidarDatos, nucleoAlMenos, existenciasPorProducto } from '../datos.js';
import { vistaComprobante, vistaComprobanteLocal, nombreForma } from '../comprobante.js';
import { abrirTurnoDialogo } from './caja_turno.js';
import { fotosActivas, miniatura } from '../fotos.js';

// Formas de pago como tarjetas (app 0.15.0, idea de RRD): ícono, nombre y una explicación corta.
const FORMAS_VISTA = {
  efectivo: ['billetes', 'Paga ahora'],
  tarjeta: ['tarjeta', 'Datáfono o POS'],
  transferencia: ['transferencia', 'Depósito o app'],
  credito: ['reloj', 'Queda debiendo'],
  mixto: ['capas', 'Dos o más formas'],
};

// Existencias para el buscador (app 0.15.0): suma de las bodegas de las sucursales del usuario (datos.js).
// Sin permiso o sin módulo de inventario no se muestran (null).
async function existenciasVisibles() {
  if (!tieneModulo('inventario') || !puede('inventario.ver')) return null;
  return existenciasPorProducto();
}

// Computadora: el ticket mide lo que queda de pantalla desde donde empieza (y al bajar, la pantalla entera),
// así el pie con el total y Cobrar siempre se ve. Se deja de vigilar cuando la pantalla cambia.
function ajustarTicket(el) {
  if (!el) return;
  const medir = () => {
    if (!el.isConnected) { window.removeEventListener('scroll', medir); window.removeEventListener('resize', medir); return; }
    if (window.innerWidth < 900) { el.style.removeProperty('max-height'); return; }
    const arriba = Math.max(12, el.getBoundingClientRect().top);
    el.style.maxHeight = `${Math.max(320, window.innerHeight - arriba - 12)}px`;
  };
  window.addEventListener('scroll', medir, { passive: true });
  window.addEventListener('resize', medir);
  requestAnimationFrame(medir);
}

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
// Productos y clientes de la foto del catálogo guardada en el equipo (modo sin internet).
function productosDeFoto(cat) {
  return Object.entries(cat.catalogo.productos).map(([id, p]) => {
    const imp = cat.catalogo.impuestos[p.tipo_impuesto] || {};
    return { producto_id: id, nombre: p.nombre, codigo: p.codigo, codigo_barras: p.codigo_barras, unidad: p.unidad, tipo: p.tipo,
      permite_fracciones: p.permite_fracciones, precio_incluye_isv: p.precio_incluye_isv, impuesto: p.tipo_impuesto,
      impuesto_clase: imp.clase, existencia: (cat.existencias || {})[id] ?? null,
      // Para mostrar: el precio con ISV (como lo paga el cliente).
      precio_venta_centavos: precioConTasa(p.precio_venta_centavos, p.precio_incluye_isv, Number(imp.porcentaje || 0)).con };
  }).sort((a, b) => a.nombre.localeCompare(b.nombre));
}

export async function armarCarrito(vista, ctx, { modo, alTerminar = null }) {
  const perfil = perfilActual();
  // Sin internet (G1) o caja con números reservados en este equipo (G2): la venta de contado va por la cola.
  const local = modo === 'venta' && modoSinInternet();
  const conBloque = modo === 'venta' && !local && puedeCobrar() && tieneModulo('ventas') ? await si.cajaConBloque(perfil) : null;
  let cat = conBloque ? conBloque.cat : null;
  let estadoLocal = null;
  if (local) {
    estadoLocal = await si.estadoVenta(perfil);
    cat = estadoLocal.cat || null;
    if (!cat || !cat.catalogo) {
      vista.append(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'alerta', 'Sin conexión'),
        mensaje('info', 'Este equipo no está preparado para vender sin internet.', 'Cuando vuelva el internet, prepare el equipo en Ajustes > Sin internet.')));
      return;
    }
  }
  const porCola = local || Boolean(conBloque);
  const cobra = modo === 'venta' && (local ? true : puedeCobrar() && tieneModulo('dinero'));
  // n018: núcleo 0.18.0 (precio mayorista: la previa recibe el cliente).
  const deFoto = () => [productosDeFoto(cat), (cat.clientes || []).map((c) => ({ ...c, activo: true })), true];
  let lista, listaClientes, n018;
  let sinRedAlAbrir = false;   // se fue el internet con la sesión abierta y la caja tiene números en este equipo
  if (local) [lista, listaClientes, n018] = deFoto();
  else {
    try {
      [lista, listaClientes, n018] = await Promise.all([productos(), clientes().catch(() => []), nucleoAlMenos('0.18.0')]);
    } catch (e) {
      if (!(e.sinConexion && conBloque && cat)) throw e;
      sinRedAlAbrir = true;
      [lista, listaClientes, n018] = deFoto();
    }
  }
  const formas = local || sinRedAlAbrir ? ['efectivo', 'transferencia']
    : conBloque ? ['efectivo', 'tarjeta', 'transferencia']
      : cobra ? ['efectivo', 'tarjeta', 'transferencia', 'credito', 'mixto'] : ['credito'];
  if (!ctx.sigueVigente()) return;

  const estado = {
    lineas: [], descFactura: '', clienteId: '', forma: formas[0], recibido: '', referencia: '', banco: '', previaLocal: local || sinRedAlAbrir,
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
  const botonCamara = h('button', { type: 'button', class: 'boton', onclick: () => escanear(porCodigo, buscar) }, icono('foto'), 'Cámara');

  // Existencias: con internet se leen aparte (no frenan la pantalla); sin internet, las de la foto del catálogo.
  let existencias = null;
  if (local || sinRedAlAbrir) {
    existencias = new Map(lista.filter((p) => p.existencia !== null && p.existencia !== undefined).map((p) => [p.producto_id, Number(p.existencia)]));
  } else if (modo === 'venta' || modo === 'cotizacion') {
    existenciasVisibles().then((m) => { existencias = m; if (buscar.value.trim()) pintarResultados(); }).catch(() => {});
  }
  function chipExistencia(p) {
    if (!existencias || p.tipo === 'servicio') return null;
    const n = existencias.get(p.producto_id) || 0;
    return n > 0 ? chip(`${fCantidad(n)} ${p.unidad || ''}`.trim(), 'verde', { class: 'chip-existencia', dataset: { dato: 'existencia' } })
      : chip('Agotado', 'rojo', { class: 'chip-existencia', dataset: { dato: 'existencia' } });
  }
  function pintarResultados() {
    const q = buscar.value.trim();
    resultados.replaceChildren(...(q ? filtrar(lista, q, ['nombre', 'codigo', 'codigo_barras']).slice(0, 8).map((p) =>
      h('button', { type: 'button', class: 'resultado-producto', role: 'listitem', onclick: () => agregar(p) },
        // Fotos encendidas (app 0.11.0): miniatura (o el ícono si no tiene foto).
        (!local && fotosActivas()) ? miniatura(p, { icono: p.tipo === 'servicio' ? 'servicio' : 'etiqueta', props: { class: 'burbuja-chica' } }) : null,
        h('span', { class: 'resultado-texto' }, p.nombre, h('span', { class: 'detalle' }, [p.codigo, p.tipo === 'servicio' ? 'Servicio' : null, p.unidad].filter(Boolean).join(' · '))),
        chipExistencia(p),
        h('span', { class: 'monto resultado-precio' }, dinero(p.precio_venta_centavos)))) : []));
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
    if (!p && !local) {
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
  // Al cambiar la cantidad o el cliente, el servidor vuelve a decidir el precio (normal o mayorista); una
  // línea con descuento manual se queda con el precio normal (nunca descuento sobre el mayorista).
  const tipoLibre = (l) => { l.precioTipo = Number(l.descPct) > 0 ? 'normal' : null; };
  function agregar(p) {
    const ya = estado.lineas.find((l) => l.producto.producto_id === p.producto_id);
    if (ya) { ya.cantidad = String(Number(ya.cantidad || 0) + 1); tipoLibre(ya); }
    else estado.lineas.push({ producto: p, cantidad: '1', descPct: '', promocionId: null, elegida: false, precioTipo: null });
    buscar.value = '';
    resultados.replaceChildren();
    zonaBuscar.replaceChildren();
    ultimaAgregada = p.producto_id;
    if (avisoAgregado) avisoAgregado.remove();
    avisoAgregado = aviso(`Agregado: ${p.nombre}`, 'ok', 1800);
    cambio();
    buscar.focus();
  }
  let ultimaAgregada = null;
  let avisoAgregado = null;

  function pintarCarrito() {
    cuentaArticulos.textContent = estado.lineas.length ? String(estado.lineas.length) : '';
    cuentaArticulos.hidden = !estado.lineas.length;
    if (!estado.lineas.length) {
      carrito.replaceChildren(lista.length
        ? estadoVacio({ icono: 'buscar', chico: true, texto: 'Busque un producto o servicio arriba para empezar.' })
        // Sin productos no se puede vender: enseña dónde agregarlos (solo si puede entrar ahí).
        : estadoVacio({ icono: 'etiqueta', color: 'dorado', titulo: 'Aún no tiene productos para vender',
          texto: 'Agregue sus productos o servicios y aquí podrá venderlos.',
          botones: [hayEnMenu(ctx.menu || [], 'inventario', 'productos') ? { texto: 'Agregar productos', href: '#/inventario/productos', icono: 'mas' } : null,
            hayEnMenu(ctx.menu || [], 'ajustes', 'excel') ? { texto: 'Subir mi Excel', href: '#/ajustes/excel', icono: 'excel' } : null] }));
      return;
    }
    const previa = estado.previa;
    carrito.replaceChildren(...estado.lineas.map((l, i) => {
      const p = l.producto;
      const pl = previa && previa.lineas ? previa.lineas[i] : null;
      const esMayorista = Boolean(pl && pl.precio_tipo === 'mayorista');
      const promos = esMayorista ? [] : (pl && pl.promociones) || [];
      const cant = h('input', { name: 'cantidad', type: 'number', min: p.permite_fracciones ? '0.001' : '1',
        step: p.permite_fracciones ? '0.001' : '1', inputmode: p.permite_fracciones ? 'decimal' : 'numeric', value: l.cantidad,
        'aria-label': `Cantidad de ${p.nombre}` });
      cant.addEventListener('change', () => { l.cantidad = cant.value; tipoLibre(l); if (!l.elegida) l.promocionId = null; cambio(); });
      const nombreLinea = h('div', { class: 'linea-nombre' }, h('strong', {}, p.nombre),
          h('span', { class: 'detalle' }, [p.tipo === 'servicio' ? 'Servicio · no mueve inventario' : p.codigo,
            p.impuesto_clase === 'gravado' ? `${p.impuesto || p.tipo_impuesto} ${p.precio_incluye_isv ? 'incluido' : 'aparte'}` : 'Exento',
            p.permite_fracciones ? `por ${p.unidad}, admite decimales` : null].filter(Boolean).join(' · ')));
      const partes = [
        (!local && fotosActivas()) ? h('div', { class: 'linea-cabeza' }, miniatura(p, { icono: p.tipo === 'servicio' ? 'servicio' : 'etiqueta', props: { class: 'burbuja-chica' } }), nombreLinea)
          : nombreLinea,
        h('div', { class: 'linea-datos' },
          campo('Cantidad', cant),
          h('div', { class: 'campo' }, h('span', { class: 'etiqueta-campo' }, 'Precio'), h('span', { class: 'monto valor-campo', dataset: { dato: 'precio-linea' } },
            dinero(pl ? pl.precio_unitario_centavos : p.precio_venta_centavos))),
          promos.length || esMayorista || porCola ? null : (() => {
            const d = h('input', { name: 'descuento', type: 'number', min: '0', max: '100', step: '0.01', inputmode: 'decimal',
              value: l.descPct, placeholder: '0' });
            // Un descuento manual va con el precio normal (nunca descuento sobre el mayorista).
            d.addEventListener('change', () => { l.descPct = d.value; if (Number(d.value) > 0 && pl && pl.precio_mayorista_disponible) l.precioTipo = 'normal'; cambio(); });
            return campo('Desc. %', d);
          })(),
          h('div', { class: 'campo' }, h('span', { class: 'etiqueta-campo' }, 'Total'),
            h('span', { class: 'monto valor-campo', dataset: { dato: 'total-linea' } }, pl ? dinero(pl.total_centavos) : '…')),
          h('button', { type: 'button', class: 'boton boton-peligro boton-quitar', 'aria-label': `Quitar ${p.nombre}`,
            onclick: () => { estado.lineas.splice(i, 1); cambio(); } }, 'Quitar')),
      ];
      // Precio mayorista (núcleo 0.18.0): chip y botón para cambiar entre normal y mayorista.
      if (pl && pl.precio_mayorista_disponible) {
        partes.push(h('div', { class: 'linea-mayorista' },
          esMayorista ? chip('Mayorista', 'azul', { dataset: { dato: 'chip-mayorista' } }) : null,
          esMayorista && pl.precio_normal_centavos ? h('span', { class: 'detalle' }, ` Precio normal ${dinero(pl.precio_normal_centavos)} · no se suma a promociones ni descuentos `) : null,
          h('button', { type: 'button', class: 'boton', dataset: { accion: 'cambiar-precio-tipo' },
            onclick: () => { l.precioTipo = esMayorista ? 'normal' : 'mayorista'; l.promocionId = null; l.elegida = false; l.descPct = ''; cambio(); } },
            esMayorista ? 'Usar precio normal' : 'Usar precio mayorista')));
      }
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
              k === 0 ? chip('Sugerida: la que más descuenta', 'verde') : null);
          })));
      }
      const nueva = ultimaAgregada === p.producto_id;
      return h('article', { class: 'linea-carrito' + (nueva ? ' linea-nueva' : ''), dataset: { producto: p.producto_id } }, ...partes);
    }));
    ultimaAgregada = null;
  }
  const cuentaArticulos = chip('', 'azul', { class: 'cuenta-articulos', hidden: true, 'aria-label': 'Artículos en la venta' });

  // ---------------- Cliente, totales y pago ----------------
  const selCliente = h('select', { id: 'cliente' }, h('option', { value: '' }, 'Consumidor final'),
    listaClientes.filter((c) => c.activo).map((c) => h('option', { value: c.id }, c.nombre + (c.rtn ? ` · RTN ${c.rtn}` : ''))));
  // Con núcleo 0.18.0 el cliente puede cambiar el precio (mayorista): se recalcula.
  selCliente.addEventListener('change', () => {
    estado.clienteId = selCliente.value;
    if (n018) { for (const l of estado.lineas) tipoLibre(l); cambio(); } else cambio(false);
  });
  const descFactura = h('input', { id: 'descuento-factura', type: 'number', min: '0', max: '100', step: '0.01', inputmode: 'decimal', placeholder: '0' });
  descFactura.addEventListener('change', () => { estado.descFactura = descFactura.value; cambio(); });
  const totales = h('div', { class: 'totales', 'aria-live': 'polite' });
  const zonaTurno = h('div', {});
  const zonaPago = h('div', { class: 'zona-pago' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const botonCobrar = h('button', { id: 'cobrar', type: 'button', class: 'boton boton-principal boton-grande boton-ancho' + (modo === 'venta' ? ' boton-cobrar' : '') }, '');

  function total() { return estado.previa ? estado.previa.total_centavos : null; }

  // Barra oscura con el TOTAL grande (app 0.15.0, como el "TOTAL" de RRD): lo primero que se ve antes de cobrar.
  function barraTotal(pv) {
    return h('div', { class: 'total-barra' }, h('span', { class: 'total-barra-texto' }, modo === 'venta' ? 'Total a cobrar' : 'Total'),
      pv ? h('span', { class: 'monto total-barra-monto', dataset: { dato: 'total' } }, dinero(pv.total_centavos))
        : h('span', { class: 'monto total-barra-monto' }, estado.lineas.length ? 'Calculando…' : dinero(0)));
  }
  function pintarTotales() {
    const pv = estado.previa;
    if (estado.errorPrevia) { totales.replaceChildren(estado.errorPrevia); }
    else if (!pv) { totales.replaceChildren(barraTotal(null)); }
    else {
      totales.replaceChildren(...[
        // Todo con ISV, como lo ve el cliente: Subtotal - Descuento = Total (lo calcula el servidor).
        h('div', { class: 'suma' }, h('span', {}, 'Subtotal'), h('span', { class: 'monto', dataset: { dato: 'subtotal' } }, dinero(pv.subtotal_con_isv_centavos))),
        pv.descuento_con_isv_centavos ? h('div', { class: 'suma' }, h('span', {}, 'Descuento'),
          h('span', { class: 'monto', dataset: { dato: 'descuento' } }, '−' + dinero(pv.descuento_con_isv_centavos))) : null,
        (pv.desglose_impuestos || []).filter((d) => d.clase === 'gravado').map((d) =>
          h('div', { class: 'suma suma-nota' }, h('span', {}, `${d.nombre} incluido`), h('span', { class: 'monto', dataset: { dato: 'isv-' + d.codigo } }, dinero(d.impuesto_centavos)))),
        pv.exento_centavos ? h('div', { class: 'suma suma-nota' }, h('span', {}, 'Exento'), h('span', { class: 'monto' }, dinero(pv.exento_centavos))) : null,
        barraTotal(pv),
        pv.descuento_pide_aprobacion ? mensaje('info', `El descuento pasa su tope (${pv.tope_descuento_porcentaje} %).`,
          'Puede seguir: la venta quedará esperando la aprobación del administrador o del dueño.', { class: 'aviso-tope' }) : null].flat().filter(Boolean));
    }
    botonCobrar.textContent = modo === 'venta' ? `Cobrar ${pv ? dinero(pv.total_centavos) : ''}`.trim() : 'Guardar cotización';
  }

  function pintarPago() {
    if (modo !== 'venta') { zonaPago.replaceChildren(); return; }
    const t = total();
    const botones = h('div', { class: 'formas', role: 'radiogroup', 'aria-label': 'Forma de pago' }, formas.map((f) =>
      h('button', { type: 'button', class: 'forma' + (estado.forma === f ? ' forma-on' : ''), role: 'radio',
        'aria-checked': estado.forma === f ? 'true' : 'false', dataset: { forma: f },
        onclick: () => { estado.forma = f; cambio(false); } },
      icono((FORMAS_VISTA[f] || ['billetes'])[0]),
      h('span', { class: 'forma-nombre' }, f === 'mixto' ? 'Mixto' : nombreForma(f)),
      h('span', { class: 'forma-ayuda' }, (FORMAS_VISTA[f] || [null, ''])[1]))));
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
      const ref = h('input', { id: 'referencia', type: 'text', maxlength: 60, value: estado.referencia });
      ref.addEventListener('input', () => { estado.referencia = ref.value; });
      // Por la cola (sin internet) la transferencia EXIGE su referencia; el banco ayuda a confirmarla.
      const exige = porCola && estado.forma === 'transferencia';
      detalle.append(campo(estado.forma === 'tarjeta' ? 'Número de voucher (opcional)'
        : exige ? 'Número de referencia de la transferencia' : 'Referencia de la transferencia (opcional)', ref,
      estado.forma === 'transferencia' ? 'La transferencia queda "por confirmar" hasta que se vea en el banco.' : null));
      if (exige) {
        const banco = h('input', { id: 'banco-transferencia', type: 'text', maxlength: 38, value: estado.banco, placeholder: 'Ej.: BAC' });
        banco.addEventListener('input', () => { estado.banco = banco.value; });
        detalle.append(campo('Banco (si lo sabe)', banco));
      }
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
    zonaPago.replaceChildren(titulo('h3', 'billetes', 'Forma de pago', { class: 'titulo-chico' }), botones, detalle);
  }

  async function pintarTurno() {
    zonaTurno.replaceChildren();
    if (local) {
      const t = cat.turno;
      zonaTurno.append(h('p', { class: 'ayuda con-icono-linea', dataset: { dato: 'turno' } }, icono('candado_abierto'),
        t ? ` Turno ${t.numero} · ${(cat.caja && cat.caja.nombre) || ''} · sin conexión` : ` ${(cat.caja && cat.caja.nombre) || ''} · sin conexión`));
      if (!estadoLocal.puede) zonaTurno.append(mensaje('error', estadoLocal.razon, null, { dataset: { dato: 'no-sin-internet' } }));
      else if (estadoLocal.quedan <= 10) zonaTurno.append(mensaje('info', `Quedan ${estadoLocal.quedan} números reservados en este equipo.`));
      return;
    }
    if (conBloque) {
      zonaTurno.append(mensaje('info', 'Esta caja tiene números reservados en este equipo.',
        'Aquí solo se cobra de contado (efectivo, tarjeta o transferencia); la venta se guarda primero en el equipo y sube enseguida. Para crédito use otra caja o devuelva los números en Ajustes > Sin internet.',
        { dataset: { dato: 'caja-con-bloque' } }));
    }
    if (!cobra || !puede('caja.turno')) return;
    try { turno = await miTurno(); } catch { turno = null; }
    if (turno) {
      zonaTurno.append(h('p', { class: 'ayuda con-icono-linea', dataset: { dato: 'turno' } }, icono('candado_abierto'), ` Turno ${turno.numero} abierto · ${turno.caja}`));
    } else if (perfil.empresa.turnos_obligatorios) {
      zonaTurno.append(mensaje('info', 'No tiene turno de caja abierto.', 'Para cobrar en efectivo abra su turno (cuente el fondo de la caja).'),
        h('button', { type: 'button', class: 'boton boton-ancho', onclick: async () => { if (await abrirTurnoDialogo()) pintarTurno(); } }, icono('candado_abierto'), 'Abrir turno'));
    }
  }

  // ---------------- Previa (servidor) ----------------
  function lineasServidor() {
    return estado.lineas.map((l) => {
      const x = { producto_id: l.producto.producto_id, cantidad: Number(l.cantidad) };
      if (l.promocionId) x.promocion_id = l.promocionId;
      if (l.precioTipo && n018) x.precio_tipo = l.precioTipo;
      const d = Number(l.descPct);
      if (l.descPct !== '' && d > 0 && !l.promocionId && l.precioTipo !== 'mayorista') x.descuento_porcentaje = d;
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
      let pv;
      if (local || estado.previaLocal) {
        pv = si.calcular(cat, { lineas: lineasServidor(), cliente_id: estado.clienteId || null });
      } else {
        try {
          pv = await rpc('calcular_venta_previa', { p_empresa_id: empresaId(),
            p_datos: { lineas: lineasServidor(), descuento_factura: descuentoFactura(), ...(n018 && estado.clienteId ? { cliente_id: estado.clienteId } : {}) } },
          { tiempo: porCola ? 10000 : 0 });
        } catch (e) {
          // El servidor no contesta y la caja tiene números en este equipo: se sigue con la foto del catálogo.
          if (!(e.sinConexion && conBloque && cat)) throw e;
          estado.previaLocal = true;
          pv = si.calcular(cat, { lineas: lineasServidor(), cliente_id: estado.clienteId || null });
        }
      }
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
      if (modo === 'venta' && porCola) {
        const reg = await cobrarPorCola(datos.pagos);
        listo = true;
        await terminadoCola(reg);
        return;
      }
      if (!estado.idOperacion) estado.idOperacion = nuevoId();
      if (modo === 'venta') {
        const r = await escribir('registrar_venta', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: estado.idOperacion });
        olvidarDatos('productos');
        listo = true;
        await terminado(r);
      } else {
        const r = await escribir('crear_cotizacion', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: estado.idOperacion });
        listo = true;
        aviso(`Cotización #${r.numero} guardada · ${dinero(r.total_centavos)}`);
        if (alTerminar) alTerminar(r);
      }
    } catch (err) {
      zonaError.append(err instanceof Node ? err : await cajaError(err));
    } finally {
      if (!listo) { botonCobrar.disabled = false; pintarTotales(); }
    }
  });

  // ---------------- Por la cola (sin internet o caja con bloque) ----------------
  async function cobrarPorCola(pagosVenta) {
    const t = total();
    const sinRed = local || estado.previaLocal;
    const p = pagosVenta[0];
    if (pagosVenta.length !== 1 || !['efectivo', 'tarjeta', 'transferencia'].includes(p.forma)) {
      throw errorSimple('Aquí solo se cobra de contado: efectivo, tarjeta o transferencia.');
    }
    if (sinRed && p.forma === 'tarjeta') throw errorSimple('Sin internet no se cobra con tarjeta (el POS necesita conexión).', 'Cobre en efectivo o con transferencia.');
    if (p.forma === 'transferencia') {
      if (estado.referencia.trim().length < 3) throw errorSimple('Escriba el número de referencia de la transferencia.', 'Sin la referencia no se puede confirmar después en el banco.');
      if (estado.banco.trim()) p.banco = estado.banco.trim();
    }
    const est = await si.estadoVenta(perfil);
    if (sinRed) {
      if (!est.puede) throw errorSimple(est.razon);
      const reglas = est.cat.reglas;
      if (t > reglas.tope_venta_centavos) throw errorSimple(`Sin internet una venta no puede pasar de ${dinero(reglas.tope_venta_centavos)}.`, 'Divida la venta o espere el internet.');
      const vendido = (await si.cola(perfil.empresa.id)).filter((x) => x.usuario_id === perfil.usuario.id && !x.payload.en_linea
        && x.payload.bloque_id === est.bloque.bloque_id).reduce((s2, x) => s2 + x.total_centavos, 0);
      if (vendido + t > reglas.tope_turno_centavos) throw errorSimple(`Lo vendido sin internet en este turno pasaría de ${dinero(reglas.tope_turno_centavos)}.`, 'Espere el internet para seguir vendiendo.');
    } else if (!est.bloque && !(conBloque && conBloque.bloque)) {
      throw errorSimple('Este equipo no tiene números reservados para esta caja.');
    }
    const nombre = (perfil.usuario && (perfil.usuario.nombre || perfil.usuario.correo)) || '';
    const reg = await si.guardarVenta(perfil, { usuario: { id: perfil.usuario.id, nombre }, calculo: estado.previa,
      cliente_id: estado.clienteId || null, pagos: pagosVenta, en_linea: !sinRed }, { fallar: window.__fallarGuardarVenta === true });
    if (!sinRed) {
      try { await si.subir(perfil.empresa.id); } catch { /* queda en la cola: sube sola */ }
      const ahora = (await si.cola(perfil.empresa.id)).find((x) => x.id_operacion === reg.id_operacion);
      return ahora || reg;
    }
    si.programarSubida(true);
    return reg;
  }

  async function terminadoCola(reg) {
    const nueva = h('a', { class: 'boton', href: '#/vender/nueva', onclick: (ev) => { ev.preventDefault(); reiniciar(); } }, 'Nueva venta');
    // Las existencias cambiaron: se vuelven a leer, salvo si la venta fue sin conexión (sin red no se podrían leer).
    if (!local && reg.payload.en_linea) olvidarDatos('productos');
    const p = reg.payload.pagos[0];
    const como = `en ${nombreForma(p.forma).toLowerCase()}`;
    const subida = reg.estado === 'subida' && reg.resultado && reg.resultado.venta_id;
    const hecho = subida ? `Venta ${reg.numero_documento} guardada · ${dinero(reg.total_centavos)} ${como}`
      : `Venta ${reg.numero_documento} guardada en este equipo · ${dinero(reg.total_centavos)} ${como}`;
    aviso(hecho);
    const vuelto = p.recibido_centavos ? p.recibido_centavos - p.monto_centavos : 0;
    const cabeza = h('div', { class: `mensaje ${reg.estado === 'por_resolver' ? 'mensaje-error' : 'mensaje-ok'} con-icono venta-lista resultado`, role: 'status',
      dataset: { estado: reg.estado } }, icono(reg.estado === 'por_resolver' ? 'alerta' : 'check_circulo'),
    h('div', {}, h('p', {}, h('strong', {}, hecho)),
      reg.estado === 'en_equipo' ? h('p', {}, 'Se sube sola cuando vuelva el internet.') : null,
      reg.estado === 'por_resolver' ? h('p', {}, 'Quedó por resolver: ', (reg.resultado && reg.resultado.problema_texto) || '') : null,
      vuelto ? h('p', { class: 'vuelto-grande' }, 'Vuelto: ', h('strong', { class: 'monto', dataset: { dato: 'vuelto-final' } }, dinero(vuelto))) : null));
    if (subida) {
      vista.replaceChildren(cabeza, h('p', { class: 'cargando' }, 'Preparando el comprobante…'));
      try {
        vista.replaceChildren(cabeza, await vistaComprobante(reg.resultado.venta_id, { extra: [nueva] }));
        return;
      } catch { /* sin conexión justo ahora: el comprobante del equipo */ }
    }
    vista.replaceChildren(cabeza, vistaComprobanteLocal(reg, { extra: [nueva] }));
  }

  async function terminado(r) {
    const cli = listaClientes.find((c) => c.id === r.cliente_id);
    const nueva = h('a', { class: 'boton', href: '#/vender/nueva', onclick: (ev) => { ev.preventDefault(); reiniciar(); } }, 'Nueva venta');
    if (r.estado === 'pendiente_aprobacion') {
      aviso(`Venta #${r.numero} en espera de aprobación · ${dinero(r.total_centavos)}`, 'info');
      vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-pend' },
        titulo('h1', 'reloj', `Venta #${r.numero} esperando aprobación`, { id: 't-pend' }),
        mensaje('info', 'La venta quedó pendiente de aprobación.',
          `Total ${dinero(r.total_centavos)}. Todavía no se cobró ni salió mercadería. Cuando el administrador o el dueño la apruebe, se emite sola con estas formas de pago.`,
          { dataset: { dato: 'pendiente' } }),
        h('div', { class: 'botones' }, nueva)));
      return;
    }
    // "Venta T-001-001-00000015 guardada · L 850.00 en efectivo" (datos que devuelve el servidor).
    const como = estado.forma === 'credito' ? 'al crédito' : estado.forma === 'mixto' ? 'con pago mixto' : `en ${nombreForma(estado.forma).toLowerCase()}`;
    const hecho = `Venta ${r.numero_documento || '#' + r.numero} guardada · ${dinero(r.total_centavos)} ${como}`;
    aviso(hecho);
    const cabeza = h('div', { class: 'mensaje mensaje-ok con-icono venta-lista resultado', role: 'status' }, icono('check_circulo'),
      h('div', {}, h('p', {}, h('strong', {}, hecho)),
        r.vuelto_centavos ? h('p', { class: 'vuelto-grande' }, 'Vuelto: ', h('strong', { class: 'monto', dataset: { dato: 'vuelto-final' } }, dinero(r.vuelto_centavos))) : null));
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
        h('label', { for: 'buscar-producto', class: 'etiqueta-grande titulo-icono' }, icono('buscar'), 'Buscar producto o servicio'),
        h('div', { class: 'buscar-fila' }, buscar, botonCamara),
        h('p', { class: 'ayuda', id: 'ayuda-buscar' }, 'Con lector de códigos: apunte y listo (escribe el código y Enter).'),
        zonaBuscar, resultados),
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-carrito' },
        titulo('h2', 'bolsa', [modo === 'venta' ? 'Artículos' : 'Artículos de la cotización', ' ', cuentaArticulos], { id: 't-carrito' }), carrito)),
    // El "ticket" de la derecha (app 0.15.0): cliente, forma de pago y, abajo, el total grande y Cobrar.
    h('aside', { class: 'vender-der tarjeta', 'aria-label': 'Cobro' },
      titulo('h2', modo === 'venta' ? 'cobrar' : 'documento', modo === 'venta' ? 'Cobro' : 'Cotización', { class: 'titulo-ticket' }),
      zonaTurno,
      campo('Cliente', selCliente, modo === 'venta' ? 'Opcional. El crédito necesita cliente.' : null),
      // El descuento a toda la factura se usa poco: plegado (se abre solo si ya tiene un valor).
      porCola ? null : h('details', { class: 'plegable', open: estado.descFactura !== '' ? true : null },
        h('summary', {}, icono('mas'), 'Descuento a toda la factura'),
        campo('Descuento a toda la factura (%)', descFactura, 'Solo va a las líneas sin promoción ni otro descuento.')),
      zonaPago,
      !cobra && modo === 'venta' && !porCola ? mensaje('info', 'Usted puede vender al crédito o hacer una cotización.',
        'El cobro en efectivo, tarjeta o transferencia lo hace el cajero.') : null,
      // Abajo y siempre a la vista en la computadora: el total grande y Cobrar.
      h('div', { class: 'ticket-pie' }, totales, zonaError, botonCobrar)));
  vista.append(raiz);
  ajustarTicket(raiz.querySelector('.vender-der'));
  pintarTodo();
  pintarTurno();
  buscar.focus();
}
