// Cuenta de una venta SIN INTERNET, con la foto del catálogo que bajó el equipo (núcleo 0.20.0, G5).
// Es la MISMA regla que interno.calcular_venta del servidor (solo lo que se puede sin internet: precio normal o
// mayorista, una promoción por línea; sin descuentos manuales ni de factura). El servidor la vuelve a calcular al
// subir: si no da lo mismo, la venta queda "por resolver". Las pruebas espejo (app-pruebas/probar_espejo.mjs) la
// comparan con calcular_venta_previa del servidor en 200 casos.
// Todo en centavos ENTEROS (BigInt para no perder un centavo) y redondeo "mitad hacia arriba" como PostgreSQL.
// No importa nada: lo usan vender.js, sin_internet.js y las pruebas en Node.

const B = (x) => BigInt(x);
// round(a / b) con mitades lejos del cero (como round() de numeric en PostgreSQL); b > 0.
function divRedondeo(a, b) {
  const neg = a < 0n;
  const n = neg ? -a : a;
  const q = (2n * n + b) / (2n * b);
  return neg ? -q : q;
}
// Cantidad (hasta 4 decimales) en diezmilésimas exactas: "2.5" -> 25000n.
function diezmil(q) {
  const t = String(q).trim();
  if (!/^\d+(\.\d{1,4})?$/.test(t)) throw errorCalculo('LINEA_INVALIDA', `La cantidad "${t}" no es válida (hasta 4 decimales).`);
  const [e, d = ''] = t.split('.');
  return B(e) * 10000n + B((d + '0000').slice(0, 4));
}
// Porcentaje (hasta 3 decimales) en milésimas: 15 -> 15000n.
function milPct(p) {
  const t = Number(p || 0).toFixed(3);
  const [e, d] = t.split('.');
  return B(e) * 1000n + B(d);
}
// round(cantidad x precio)
const brutoDe = (q4, precio) => divRedondeo(q4 * B(precio), 10000n);

// public.precio_con_tasa(precio, incluye, porcentaje, 1) sobre un total ya redondeado.
export function precioConTasa(total, incluye, porcentaje) {
  const t = B(total);
  const pm = milPct(porcentaje);              // tasa = pm / 100000
  if (incluye) {
    const sin = divRedondeo(t * 100000n, 100000n + pm);
    return { sin: Number(sin), isv: Number(t - sin), con: Number(t) };
  }
  const isv = divRedondeo(t * pm, 100000n);
  return { sin: Number(t), isv: Number(isv), con: Number(t + isv) };
}

function errorCalculo(clave, texto) {
  const e = new Error(`${clave}: ${texto}`);
  e.clave = clave;
  return e;
}

// Promociones de un producto en una fecha (interno.promociones_de con la foto), de la que más descuenta a la que menos.
export function promocionesDe(foto, prodId, precio, q4, fecha) {
  const p = foto.productos[prodId];
  const lista = [];
  for (const id of (p && p.promos) || []) {
    const pr = foto.promociones[id];
    if (!pr || fecha < pr.fecha_inicio || fecha > pr.fecha_fin) continue;
    const bruto = brutoDe(q4, precio);
    const d = pr.tipo === 'porcentaje'
      ? divRedondeo(bruto * B(Math.round(Number(pr.porcentaje) * 100)), 10000n)
      : (() => { const m = brutoDe(q4, pr.monto_centavos); return bruto < m ? bruto : m; })();
    lista.push({ promocion_id: id, nombre: pr.nombre, tipo: pr.tipo, porcentaje: pr.porcentaje, monto_centavos: pr.monto_centavos,
      descuento_centavos: Number(d), creado: pr.creado_en });
  }
  lista.sort((a, b) => (b.descuento_centavos - a.descuento_centavos) || (a.creado < b.creado ? -1 : a.creado > b.creado ? 1 : 0)
    || (a.promocion_id < b.promocion_id ? -1 : a.promocion_id > b.promocion_id ? 1 : 0));
  return lista.map(({ creado, ...x }) => x);
}

// lineas: [{producto_id, cantidad, precio_tipo?, promocion_id?}]; cliente_id opcional; fecha 'AAAA-MM-DD' (zona de la empresa).
// sugerir = true: como calcular_venta_previa (si aplican varias promociones y nadie eligió, usa la que más descuenta,
// salvo que gane el mayorista). Devuelve lo mismo que el servidor (lineas con sus montos y los totales) o lanza el error.
export function calcularVentaLocal(foto, { lineas, cliente_id = null, fecha, sugerir = false }) {
  if (!foto || !foto.productos) throw errorCalculo('SIN_CATALOGO', 'Este equipo no tiene los precios guardados.');
  if (!Array.isArray(lineas) || !lineas.length) throw errorCalculo('DATO_INVALIDO', 'La venta necesita al menos una línea.');
  const cliMay = Boolean(cliente_id) && (foto.mayoristas || []).includes(cliente_id);
  const out = [];
  let tSub = 0, tDpro = 0, tBase = 0, tImp = 0, tTot = 0, tGrav = 0, tExe = 0, tExo = 0, tSubCon = 0;
  const desg = new Map();
  lineas.forEach((l, i) => {
    const n = i + 1;
    const p = foto.productos[l.producto_id];
    if (!p) throw errorCalculo('PRODUCTO_INVALIDO', `El producto de la línea ${n} no está en los precios guardados en el equipo.`);
    const imp = foto.impuestos[p.tipo_impuesto];
    if (!imp) throw errorCalculo('IMPUESTO_INVALIDO', `El impuesto "${p.tipo_impuesto}" no está en los precios guardados.`);
    const pct = Number(imp.porcentaje);
    const q4 = diezmil(l.cantidad);
    if (q4 <= 0n) throw errorCalculo('LINEA_INVALIDA', `La cantidad de la línea ${n} debe ser mayor que cero.`);
    if (!p.permite_fracciones && q4 % 10000n !== 0n) throw errorCalculo('LINEA_INVALIDA', `"${p.nombre}" se vende en unidades enteras.`);
    let ptip = l.precio_tipo || null;
    let promoId = l.promocion_id || null;
    // Mayorista (interno.mayorista_de con la foto).
    const mPrecio = p.precio_mayorista_centavos;
    const mCant = p.cantidad_mayorista;
    const masBarato = mPrecio !== null && mPrecio !== undefined
      && precioConTasa(mPrecio, p.mayorista_incluye, pct).con < precioConTasa(p.precio_venta_centavos, p.precio_incluye_isv, pct).con;
    const por = cliMay ? 'cliente' : (mCant !== null && mCant !== undefined && q4 >= diezmil(Number(mCant).toFixed(4).replace(/\.?0+$/, '') || '0')) ? 'cantidad' : null;
    const aplica = Boolean(masBarato && por);
    // Sugerencia de la previa: varias promociones y nadie eligió.
    if (sugerir && !promoId && ptip !== 'mayorista') {
      const prs = promocionesDe(foto, l.producto_id, p.precio_venta_centavos, q4, fecha);
      if (prs.length > 1) {
        const gana = aplica && ptip !== 'normal'
          && precioConTasa(brutoDe(q4, mPrecio), p.mayorista_incluye, pct).con
             <= precioConTasa(Number(brutoDe(q4, p.precio_venta_centavos)) - prs[0].descuento_centavos, p.precio_incluye_isv, pct).con;
        if (!gana) promoId = prs[0].promocion_id;
      }
    }
    let usaMay = false;
    if (ptip === 'mayorista') {
      if (!aplica) throw errorCalculo('PRECIO_MAYORISTA_NO_APLICA', `La línea ${n} ("${p.nombre}") no lleva precio mayorista.`);
      if (promoId) throw errorCalculo('DESCUENTO_DOBLE', `La línea ${n} ("${p.nombre}") va con precio mayorista y no lleva además una promoción.`);
      usaMay = true;
    } else if (ptip === null && aplica && !promoId) {
      const prs = promocionesDe(foto, l.producto_id, p.precio_venta_centavos, q4, fecha);
      usaMay = true;
      if (prs.length) {
        const conMay = precioConTasa(brutoDe(q4, mPrecio), p.mayorista_incluye, pct).con;
        const conPro = precioConTasa(Number(brutoDe(q4, p.precio_venta_centavos)) - prs[0].descuento_centavos, p.precio_incluye_isv, pct).con;
        usaMay = conMay <= conPro;
      }
    }
    const precio = usaMay ? mPrecio : p.precio_venta_centavos;
    const incluye = usaMay ? p.mayorista_incluye : p.precio_incluye_isv;
    const bruto = Number(brutoDe(q4, precio));
    const prs = usaMay ? [] : promocionesDe(foto, l.producto_id, precio, q4, fecha);
    let dp = 0;
    if (promoId) {
      const x = prs.find((y) => y.promocion_id === promoId);
      if (!x) throw errorCalculo('PROMOCION_INVALIDA', `La promoción elegida en la línea ${n} no aplica a "${p.nombre}" en la fecha de la venta.`);
      dp = x.descuento_centavos;
    } else if (prs.length === 1) {
      promoId = prs[0].promocion_id; dp = prs[0].descuento_centavos;
    } else if (prs.length > 1) {
      throw errorCalculo('PROMOCION_A_ELEGIR', `La línea ${n} ("${p.nombre}") tiene ${prs.length} promociones; elija una.`);
    }
    const s0 = precioConTasa(bruto, incluye, pct).sin;
    const s1 = precioConTasa(bruto - dp, incluye, pct).sin;
    const r3 = precioConTasa(bruto - dp, incluye, pct);
    const conBruto = precioConTasa(bruto, incluye, pct).con;
    out.push({ linea: n, producto_id: l.producto_id, descripcion: p.nombre, cantidad: Number(l.cantidad),
      precio_unitario_centavos: precio, precio_incluye_isv: incluye, tipo_impuesto: p.tipo_impuesto, impuesto_porcentaje: pct,
      impuesto_clase: imp.clase, es_servicio: p.tipo === 'servicio', promocion_id: promoId,
      bruto_centavos: bruto, descuento_promocion_precio_centavos: dp, neto_centavos: bruto - dp,
      subtotal_centavos: s0, descuento_promocion_centavos: s0 - s1, descuento_centavos: s0 - r3.sin,
      base_centavos: r3.sin, impuesto_centavos: r3.isv, total_centavos: r3.con,
      precio_tipo: usaMay ? 'mayorista' : 'normal', precio_normal_centavos: usaMay ? p.precio_venta_centavos : null,
      precio_mayorista_disponible: aplica, promociones: prs,
      bruto_con_isv_centavos: conBruto, descuento_con_isv_centavos: conBruto - r3.con });
    tSub += s0; tDpro += s0 - s1; tBase += r3.sin; tImp += r3.isv; tTot += r3.con; tSubCon += conBruto;
    if (imp.clase === 'gravado') tGrav += r3.sin; else if (imp.clase === 'exonerado') tExo += r3.sin; else tExe += r3.sin;
    const k = `${p.tipo_impuesto}|${pct}|${imp.clase}`;
    const d = desg.get(k) || { codigo: p.tipo_impuesto, nombre: imp.nombre, porcentaje: pct, clase: imp.clase, base_centavos: 0, impuesto_centavos: 0 };
    d.base_centavos += r3.sin; d.impuesto_centavos += r3.isv;
    desg.set(k, d);
  });
  return { lineas: out, subtotal_centavos: tSub, descuento_centavos: tSub - tBase, descuento_promocion_centavos: tDpro,
    descuento_manual_centavos: tSub - tBase - tDpro, gravado_centavos: tGrav, exento_centavos: tExe, exonerado_centavos: tExo,
    impuesto_centavos: tImp, total_centavos: tTot, desglose_impuestos: [...desg.values()],
    subtotal_con_isv_centavos: tSubCon, descuento_con_isv_centavos: tSubCon - tTot, cliente_mayorista: cliMay, fecha };
}

// Total en letras como el servidor (interno.monto_en_letras): "QUINCE LEMPIRAS CON 00/100".
const U = ['', 'UNO', 'DOS', 'TRES', 'CUATRO', 'CINCO', 'SEIS', 'SIETE', 'OCHO', 'NUEVE', 'DIEZ', 'ONCE', 'DOCE', 'TRECE', 'CATORCE',
  'QUINCE', 'DIECISÉIS', 'DIECISIETE', 'DIECIOCHO', 'DIECINUEVE', 'VEINTE', 'VEINTIUNO', 'VEINTIDÓS', 'VEINTITRÉS',
  'VEINTICUATRO', 'VEINTICINCO', 'VEINTISÉIS', 'VEINTISIETE', 'VEINTIOCHO', 'VEINTINUEVE'];
const D = ['', '', '', 'TREINTA', 'CUARENTA', 'CINCUENTA', 'SESENTA', 'SETENTA', 'OCHENTA', 'NOVENTA'];
const C = ['', 'CIENTO', 'DOSCIENTOS', 'TRESCIENTOS', 'CUATROCIENTOS', 'QUINIENTOS', 'SEISCIENTOS', 'SETECIENTOS', 'OCHOCIENTOS', 'NOVECIENTOS'];
function centenas(n) {
  if (n === 0) return '';
  if (n === 100) return 'CIEN';
  const c = Math.floor(n / 100), r = n % 100;
  let t = c ? C[c] : '';
  if (r) t += (t ? ' ' : '') + (r < 30 ? U[r] : D[Math.floor(r / 10)] + (r % 10 ? ' Y ' + U[r % 10] : ''));
  return t;
}
const apocope = (t) => (/VEINTIUNO$/.test(t) ? t.replace(/VEINTIUNO$/, 'VEINTIÚN') : /(^| )UNO$/.test(t) ? t.replace(/UNO$/, 'UN') : t);
export function montoEnLetras(centavos, moneda = 'HNL') {
  const a = Math.abs(Number(centavos));
  const ent = Math.floor(a / 100), cen = a % 100;
  const mm = Math.floor(ent / 1e9), m = Math.floor(ent / 1e6) % 1000, k = Math.floor(ent / 1000) % 1000, u = ent % 1000;
  const mill = mm * 1000 + m;
  let t = '';
  if (mill > 0) {
    t = mill === 1 ? 'UN MILLÓN'
      : `${((mm > 0 ? (mm === 1 ? 'MIL' : apocope(centenas(mm)) + ' MIL') : '') + ' ' + apocope(centenas(m))).trim()} MILLONES`;
  }
  if (k > 0) t += ' ' + (k === 1 ? 'MIL' : apocope(centenas(k)) + ' MIL');
  if (u > 0) t += ' ' + apocope(centenas(u));
  t = t.trim() || 'CERO';
  if (k === 0 && u === 0 && mill > 0) t += ' DE';
  const nombres = { HNL: ['LEMPIRA', 'LEMPIRAS'], USD: ['DÓLAR', 'DÓLARES'], GTQ: ['QUETZAL', 'QUETZALES'], NIO: ['CÓRDOBA', 'CÓRDOBAS'],
    CRC: ['COLÓN', 'COLONES'], MXN: ['PESO', 'PESOS'] }[moneda] || [moneda, moneda];
  return `${t} ${ent === 1 ? nombres[0] : nombres[1]} CON ${String(cen).padStart(2, '0')}/100`;
}

// Fecha de hoy en la zona de la empresa ('AAAA-MM-DD') para una hora dada (ms).
export function fechaLocal(ms, zona = 'America/Tegucigalpa') {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: zona, year: 'numeric', month: '2-digit', day: '2-digit' });
  return f.format(new Date(ms));
}
