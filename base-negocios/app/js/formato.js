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
