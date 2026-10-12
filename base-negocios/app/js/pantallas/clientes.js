// Clientes · lista con búsqueda, ficha (estado de cuenta y antigüedad), cobrar abono
// (registrar_cobro: a la más vieja o eligiendo facturas; lo que sobra queda a favor solo si
// se confirma) y crear o editar cliente (límite y plazo solo con terceros.credito).
import { rpc, leer, escribir, nuevoId } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo } from '../sesion.js';
import { dinero, fecha, aCentavos, paraCampo } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, enlaceWhatsApp } from '../ui.js';
import { clientes, filtrar, olvidarDatos } from '../datos.js';
import { nombreForma } from '../comprobante.js';

const verCxc = () => tieneModulo('ventas') && puede('ventas.ver');

export async function mostrar(vista, ctx) {
  const [lista, saldos] = await Promise.all([clientes(true),
    verCxc() ? leer('v_cxc_cliente', { empresa_id: empresaId() }, { limite: 1000 }) : []]);
  if (!ctx.sigueVigente()) return;
  const porId = new Map(saldos.map((s) => [s.cliente_id, s]));
  const buscar = h('input', { id: 'buscar-cliente', type: 'search', placeholder: 'Nombre, RTN o teléfono', autocomplete: 'off' });
  const zona = h('div', { class: 'lista' });
  const pintar = () => {
    const vistos = filtrar(lista, buscar.value, ['nombre', 'rtn', 'telefono', 'codigo']);
    zona.replaceChildren(...(vistos.length ? vistos.slice(0, 200).map((c) => {
      const s = porId.get(c.id);
      return h('article', { class: 'venta-fila', dataset: { cliente: c.id } },
        h('div', {}, h('strong', {}, c.nombre), !c.activo ? h('span', { class: 'etiqueta' }, 'Inactivo') : null,
          h('span', { class: 'detalle' }, [c.rtn ? 'RTN ' + c.rtn : null, c.telefono].filter(Boolean).join(' · ') || 'Sin RTN ni teléfono')),
        s && s.saldo_centavos ? h('span', { class: 'monto' + (s.vencido_centavos ? ' peligro' : '') }, dinero(s.saldo_centavos)) : h('span', {}, ''),
        h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => abrirFicha(vista, ctx, c.id) }, 'Ver')));
    }) : [h('p', { class: 'vacio' }, 'No hay clientes con ese nombre.')]));
  };
  buscar.addEventListener('input', pintar);
  pintar();
  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cli' },
    h('div', { class: 'titulo-con-boton' }, h('h1', { id: 't-cli' }, 'Clientes'),
      puede('terceros.editar') ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nuevo-cliente',
        onclick: () => formularioCliente(vista, ctx, null) }, 'Nuevo cliente') : null),
    campo('Buscar', buscar), zona));
}

// Ficha del cliente. Con opciones.cobrar abre directo el cobro.
export async function abrirFicha(vista, ctx, clienteId, opciones = {}) {
  vista.replaceChildren(h('p', { class: 'cargando' }, 'Cargando…'));
  try {
    const [cli] = await leer('tercero', { id: clienteId });
    const [s] = verCxc() ? await leer('v_cxc_cliente', { empresa_id: empresaId(), cliente_id: clienteId }) : [];
    const ec = verCxc() ? await rpc('estado_cuenta_cliente', { p_empresa_id: empresaId(), p_cliente_id: clienteId }) : null;
    if (!ctx.sigueVigente()) return;
    if (opciones.cobrar) return formularioCobro(vista, ctx, cli, ec);
    const volver = h('button', { type: 'button', class: 'boton', onclick: () => { vista.replaceChildren(); mostrar(vista, ctx); } }, 'Volver a la lista');
    const dato = (t, v) => (v || v === 0 ? h('div', { class: 'fila' }, h('span', {}, t), h('span', {}, v)) : null);
    const saldo = ec ? ec.saldo_actual_centavos : 0;
    vista.replaceChildren(...[
      h('section', { class: 'tarjeta', 'aria-labelledby': 't-ficha' },
        h('h1', { id: 't-ficha' }, cli.nombre),
        dato('Código', cli.codigo), dato('RTN', cli.rtn), dato('Teléfono', cli.telefono), dato('Correo', cli.correo), dato('Dirección', cli.direccion),
        dato('Límite de crédito', dinero(cli.limite_credito_centavos)), dato('Plazo', `${cli.plazo_dias || 0} días`),
        h('div', { class: 'botones' },
          puede('terceros.editar') ? h('button', { type: 'button', class: 'boton', onclick: () => formularioCliente(vista, ctx, cli) }, 'Editar') : null,
          ec && saldo > 0 && puede('ventas.cobrar') ? h('button', { type: 'button', class: 'boton boton-principal', id: 'cobrar-abono',
            onclick: () => formularioCobro(vista, ctx, cli, ec) }, 'Cobrar abono') : null,
          volver)),
      ec ? h('section', { class: 'tarjeta', 'aria-labelledby': 't-ec' },
        h('h2', { id: 't-ec' }, 'Estado de cuenta'),
        h('div', { class: 'cifras' },
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Debe'), h('p', { class: 'cifra-valor', dataset: { dato: 'saldo-cliente' } }, dinero(saldo))),
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Vencido'), h('p', { class: 'cifra-valor' + (s && s.vencido_centavos ? ' peligro' : '') }, dinero(s ? s.vencido_centavos : 0))),
          h('div', { class: 'cifra-chica' }, h('p', { class: 'cifra-titulo' }, 'Saldo a favor'), h('p', { class: 'cifra-valor', dataset: { dato: 'saldo-favor' } }, dinero(ec.saldo_favor_centavos)))),
        s ? h('div', { class: 'antiguedad' }, [['0 a 30 días', s.de_0_a_30], ['31 a 60', s.de_31_a_60], ['61 a 90', s.de_61_a_90], ['Más de 90', s.mas_de_90]]
          .map(([t, v]) => h('div', {}, h('span', { class: 'detalle' }, t), h('span', { class: 'monto' }, dinero(v))))) : null,
        h('h3', { class: 'titulo-chico' }, 'Facturas pendientes'),
        ec.pendientes.length ? ec.pendientes.map((p) => h('div', { class: 'fila' },
          h('span', {}, p.documento, h('span', { class: 'detalle' }, `${fecha(p.fecha)} · vence ${fecha(p.vence_el)}${p.dias_vencido > 0 ? ` · ${p.dias_vencido} días vencida` : ''}`)),
          h('span', { class: 'monto' + (p.dias_vencido > 0 ? ' peligro' : '') }, dinero(p.saldo_centavos))))
          : h('p', { class: 'vacio' }, 'No debe nada.'),
        h('h3', { class: 'titulo-chico' }, 'Movimientos'),
        ec.movimientos.slice(-30).reverse().map((m) => h('div', { class: 'fila' },
          h('span', {}, `${m.documento || ''} ${m.referencia ? '· ' + m.referencia : ''}`, h('span', { class: 'detalle' }, fecha(m.fecha))),
          h('span', { class: 'monto' }, m.cargo_centavos ? '+' + dinero(m.cargo_centavos) : '-' + dinero(m.abono_centavos))))) : null].filter(Boolean));
  } catch (err) {
    vista.replaceChildren(await cajaError(err));
  }
}

function formularioCobro(vista, ctx, cli, ec) {
  const deuda = ec.saldo_actual_centavos;
  const formas = ['efectivo', 'tarjeta', 'transferencia'];
  const monto = h('input', { id: 'abono-monto', type: 'text', inputmode: 'decimal', autocomplete: 'off', value: paraCampo(deuda) });
  const selForma = h('select', { id: 'abono-forma' }, formas.map((f) => h('option', { value: f }, nombreForma(f))));
  const referencia = h('input', { id: 'abono-referencia', type: 'text', maxlength: 100 });
  const elegir = h('input', { type: 'checkbox', id: 'abono-elegir' });
  const zonaFacturas = h('div', { class: 'lista', hidden: true });
  const excedente = h('input', { type: 'checkbox', id: 'abono-excedente' });
  const zonaExcedente = h('label', { class: 'mensaje mensaje-info confirmar-excedente', hidden: true }, excedente, h('span', {}));
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Cobrar');
  const id = nuevoId();
  // Facturas pendientes (la más vieja primero) con el monto a aplicar.
  let docs = [];
  leer('v_cxc_documento', { empresa_id: empresaId(), cliente_id: cli.id }, { orden: 'fecha_documento.asc', limite: 500 }).then((filas) => {
    docs = filas.filter((d) => d.saldo_centavos > 0).map((d) => ({ d, si: h('input', { type: 'checkbox' }),
      x: h('input', { type: 'text', inputmode: 'decimal', value: paraCampo(d.saldo_centavos), 'aria-label': `Monto para ${d.numero_documento}` }) }));
    zonaFacturas.replaceChildren(...docs.map(({ d, si, x }) => h('div', { class: 'linea-devolver' },
      h('label', {}, si, ` ${d.numero_documento} · ${fecha(d.fecha_documento)}`, h('span', { class: 'detalle' }, `Saldo ${dinero(d.saldo_centavos)}`)), x)));
  }).catch(async (err) => zonaFacturas.append(await cajaError(err)));
  elegir.addEventListener('change', () => { zonaFacturas.hidden = !elegir.checked; revisar(); });
  monto.addEventListener('input', revisar);
  // ¿Sobra? Se pide confirmar que lo que sobra quede a favor del cliente.
  function aplicarElegido() {
    return docs.filter((x) => x.si.checked).reduce((s, x) => s + (aCentavos(x.x.value) || 0), 0);
  }
  function revisar() {
    const m = aCentavos(monto.value) || 0;
    const tope = elegir.checked ? aplicarElegido() : deuda;
    const sobra = m - tope;
    zonaExcedente.hidden = !(sobra > 0);
    zonaExcedente.lastChild.textContent = ` Recibe ${dinero(m)} y debe ${dinero(tope)}: los ${dinero(Math.max(sobra, 0))} que sobran quedan como saldo a favor de ${cli.nombre}.`;
  }
  zonaFacturas.addEventListener('input', revisar);
  zonaFacturas.addEventListener('change', revisar);
  const form = h('form', { class: 'formulario', novalidate: true },
    h('p', {}, `Debe ${dinero(deuda)}.`),
    campo('Monto que paga (L)', monto), campo('Forma de pago', selForma), campo('Referencia (opcional)', referencia),
    h('label', { class: 'opcion-check' }, elegir, ' Elegir a qué facturas va (si no, a la más vieja primero)'),
    zonaFacturas, zonaExcedente, zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => abrirFicha(vista, ctx, cli.id) }, 'Volver'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(monto.value);
    if (!m) { zonaError.append(errorSimple('Escriba el monto que paga.')); return; }
    const pago = { forma: selForma.value, monto_centavos: m };
    if (referencia.value.trim()) pago.referencia = referencia.value.trim();
    const datos = { cliente_id: cli.id, pagos: [pago] };
    if (elegir.checked) {
      const ap = docs.filter((x) => x.si.checked).map((x) => ({ ...(x.d.origen === 'saldo_inicial' ? { saldo_inicial_id: x.d.documento_id } : { venta_id: x.d.venta_id }),
        monto_centavos: aCentavos(x.x.value) }));
      if (!ap.length || ap.some((a) => !a.monto_centavos)) { zonaError.append(errorSimple('Marque las facturas y escriba cuánto va a cada una.')); return; }
      datos.aplicar = ap;
    }
    if (!zonaExcedente.hidden) {
      if (!excedente.checked) { zonaError.append(errorSimple('Lo que paga es más de lo que debe.', 'Marque la casilla si lo que sobra queda a su favor, o baje el monto.')); return; }
      datos.excedente = 'saldo_favor';
    }
    const r = await conBoton(boton, zonaError, () => escribir('registrar_cobro', { p_empresa_id: empresaId(), p_datos: datos, p_id_operacion: id }), 'Cobrando…');
    if (!r) return;
    aviso(`Cobro #${r.numero} registrado por ${dinero(r.monto_centavos)}.`);
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-cobok' },
      h('h1', { id: 't-cobok' }, `Cobro #${r.numero} de ${cli.nombre}`),
      h('div', { class: 'fila' }, h('span', {}, 'Recibido'), h('span', { class: 'monto' }, dinero(r.monto_centavos))),
      h('div', { class: 'fila' }, h('span', {}, 'Aplicado a facturas'), h('span', { class: 'monto', dataset: { dato: 'aplicado' } }, dinero(r.aplicado_centavos))),
      (r.aplicaciones || []).map((a) => h('div', { class: 'fila' }, h('span', { class: 'detalle' }, a.documento), h('span', { class: 'monto' }, dinero(a.monto_centavos)))),
      r.excedente_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Queda a su favor'), h('span', { class: 'monto', dataset: { dato: 'excedente' } }, dinero(r.excedente_centavos))) : null,
      r.vuelto_centavos ? h('div', { class: 'fila' }, h('span', {}, 'Vuelto'), h('span', { class: 'monto' }, dinero(r.vuelto_centavos))) : null,
      h('div', { class: 'fila fila-total' }, h('span', {}, 'Todavía debe'), h('span', { class: 'monto', dataset: { dato: 'saldo-restante' } }, dinero(r.saldo_cliente_centavos))),
      h('div', { class: 'botones' }, h('button', { type: 'button', class: 'boton', onclick: () => abrirFicha(vista, ctx, cli.id) }, 'Ver la ficha'))));
  });
  revisar();
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-abono' },
    h('h1', { id: 't-abono' }, `Cobrar a ${cli.nombre}`), form));
}

// Crear (cli = null) o editar un cliente.
function formularioCliente(vista, ctx, cli) {
  const credito = puede('terceros.credito');
  const v = (k) => (cli && cli[k] !== null && cli[k] !== undefined ? String(cli[k]) : '');
  const f = {
    nombre: h('input', { id: 'cli-nombre', type: 'text', maxlength: 200, required: true, value: v('nombre') }),
    rtn: h('input', { id: 'cli-rtn', type: 'text', inputmode: 'numeric', maxlength: 20, value: v('rtn') }),
    telefono: h('input', { id: 'cli-telefono', type: 'tel', maxlength: 20, value: v('telefono') }),
    correo: h('input', { id: 'cli-correo', type: 'email', maxlength: 200, value: v('correo') }),
    direccion: h('input', { id: 'cli-direccion', type: 'text', maxlength: 300, value: v('direccion') }),
    limite: h('input', { id: 'cli-limite', type: 'text', inputmode: 'decimal', value: cli ? paraCampo(cli.limite_credito_centavos) : '' }),
    plazo: h('input', { id: 'cli-plazo', type: 'number', min: '0', max: '365', step: '1', value: v('plazo_dias') }),
  };
  const motivo = h('input', { id: 'cli-motivo', type: 'text', maxlength: 300 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, cli ? 'Guardar cambios' : 'Crear cliente');
  const id = nuevoId();
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Nombre', f.nombre), campo('RTN (opcional)', f.rtn, '14 números. Puede escribirlo con guiones.'),
    campo('Teléfono (opcional)', f.telefono), campo('Correo (opcional)', f.correo), campo('Dirección (opcional)', f.direccion),
    credito ? campo('Límite de crédito (L)', f.limite, '0 = sin crédito directo (cada venta al crédito pide aprobación).') : null,
    credito ? campo('Plazo para pagar (días)', f.plazo) : null,
    cli ? campo('Motivo del cambio', motivo, 'Pídalo si cambia el crédito. Queda en la bitácora.') : null,
    zonaError, boton,
    h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => (cli ? abrirFicha(vista, ctx, cli.id) : (vista.replaceChildren(), mostrar(vista, ctx))) }, 'Cancelar'));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const datos = {};
    const nombre = f.nombre.value.trim();
    if (nombre.length < 2) { zonaError.append(errorSimple('Escriba el nombre del cliente.')); return; }
    const rtn = f.rtn.value.replace(/\D/g, '');
    if (rtn && rtn.length !== 14) { zonaError.append(errorSimple('El RTN debe tener 14 números.', `Tiene ${rtn.length}. Revíselo.`)); return; }
    const tel = f.telefono.value.replace(/\D/g, '');
    if (tel && (tel.length < 8 || tel.length > 15)) { zonaError.append(errorSimple('El teléfono debe tener de 8 a 15 números.')); return; }
    const pon = (k, val, antes) => {
      if (!cli) { if (val !== '') datos[k] = val; return; }
      if (String(val ?? '') !== String(antes ?? '')) datos[k] = val === '' ? null : val;
    };
    pon('nombre', nombre, cli && cli.nombre);
    pon('rtn', rtn, cli && cli.rtn);
    pon('telefono', tel, cli && cli.telefono);
    pon('correo', f.correo.value.trim(), cli && cli.correo);
    pon('direccion', f.direccion.value.trim(), cli && cli.direccion);
    if (credito) {
      const lim = f.limite.value.trim() === '' ? 0 : aCentavos(f.limite.value);
      if (lim === null) { zonaError.append(errorSimple('El límite de crédito no es un monto válido.')); return; }
      const plazo = f.plazo.value === '' ? 0 : Number(f.plazo.value);
      if (!Number.isInteger(plazo) || plazo < 0 || plazo > 365) { zonaError.append(errorSimple('El plazo va de 0 a 365 días.')); return; }
      if (!cli || lim !== Number(cli.limite_credito_centavos)) datos.limite_credito_centavos = lim;
      if (!cli || plazo !== Number(cli.plazo_dias || 0)) datos.plazo_dias = plazo;
    }
    if (cli && !Object.keys(datos).length) { abrirFicha(vista, ctx, cli.id); return; }
    const r = await conBoton(boton, zonaError, () => (cli
      ? escribir('editar_tercero', { p_empresa_id: empresaId(), p_tercero_id: cli.id, p_datos: datos, p_motivo: motivo.value.trim() || null })
      : escribir('crear_tercero', { p_empresa_id: empresaId(), p_datos: { ...datos, es_cliente: true }, p_id_operacion: id })));
    if (!r) return;
    olvidarDatos('clientes');
    aviso(cli ? 'Cliente actualizado.' : 'Cliente creado.');
    abrirFicha(vista, ctx, cli ? cli.id : r.tercero_id);
  });
  vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-fcli' },
    h('h1', { id: 't-fcli' }, cli ? `Editar ${cli.nombre}` : 'Nuevo cliente'), form));
  f.nombre.focus();
}

// Mensaje amable para cobrar por WhatsApp.
export function mensajeCobro(nombre, saldo, vencido) {
  const negocio = perfilActual().empresa.nombre;
  return `Hola ${nombre}, le saluda ${negocio}. Le recordamos con cariño que tiene un saldo pendiente de ${dinero(saldo)}`
    + (vencido > 0 ? ` (de eso, ${dinero(vencido)} ya venció)` : '')
    + '. Puede pasar a pagar o responder este mensaje para coordinar. ¡Muchas gracias por su preferencia!';
}
export { enlaceWhatsApp };
