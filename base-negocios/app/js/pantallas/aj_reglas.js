// Ajustes · Reglas y topes (solo el dueño: empresa.configurar). Topes de descuento por puesto
// (configurar_tope_descuento), tope de gasto sin aprobación (configurar_tope_rol), tope de
// crédito, política de crédito, vendedor que cobra, turnos de caja obligatorios y doble
// aprobación (configurar_empresa). Todo con motivo y en la bitácora.
import { rpc, leer } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, aCentavos, paraCampo, aPorcentaje, comaInvalida, MENSAJE_COMA } from '../formato.js';
import { h, aviso, errorSimple, campo, pedirMotivo, titulo, tabla } from '../ui.js';

const PUESTOS = { admin: 'Administrador', cajero: 'Cajero', vendedor: 'Vendedor' };
const DEFECTO = { admin: [10, 20], cajero: [5, 0], vendedor: [5, 0] }; // núcleo 0.8.0

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const [[emp], topes] = await Promise.all([leer('empresa', { id: E }), leer('tope_rol', { empresa_id: E }).catch(() => [])]);
  if (!ctx.sigueVigente()) return;
  const recargar = async () => { vista.replaceChildren(); await mostrar(vista, ctx); };
  const tope = (rol, tipo) => topes.find((t) => t.rol === rol && t.tipo === tipo);

  // 1) Reglas del negocio
  const credito = h('input', { id: 'regla-tope-credito', type: 'text', inputmode: 'decimal', value: paraCampo(emp.tope_credito_centavos || 0) });
  const politica = h('select', { id: 'regla-credito-politica' }, h('option', { value: 'segun_limite' }, 'Según el límite de cada cliente'),
    h('option', { value: 'siempre_aprobacion' }, 'Toda venta al crédito pide aprobación'));
  politica.value = emp.credito_politica || 'segun_limite';
  const chk = (id, v) => h('input', { type: 'checkbox', id, checked: !!v });
  const vendedorCobra = chk('regla-vendedor-cobra', emp.vendedor_cobra);
  const turnos = chk('regla-turnos', emp.turnos_obligatorios);
  const doble = chk('regla-doble', emp.doble_aprobacion);
  const zona1 = h('div', { 'aria-live': 'assertive' });
  const f1 = h('form', { class: 'formulario', novalidate: true },
    campo('Tope de crédito que puede dar el administrador a un cliente (L)', credito),
    campo('Ventas al crédito', politica),
    h('label', { class: 'opcion-check' }, vendedorCobra, ' El vendedor también cobra (si no, cobra el cajero)'),
    h('label', { class: 'opcion-check' }, turnos, ' Turnos de caja obligatorios (sin turno abierto no entra efectivo)'),
    h('label', { class: 'opcion-check' }, doble, ' Doble aprobación (dos personas aprueban lo grande)'),
    zona1, h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'reglas-guardar' }, 'Guardar reglas'));
  f1.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zona1.replaceChildren();
    const tc = aCentavos(credito.value);
    if (tc === null || tc < 0) { zona1.append(errorSimple('Escriba el tope de crédito (0 o más).')); return; }
    const nuevos = { tope_credito_centavos: tc, credito_politica: politica.value, vendedor_cobra: vendedorCobra.checked,
      turnos_obligatorios: turnos.checked, doble_aprobacion: doble.checked };
    const cambios = Object.fromEntries(Object.entries(nuevos).filter(([k, v]) => v !== emp[k]));
    if (!Object.keys(cambios).length) { zona1.append(errorSimple('No cambió nada.')); return; }
    const ok = await pedirMotivo({ titulo: 'Guardar reglas', textoBoton: 'Guardar', explicacion: `${Object.keys(cambios).length} cambio(s). Valen desde ahora.`,
      accion: (motivo) => rpc('configurar_empresa', { p_empresa_id: E, p_datos: cambios, p_motivo: motivo }) });
    if (ok) { aviso(`Reglas guardadas · ${Object.keys(cambios).length} cambio(s), valen desde ahora`); recargar(); }
  });

  // 2) Topes por puesto
  const filas = Object.keys(PUESTOS).map((rol) => {
    const d = tope(rol, 'descuento');
    const g = tope(rol, 'gasto');
    return { rol, d, g,
      sin: h('input', { type: 'text', inputmode: 'decimal', 'aria-label': `${PUESTOS[rol]}: descuento sin aprobación (%)`, dataset: { tope: rol },
        value: d && d.sin_aprobacion_porcentaje !== null ? String(Number(d.sin_aprobacion_porcentaje)) : String(DEFECTO[rol][0]) }),
      aprueba: h('input', { type: 'text', inputmode: 'decimal', 'aria-label': `${PUESTOS[rol]}: aprueba descuentos hasta (%)`,
        value: d && d.aprueba_hasta_porcentaje !== null ? String(Number(d.aprueba_hasta_porcentaje)) : String(DEFECTO[rol][1]) }),
      gasto: h('input', { type: 'text', inputmode: 'decimal', 'aria-label': `${PUESTOS[rol]}: gasto sin aprobación (L)`,
        value: g ? paraCampo(g.sin_aprobacion_centavos) : '', placeholder: rol === 'admin' ? '5,000.00 (defecto)' : 'Por defecto' }) };
  });
  const zona2 = h('div', { 'aria-live': 'assertive' });
  const f2 = h('form', { class: 'formulario', novalidate: true },
    tabla({ columnas: [{ titulo: 'Puesto' }, { titulo: 'Descuento sin aprobación (%)' }, { titulo: 'Aprueba descuentos hasta (%)' }, { titulo: 'Gasto sin aprobación (L)' }],
      filas: filas.map((f) => [h('strong', {}, PUESTOS[f.rol]), f.sin, f.aprueba, f.gasto]) }),
    h('p', { class: 'ayuda' }, 'El dueño no tiene tope. Lo que pase el tope queda esperando aprobación.'),
    zona2, h('button', { type: 'submit', class: 'boton boton-principal boton-ancho', id: 'topes-guardar' }, 'Guardar topes'));
  f2.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zona2.replaceChildren();
    const llamadas = [];
    for (const f of filas) {
      const s = aPorcentaje(f.sin.value), a = aPorcentaje(f.aprueba.value);
      if (s === null || a === null) { zona2.append(errorSimple(comaInvalida(f.sin.value) || comaInvalida(f.aprueba.value) ? MENSAJE_COMA : `Revise los porcentajes de ${PUESTOS[f.rol]} (0 a 100).`)); return; }
      const antesS = f.d && f.d.sin_aprobacion_porcentaje !== null ? Number(f.d.sin_aprobacion_porcentaje) : DEFECTO[f.rol][0];
      const antesA = f.d && f.d.aprueba_hasta_porcentaje !== null ? Number(f.d.aprueba_hasta_porcentaje) : DEFECTO[f.rol][1];
      if (s !== antesS || a !== antesA) llamadas.push((m) => rpc('configurar_tope_descuento', { p_empresa_id: E, p_rol: f.rol, p_sin_aprobacion_porcentaje: s, p_aprueba_hasta_porcentaje: a, p_motivo: m }));
      if (f.gasto.value.trim()) {
        const gc = aCentavos(f.gasto.value);
        if (gc === null || gc < 0) { zona2.append(errorSimple(`Revise el tope de gasto de ${PUESTOS[f.rol]}.`)); return; }
        if (!f.g || gc !== f.g.sin_aprobacion_centavos) {
          llamadas.push((m) => rpc('configurar_tope_rol', { p_empresa_id: E, p_rol: f.rol, p_tipo: 'gasto', p_sin_aprobacion_centavos: gc,
            p_aprueba_hasta_centavos: f.g ? f.g.aprueba_hasta_centavos : gc, p_motivo: m }));
        }
      }
    }
    if (!llamadas.length) { zona2.append(errorSimple('No cambió nada.')); return; }
    const ok = await pedirMotivo({ titulo: 'Guardar topes', textoBoton: 'Guardar', explicacion: `${llamadas.length} cambio(s).`,
      accion: async (motivo) => { for (const c of llamadas) await c(motivo); } });
    if (ok) { aviso(`Topes guardados · ${llamadas.length} cambio(s)`); recargar(); }
  });

  vista.append(
    h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-reglas' }, titulo('h1', 'reglas', 'Reglas del negocio', { id: 't-reglas' }),
      h('p', { class: 'ayuda' }, `Tope de crédito actual: ${dinero(emp.tope_credito_centavos || 0)}.`), f1),
    h('section', { class: 'tarjeta', 'aria-labelledby': 't-topes' }, titulo('h2', 'usuarios', 'Topes por puesto', { id: 't-topes' }), f2));
}
