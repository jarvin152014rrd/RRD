// Inicio · "Mi negocio hoy" (app 0.5.0): saludo, acciones rápidas, 4 cifras, ventas de 7 días,
// lo más vendido, "Primeros pasos" (dueño y admin) y Pendientes.
// Todo sale de lecturas que YA existen en el núcleo (no se guarda nada nuevo):
//   resumen_hoy, donde_esta_mi_dinero, mi_turno, alertas_activas, v_aprobacion,
//   v_ventas_por_dia, mas_vendido (núcleo 0.16.0; antes v_venta_linea), v_cxp_documento, estado_arranque,
//   marca_empresa, v_turno_caja.
// Cada parte sale solo si el servidor la manda (permisos); si una falla, las demás siguen.
import { rpc, leer, rpcSiExiste } from '../api.js';
import { empresaId, perfilActual, puede, tieneModulo } from '../sesion.js';
import { dinero, fechaLarga, porcentaje, cantidad } from '../formato.js';
import { h, icono, chip, burbuja, cajaError, tarjetaCifra, botonAccion, graficaBarras, filaIcono, estadoVacio, cabezaPantalla } from '../ui.js';
import { MENU, hayEnMenu } from '../menu.js';
import { tarjetaAlerta, leerAlertas } from './alertas.js';
import { pendientes, listaAprobaciones } from './aprobaciones.js';
import { fotosActivas, miniatura, porProducto } from '../fotos.js';
import { productos } from '../datos.js';

const LIMITE_LINEAS = 1000; // líneas de venta que se leen para "lo más vendido"

async function parte(promesa) {
  try { return { ok: await promesa }; } catch (err) { return { err }; }
}

// ---------------- Fechas (siempre con la zona del negocio) ----------------
const zonaNegocio = () => perfilActual().empresa.zona_horaria || 'America/Tegucigalpa';
// "Hoy" según el reloj de esta máquina en la zona del negocio. Solo sirve para pedir datos con un
// día de margen; lo que se MUESTRA usa la fecha que trae el servidor (resumen_hoy -> fecha), así una
// app que pasó la noche abierta no se queda en el día anterior.
function hoyDeLaMaquina() {
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone: zonaNegocio(), year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  } catch { return perfilActual().empresa.hoy; }
}
function mayuscula(t) { return t ? t[0].toUpperCase() + t.slice(1) : t; }
function sumarDias(iso, n) {
  const [a, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(a, m - 1, d + n, 12)).toISOString().slice(0, 10);
}
function diaCorto(iso) {
  const [a, m, d] = iso.split('-').map(Number);
  const t = new Date(Date.UTC(a, m - 1, d, 12)).toLocaleDateString('es-HN', { weekday: 'short', timeZone: 'UTC' });
  return mayuscula(t.replace('.', ''));
}
// "viernes 24"
function diaYNumero(iso) {
  const [a, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(a, m - 1, d, 12)).toLocaleDateString('es-HN', { weekday: 'long', timeZone: 'UTC' }) + ' ' + d;
}
function saludoSegunHora() {
  let hora = 12;
  try { hora = Number(new Intl.DateTimeFormat('en-US', { hour: 'numeric', hourCycle: 'h23', timeZone: zonaNegocio() }).format(new Date())); } catch { /* hora de la máquina */ }
  return hora < 12 ? 'Buenos días' : hora < 19 ? 'Buenas tardes' : 'Buenas noches';
}
function horaCorta(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleTimeString('es-HN', { timeZone: zonaNegocio(), hour: 'numeric', minute: '2-digit', hour12: true });
}
const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`;
// Monto corto para la gráfica: L 5,095.00 -> "5,095" (computadora) y "5.1 mil" (celular).
const enteros = (c) => Math.round(c / 100).toLocaleString('en-US');
const corto = (c) => (c >= 100000 ? `${(Math.round(c / 10000) / 10).toLocaleString('en-US')} mil` : enteros(c));

// ---------------- Partes de la pantalla ----------------
function acciones(menu, turno) {
  const hay = (p, s) => hayEnMenu(menu, p, s);
  const lista = [];
  if (hay('vender', 'nueva')) {
    // Con palabras del rubro (ej. "Nueva orden de trabajo") el botón usa ese título.
    const sub = menu.find((p) => p.id === 'vender').subs.find((s) => s.id === 'nueva');
    const normal = MENU.find((p) => p.id === 'vender').subs.find((s) => s.id === 'nueva').titulo;
    lista.push(botonAccion({ href: '#/vender/nueva', icono: 'vender', texto: sub.titulo !== normal ? sub.titulo : 'Vender', principal: true, id: 'accion-vender' }));
  }
  const cobrar = hay('caja', 'cobros') ? '#/caja/cobros' : hay('clientes', 'me-deben') && puede('ventas.cobrar') ? '#/clientes/me-deben' : null;
  if (cobrar) lista.push(botonAccion({ href: cobrar, icono: 'cobrar', color: 'verde', texto: 'Cobrar a un cliente', id: 'accion-cobrar' }));
  if (hay('caja', 'gasto')) lista.push(botonAccion({ href: '#/caja/gasto', icono: 'recibo', color: 'rojo', texto: 'Registrar un gasto', id: 'accion-gasto' }));
  if (hay('caja', 'turno')) {
    lista.push(botonAccion({ href: '#/caja/turno', icono: turno ? 'candado' : 'candado_abierto', color: 'azul',
      texto: turno ? 'Cerrar mi caja' : 'Abrir mi caja', id: 'accion-turno' }));
  }
  return lista.length ? h('nav', { class: 'acciones', 'aria-label': 'Acciones rápidas' }, lista) : null;
}

function cifras(r, donde, cxp, menu, hoy) {
  const t = [];
  const limitado = Boolean(r.solo_mis_sucursales);
  if (r.ventas_hoy) {
    const v = r.ventas_hoy;
    const p = v.porcentaje;
    t.push(tarjetaCifra({ dato: 'ventas_hoy', icono: 'sube', color: 'verde', etiqueta: 'Vendí hoy', valor: dinero(v.total_centavos),
      chip: p === null || p === undefined ? chip(`Ayer: ${dinero(v.ayer_centavos)}`, 'neutro') : chip(`${porcentaje(p)} que ayer`, p >= 0 ? 'verde' : 'rojo'),
      nota: `· ${plural(v.cantidad || 0, 'venta', 'ventas')}` }));
  }
  if (limitado && r.dinero) {
    // Usuario limitado a sus sucursales: donde_esta_mi_dinero trae TODA la empresa; se usa el de
    // resumen_hoy, que ya viene filtrado (sus sucursales + cuentas de toda la empresa como el banco).
    t.push(tarjetaCifra({ dato: 'en_caja', icono: 'caja', color: 'azul', etiqueta: 'Dinero disponible en mis sucursales',
      valor: dinero(r.dinero.disponible_centavos),
      chip: r.dinero.por_confirmar_centavos ? chip(`${dinero(r.dinero.por_confirmar_centavos)} por confirmar`, 'dorado') : null,
      nota: 'Cajas, caja chica y bancos que usted ve' }));
  } else if (donde) {
    const pt = donde.por_tipo || {};
    const efectivo = (pt.efectivo_caja || 0) + (pt.caja_chica || 0);
    // Por confirmar de la MISMA lectura que el monto grande (así cuadran).
    const porConfirmar = (pt.transito || 0) + (pt.pos_por_liquidar || 0) + (pt.transferencia_por_confirmar || 0);
    t.push(tarjetaCifra({ dato: 'en_caja', icono: 'caja', color: 'azul', etiqueta: 'Hay en caja ahora', valor: dinero(efectivo),
      chip: porConfirmar ? chip(`${dinero(porConfirmar)} por confirmar`, 'dorado') : null,
      nota: [`En bancos ${dinero(pt.banco || 0)}`, hayEnMenu(menu, 'dinero', 'donde') ? [' · ', h('a', { href: '#/dinero/donde' }, 'Ver todo')] : null] }));
  }
  if (r.te_deben && tieneModulo('ventas')) {
    const d = r.te_deben;
    t.push(tarjetaCifra({ dato: 'te_deben', icono: 'clientes', color: 'dorado', etiqueta: 'Me deben', valor: dinero(d.total_centavos),
      chip: d.vencido_centavos > 0 ? chip(`${dinero(d.vencido_centavos)} vencido`, 'rojo') : chip('Nada vencido', 'verde'),
      nota: `· ${plural(d.clientes || 0, 'cliente', 'clientes')}` }));
  }
  if (r.debes && tieneModulo('compras')) {
    const d = r.debes;
    // Limitado a sucursal: los saldos iniciales de proveedores no tienen sucursal; no cuentan.
    const proximo = (cxp || []).find((x) => x.saldo_centavos > 0 && x.fecha_vencimiento && x.fecha_vencimiento >= hoy
      && !(limitado && x.origen === 'saldo_inicial'));
    t.push(tarjetaCifra({ dato: 'debes', icono: 'baja', color: 'rojo', etiqueta: 'Debo a proveedores', valor: dinero(d.total_centavos),
      chip: d.vencido_centavos > 0 ? chip(`${dinero(d.vencido_centavos)} vencido`, 'rojo') : chip('Nada vencido', 'verde'),
      nota: proximo ? `· Próximo pago: ${proximo.fecha_vencimiento === hoy ? 'hoy' : diaYNumero(proximo.fecha_vencimiento)} · ${dinero(proximo.saldo_centavos)}`
        : `· ${plural(d.proveedores || 0, 'proveedor', 'proveedores')}` }));
  }
  return t;
}

function graficaSemana(filas, hoy) {
  const por = new Map(filas.map((f) => [f.fecha, Number(f.total_centavos) || 0]));
  const barras = [];
  for (let i = 6; i >= 0; i--) {
    const f = sumarDias(hoy, -i);
    const c = por.get(f) || 0;
    barras.push({ etiqueta: i === 0 ? 'Hoy' : diaCorto(f), valor: c, texto: enteros(c), textoCorto: corto(c), destacado: i === 0, dato: f });
  }
  const total = barras.reduce((s, b) => s + b.valor, 0);
  return h('section', { class: 'tarjeta', id: 'grafica-ventas', 'aria-labelledby': 't-semana' },
    h('div', { class: 'titulo-con-total' },
      h('h2', { id: 't-semana', class: 'titulo-icono' }, icono('grafica'), 'Ventas de los últimos 7 días'),
      h('span', { class: 'suave' }, 'Total ', h('strong', { class: 'monto', dataset: { dato: 'total_7_dias' } }, dinero(total)))),
    graficaBarras(barras, { titulo: 'Ventas por día en lempiras, de hace 6 días hasta hoy' }));
}

// "1 vendido", "13 vendidos"; con decimales (kilos, libras) "8.5 unidades".
function vendidos(n) {
  if (!Number.isInteger(n)) return `${cantidad(n)} unidades`;
  return n === 1 ? '1 vendido' : `${cantidad(n)} vendidos`;
}

// Lo más vendido de los últimos 7 días (hoy - 6 a hoy, con la fecha del servidor). Núcleo 0.16.0: lo suma el
// servidor (mas_vendido), ya restadas las devoluciones y solo de sus sucursales si el usuario es limitado. Núcleo
// anterior: se suman aquí las últimas líneas de venta (sin restar devoluciones).
async function leerMasVendido(e, hoy) {
  // Fotos encendidas: la lista de productos (en memoria un rato) da la miniatura de cada uno.
  const fotos = fotosActivas() ? productos().then(porProducto).catch(() => new Map()) : Promise.resolve(new Map());
  const mv = await rpcSiExiste('mas_vendido', { p_empresa_id: e, p_desde: sumarDias(hoy, -6), p_hasta: hoy, p_limite: 5 });
  if (mv) return { servidor: true, filas: mv.filas || [], fotos: await fotos };
  return { servidor: false, fotos: await fotos, lineas: await leer('v_venta_linea', { empresa_id: e, estado: 'emitida', fecha_contable: { gte: sumarDias(hoy, -7) } },
    { orden: 'fecha_contable.desc', limite: LIMITE_LINEAS }) };
}

function masVendido(dato, hoy) {
  let top;
  if (dato.servidor) {
    top = dato.filas.map((x) => ({ id: x.producto_id, nombre: x.nombre, codigo: x.codigo, servicio: x.tipo === 'servicio',
      cantidad: Number(x.cantidad_neta) || 0, total: Number(x.total_neto_centavos) || 0 })).filter((x) => x.total > 0 || x.cantidad > 0);
  } else {
    const desde = sumarDias(hoy, -6);
    const por = new Map();
    for (const l of dato.lineas) {
      if (!l.fecha_contable || l.fecha_contable < desde) continue;
      const x = por.get(l.producto_id) || { id: l.producto_id, nombre: l.descripcion, codigo: l.codigo, servicio: l.es_servicio || l.tipo === 'servicio', cantidad: 0, total: 0 };
      x.cantidad += Number(l.cantidad) || 0;
      x.total += Number(l.total_centavos) || 0;
      por.set(l.producto_id, x);
    }
    top = [...por.values()].sort((a, b) => b.total - a.total).slice(0, 5);
  }
  const tarjeta = h('section', { class: 'tarjeta', id: 'mas-vendido', 'aria-labelledby': 't-top' },
    h('h2', { id: 't-top', class: 'titulo-icono' }, icono('estrella'), 'Lo más vendido esta semana'));
  if (!top.length) {
    tarjeta.append(estadoVacio({ icono: 'etiqueta', texto: 'Todavía no hay ventas esta semana.' }));
    return tarjeta;
  }
  tarjeta.append(h('div', { class: 'lista-filas' }, top.map((x) => filaIcono({
    // Miniatura de la foto (app 0.11.0) si las fotos están encendidas y el producto tiene; si no, el ícono.
    burbuja: miniatura((dato.fotos && dato.fotos.get(x.id)) || null, { icono: x.servicio ? 'servicio' : 'etiqueta', props: { dataset: { productoId: x.id } } }),
    titulo: x.nombre, detalle: x.codigo,
    derecha: [h('span', { class: 'monto' }, dinero(x.total)), h('span', { class: 'suave' }, vendidos(Math.round(x.cantidad * 10000) / 10000))],
    props: { dataset: { productoTop: x.id } },
  }))));
  tarjeta.append(dato.servidor
    ? h('p', { class: 'ayuda', dataset: { info: 'con-devoluciones' } }, 'Ventas de los últimos 7 días, ya restadas las devoluciones.')
    : h('p', { class: 'ayuda', dataset: { info: 'sin-devoluciones' } }, 'Ventas de los últimos 7 días, sin restar devoluciones.',
      dato.lineas.length >= LIMITE_LINEAS ? ` Se cuentan las últimas ${LIMITE_LINEAS.toLocaleString('en-US')} líneas de venta.` : ''));
  return tarjeta;
}

// "Primeros pasos": el estado sale de los datos (nada se guarda). Solo los pasos cuya pantalla
// puede abrir; desaparece cuando todo está hecho.
function primerosPasos(menu, arranque, marca, turnos, turno) {
  const paso = (codigo) => ((arranque.pasos || []).find((p) => p.paso === codigo) || {}).estado === 'hecho';
  const m = (marca && marca.marca) || {};
  const pasos = [
    { id: 'marca', texto: 'Poner mi logo y colores', hecho: Boolean(m.logo || m.color_principal || m.color_acento), ruta: 'ajustes/negocio' },
    { id: 'caja', texto: 'Abrir mi caja', hecho: Boolean(turno) || (turnos || []).length > 0, ruta: 'caja/turno' },
    { id: 'productos', texto: 'Agregar mis productos', hecho: paso('productos'), ruta: 'inventario/productos' },
    { id: 'venta', texto: 'Hacer mi primera venta', hecho: paso('primera_venta'), ruta: 'vender/nueva' },
    { id: 'empleado', texto: 'Crear a mi empleado', hecho: paso('usuarios'), ruta: 'ajustes/usuarios' },
  ].filter((p) => hayEnMenu(menu, ...p.ruta.split('/')));
  const hechos = pasos.filter((p) => p.hecho).length;
  if (!pasos.length || hechos === pasos.length) return null;
  const relleno = h('div', { class: 'progreso-relleno' });
  relleno.style.width = `${Math.round((hechos / pasos.length) * 100)}%`;
  let primero = true;
  return h('section', { class: 'tarjeta primeros-pasos', id: 'primeros-pasos', 'aria-labelledby': 't-pasos' },
    h('div', { class: 'titulo-con-total' },
      h('h2', { id: 't-pasos', class: 'titulo-icono' }, icono('bandera'), 'Primeros pasos'),
      chip(`${hechos} de ${pasos.length}`, 'dorado', { dataset: { dato: 'pasos-hechos' } })),
    h('div', { class: 'progreso', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': String(pasos.length), 'aria-valuenow': String(hechos),
      'aria-label': 'Primeros pasos hechos' }, relleno),
    pasos.map((p) => {
      const principal = !p.hecho && primero;
      if (!p.hecho) primero = false;
      return h('div', { class: 'paso' + (p.hecho ? ' paso-hecho' : ''), dataset: { paso: p.id, hecho: String(p.hecho) } },
        h('span', { class: 'paso-marca' }, p.hecho ? icono('check') : null),
        h('span', { class: 'paso-texto' }, p.texto, p.hecho ? h('span', { class: 'solo-lector' }, ' (hecho)') : null),
        p.hecho ? null : h('a', { class: 'boton' + (principal ? ' boton-principal' : ''), href: `#/${p.ruta}`, 'aria-label': `Hacerlo: ${p.texto}` }, 'Hacerlo'));
    }),
    h('p', { class: 'ayuda' }, 'Esta lista se va sola cuando termine.'));
}

async function tarjetaPendientes(alertas, aprob, ctx) {
  const tarjeta = h('section', { class: 'tarjeta', id: 'inicio-pendientes', 'aria-labelledby': 't-pend-inicio' },
    h('h2', { id: 't-pend-inicio', class: 'titulo-icono' }, icono('pendientes'), 'Pendientes'));
  if (aprob && aprob.err) tarjeta.append(await cajaError(aprob.err));
  if (alertas.err) tarjeta.append(await cajaError(alertas.err));
  const solicitudes = aprob && aprob.ok ? aprob.ok : [];
  const lista = alertas.ok || [];
  if (!solicitudes.length && !lista.length) {
    if (!alertas.err && !(aprob && aprob.err)) tarjeta.append(estadoVacio({ icono: 'check_circulo', color: 'verde', texto: 'Todo en orden: no hay pendientes.' }));
    return tarjeta;
  }
  // Al aprobar cambian el dinero y las cifras: se vuelve a pintar todo Inicio.
  const recargar = () => { if (ctx.sigueVigente()) window.dispatchEvent(new HashChangeEvent('hashchange')); };
  if (solicitudes.length) tarjeta.append(listaAprobaciones(solicitudes.slice(0, 5), recargar));
  if (lista.length) tarjeta.append(h('div', { class: 'lista-filas' }, lista.slice(0, 3).map(tarjetaAlerta)));
  const total = solicitudes.length + lista.length;
  if (total > Math.min(solicitudes.length, 5) + Math.min(lista.length, 3)) {
    tarjeta.append(h('a', { class: 'boton boton-ancho', href: '#/inicio/pendientes' }, `Ver los ${total} pendientes`));
  }
  return tarjeta;
}

function atajos(menu) {
  const filas = [];
  for (const p of menu.filter((x) => ['vender', 'clientes', 'inventario', 'caja'].includes(x.id))) {
    for (const s of p.subs.slice(0, 2)) {
      filas.push(h('a', { class: 'fila-icono', href: `#/${p.id}/${s.id}` }, burbuja(s.icono, 'azul'),
        h('div', { class: 'fila-icono-texto' }, h('div', { class: 'fila-icono-titulo' }, s.titulo), h('div', { class: 'fila-icono-detalle' }, p.titulo)),
        icono('flecha')));
    }
  }
  if (!filas.length) return null;
  return h('section', { class: 'tarjeta', 'aria-labelledby': 't-atajos' },
    h('h2', { id: 't-atajos', class: 'titulo-icono' }, icono('estrella'), '¿Qué quiere hacer?'), h('div', { class: 'lista-filas' }, filas));
}

// ---------------- Pantalla ----------------
export async function mostrar(vista, ctx) {
  const perfil = perfilActual();
  const e = empresaId();
  const menu = ctx.menu || [];
  const verVentas = tieneModulo('ventas') && puede('ventas.ver');
  const verDinero = tieneModulo('dinero') && puede('dinero.ver');
  const verCxp = tieneModulo('compras') && puede('compras.ver');
  const verTurno = hayEnMenu(menu, 'caja', 'turno');
  const esJefe = ['dueno', 'admin'].includes(perfil.rol.codigo) && puede('arranque.gestionar');
  // Se pide con un día de margen (por si el reloj de la máquina no cuadra con el servidor);
  // después se filtra con la fecha del servidor.
  const desdeMargen = sumarDias(hoyDeLaMaquina(), -8);
  const hoyMargen = sumarDias(hoyDeLaMaquina(), -1);

  const [resumen, donde, alertas, aprob, turno, dias, cxp, arranque, marca, turnos] = await Promise.all([
    parte(rpc('resumen_hoy', { p_empresa_id: e })),
    verDinero ? parte(rpc('donde_esta_mi_dinero', { p_empresa_id: e })) : null,
    parte(leerAlertas(puede('aprobaciones.ver'))),
    puede('aprobaciones.ver') ? parte(pendientes()) : null,
    verTurno ? parte(rpc('mi_turno', { p_empresa_id: e }).then((r) => (r && r.turno) || null)) : null,
    verVentas ? parte(leer('v_ventas_por_dia', { empresa_id: e, fecha: { gte: desdeMargen } }, { orden: 'fecha.desc', limite: 20 })) : null,
    // Próximo pago: solo lo que vence de hoy en adelante, el más cercano primero.
    verCxp ? parte(leer('v_cxp_documento', { empresa_id: e, fecha_vencimiento: { gte: hoyMargen } }, { orden: 'fecha_vencimiento.asc', limite: 20 })) : null,
    esJefe ? parte(rpc('estado_arranque', { p_empresa_id: e })) : null,
    esJefe ? parte(rpc('marca_empresa', { p_empresa_id: e })) : null,
    esJefe && tieneModulo('dinero') ? parte(leer('v_turno_caja', { empresa_id: e }, { limite: 1 })) : null,
  ]);
  if (!ctx.sigueVigente()) return;
  const miTurno = turno && turno.ok ? turno.ok : null;
  // La fecha de hoy la manda el servidor en cada carga (y se refresca en el perfil).
  const hoy = (resumen.ok && resumen.ok.fecha) || perfil.empresa.hoy;
  if (resumen.ok && resumen.ok.fecha) perfil.empresa.hoy = resumen.ok.fecha;
  // Lo más vendido necesita la fecha del servidor (de hoy - 6 a hoy).
  const lineas = verVentas ? await parte(leerMasVendido(e, hoy)) : null;
  if (!ctx.sigueVigente()) return;

  // Saludo, fecha y estado de la caja del usuario
  const nombre = (perfil.usuario.nombre || '').split(' ')[0];
  const partes = [mayuscula(fechaLarga(hoy).replace(',', ''))];
  if (miTurno) partes.push(`${miTurno.caja || 'Su caja'} abierta desde las ${horaCorta(miTurno.abierto_en)}`);
  else if (turno && turno.ok === null) partes.push('Su caja está cerrada');
  // Saludo y, a su lado (computadora), las subpestañas de Inicio, como en el dibujo aprobado.
  vista.append(cabezaPantalla(ctx, h('div', { class: 'saludo' },
    h('h1', {}, `${saludoSegunHora()}${nombre ? `, ${nombre}` : ''}`),
    h('p', { dataset: { info: 'fecha-caja' } }, partes.join(' · ')))));

  const botones = acciones(menu, miTurno);
  if (botones) vista.append(botones);

  if (resumen.err) vista.append(await cajaError(resumen.err));
  const r = resumen.ok || {};
  // Restringido: la gráfica es de toda la empresa y no se muestra; lo más vendido solo si lo sumó el servidor (0.16.0: sus sucursales).
  const sucursal = Boolean(r.solo_mis_sucursales);

  const izq = h('div', { class: 'inicio-izq' });
  const der = h('div', { class: 'inicio-der' });
  const t = cifras(r, donde && donde.ok, cxp && cxp.ok, menu, hoy);
  if (donde && donde.err && !sucursal) izq.append(await cajaError(donde.err));
  if (t.length) izq.append(h('div', { class: 'cifras-dos' }, t));
  if (r.frase) izq.append(h('p', { class: 'tarjeta frase', dataset: { dato: 'frase' } }, r.frase));
  if (dias && dias.ok && !sucursal) izq.append(graficaSemana(dias.ok, hoy));
  if (lineas && lineas.ok && (!sucursal || lineas.ok.servidor)) izq.append(masVendido(lineas.ok, hoy));
  if (!t.length) { const a = atajos(menu); if (a) izq.append(a); }

  if (arranque && arranque.ok && marca && marca.ok) {
    const pp = primerosPasos(menu, arranque.ok, marca.ok, turnos && turnos.ok, miTurno);
    if (pp) der.append(pp);
  }
  der.append(await tarjetaPendientes(alertas, aprob, ctx));
  if (!alertas.err && (!aprob || !aprob.err)) {
    window.dispatchEvent(new CustomEvent('pendientes-conteo', { detail: alertas.ok.length + (aprob ? aprob.ok.length : 0) }));
  }
  vista.append(h('div', { class: 'inicio-columnas' }, izq.children.length ? izq : null, der));
}
