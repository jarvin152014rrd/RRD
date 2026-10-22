// Formatos para mostrar. El dinero llega del servidor en CENTAVOS enteros;
// aquí solo se convierte a texto, nunca se calcula.
const SIMBOLO = { HNL: 'L', USD: '$', GTQ: 'Q', NIO: 'C$', CRC: '₡' };
let moneda = 'HNL';
let zona = 'America/Tegucigalpa';

export function configurarFormato({ moneda: m, zona_horaria: z } = {}) {
  if (m) moneda = m;
  if (z) zona = z;
}

// 123456 -> "L 1,234.56"; -15000 -> "-L 150.00"; null -> "—"
export function dinero(centavos) {
  if (centavos === null || centavos === undefined || centavos === '') return '—';
  const n = Number(centavos);
  if (!Number.isFinite(n)) return '—';
  const abs = Math.abs(Math.round(n));
  const enteros = Math.floor(abs / 100).toLocaleString('en-US');
  const cent = String(abs % 100).padStart(2, '0');
  return `${n < 0 ? '-' : ''}${SIMBOLO[moneda] || moneda} ${enteros}.${cent}`;
}

// "2026-10-12" -> "12/10/2026"
export function fecha(iso) {
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : String(iso);
}

// "2026-10-12T15:04:00Z" -> "12/10/2026 09:04" (hora del negocio)
export function fechaHora(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString('es-HN', { timeZone: zona, day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false });
}

// "lunes, 12 de octubre"
export function fechaLarga(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || '');
  if (!m) return '';
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], 12));
  return d.toLocaleDateString('es-HN', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long' });
}

export function porcentaje(p) {
  if (p === null || p === undefined) return '';
  const n = Number(p);
  return `${n > 0 ? '+' : ''}${n.toLocaleString('en-US', { maximumFractionDigits: 1 })} %`;
}

// Lo que la persona escribe, sin "L" ni espacios. La coma SOLO vale como separador de miles en grupos de
// 3 ("1,500" o "1,234,567.89"); cualquier otra coma ("150,50", "2,5") se rechaza (null) porque no se sabe si
// era un decimal: el decimal va con punto. (Antes se borraban todas las comas y "150,50" quedaba 15050.)
const CON_MILES = /^\d{1,3}(,\d{3})+(\.\d*)?$/;
function limpiarNumero(texto) {
  const t = String(texto ?? '').trim().replace(/^L\s*/i, '');
  if (!t.includes(',')) return t;
  return CON_MILES.test(t) ? t.replace(/,/g, '') : null;
}
// ¿Tiene una coma que no es de miles? Para avisar "Use punto para los decimales".
export function comaInvalida(texto) {
  const t = String(texto ?? '').trim().replace(/^L\s*/i, '');
  return t.includes(',') && !CON_MILES.test(t);
}
export const MENSAJE_COMA = 'Use punto para los decimales, por ejemplo 150.50';

// Lo que la persona escribe -> centavos enteros (sin decimales flotantes).
// "1,234.5" -> 123450; "150,50", "" o texto raro -> null. Solo números positivos con hasta 2 decimales.
export function aCentavos(texto) {
  const t = limpiarNumero(texto);
  const m = t === null ? null : /^(\d{1,12})(?:\.(\d{0,2}))?$/.exec(t);
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] || '').padEnd(2, '0'));
}

// Costo por unidad (app 0.7.0): lempiras con hasta 4 decimales -> centavos con hasta 2 decimales
// (el núcleo guarda el costo unitario en centavos con decimales). "12.505" -> 1250.5. Se arma con
// texto (sin multiplicar flotantes) para que llegue exacto. Texto raro o 0 -> null.
export function aCosto(texto) {
  const t = limpiarNumero(texto);
  const m = t === null ? null : /^(\d{1,12})(?:\.(\d{0,4}))?$/.exec(t);
  if (!m) return null;
  const dec = (m[2] || '').padEnd(4, '0');
  const n = Number(`${Number(m[1]) * 100 + Number(dec.slice(0, 2))}.${dec.slice(2)}`);
  return n > 0 ? n : null;
}

// Cantidad (unidades, libras...): positiva con hasta 4 decimales. "2.5" -> 2.5; "2,5", texto raro o 0 -> null.
export function aCantidad(texto) {
  const t = limpiarNumero(String(texto ?? '').replace(/^L/i, 'x'));
  if (t === null || !/^\d{1,12}(?:\.\d{0,4})?$/.test(t)) return null;
  const n = Number(t);
  return n > 0 ? n : null;
}

// Número de 0 o más escrito a mano (mínimo de un producto, cantidad contada): hasta 4 decimales, la coma solo
// como separador de miles (app 0.8.0). "2.5" -> 2.5; "0" -> 0; "1,500" -> 1500; "2,5", "-1" o texto raro -> null.
export function aNumero(texto) {
  const t = limpiarNumero(texto);
  if (t === null || !/^\d{1,12}(?:\.\d{0,4})?$/.test(t)) return null;
  return Number(t);
}
// Porcentaje de 0 a 100 con hasta 4 decimales (tasa de un impuesto, topes de descuento). "15" -> 15;
// "12.5" -> 12.5; "12,5", "150" o texto raro -> null.
export function aPorcentaje(texto) {
  const n = aNumero(String(texto ?? '').trim().replace(/\s*%$/, ''));
  return n !== null && n <= 100 ? n : null;
}

// Fechas "AAAA-MM-DD" sin horas (sin problemas de zona): sumar días y días entre dos fechas.
export function sumarDias(iso, n) {
  const [a, m, d] = String(iso).split('-').map(Number);
  return new Date(Date.UTC(a, m - 1, d + n, 12)).toISOString().slice(0, 10);
}
export function diasEntre(desde, hasta) {
  const f = (x) => { const [a, m, d] = String(x).split('-').map(Number); return Date.UTC(a, m - 1, d); };
  return Math.round((f(hasta) - f(desde)) / 86400000);
}

// Centavos -> texto para un campo ("1234.50"), sin símbolo ni comas.
export function paraCampo(centavos) {
  if (centavos === null || centavos === undefined) return '';
  const n = Math.round(Number(centavos));
  return `${Math.floor(n / 100)}.${String(n % 100).padStart(2, '0')}`;
}

// 2.5 -> "2.5"; 10.0000 -> "10"
export function cantidad(n) {
  const x = Number(n);
  return Number.isFinite(x) ? x.toLocaleString('en-US', { maximumFractionDigits: 3 }) : '';
}

// Quita tildes y pasa a minúsculas (para buscar "galon" y encontrar "galón").
export function sinTildes(t) {
  return String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}
