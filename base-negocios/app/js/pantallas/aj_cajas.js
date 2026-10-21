// Ajustes · Cajas y bancos: crear y desactivar cuentas de dinero (crear_cuenta_dinero; del banco
// solo se guardan los 4 últimos números), saldo inicial o "empezar en cero" (solo el dueño:
// dinero.saldo_inicial) y política de saldo negativo (solo el dueño: configurar_saldo_negativo).
import { rpc, leer, escribir } from '../api.js';
import { empresaId, perfilActual, puede } from '../sesion.js';
import { dinero, aCentavos } from '../formato.js';
import { h, icono, aviso, errorSimple, campo, conBoton, pedirMotivo, confirmar, titulo, filaIcono, chipEstado, chip, monto, estadoVacio } from '../ui.js';
import { olvidarDatos } from '../datos.js';

const TIPOS = { efectivo_caja: 'Efectivo (caja)', banco: 'Banco', caja_chica: 'Caja chica', pos_por_liquidar: 'Tarjetas por liquidar',
  transferencia_por_confirmar: 'Transferencias por confirmar', transito: 'Dinero en tránsito' };
const POLITICAS = { no_permitir: 'No permitir saldo negativo', permitir_con_alerta: 'Permitir con alerta', sobregiro_hasta: 'Sobregiro hasta un monto' };

export async function mostrar(vista, ctx) {
  const E = empresaId();
  const [cuentas, cajas] = await Promise.all([leer('v_cuenta_dinero', { empresa_id: E }, { orden: 'nombre.asc' }),
    leer('caja', { empresa_id: E, activa: true }, { orden: 'punto_emision.asc' })]);
  if (!ctx.sigueVigente()) return;
  const dueno = puede('empresa.configurar');
  const recargar = async () => { olvidarDatos('cuentas'); vista.replaceChildren(); await mostrar(vista, ctx); };

  // Ícono por tipo (azul = información; dorado = dinero por confirmar). Saldo negativo en rojo.
  const ICONO = { efectivo_caja: 'caja', caja_chica: 'billetes', banco: 'banco', transito: 'deposito', pos_por_liquidar: 'reloj', transferencia_por_confirmar: 'reloj' };
  const filas = cuentas.map((c) => filaIcono({
    icono: ICONO[c.tipo] || 'dinero', color: !c.activa ? 'neutro' : c.saldo_centavos < 0 ? 'rojo' : ['transito', 'pos_por_liquidar', 'transferencia_por_confirmar'].includes(c.tipo) ? 'dorado' : 'azul',
    titulo: [h('strong', {}, c.nombre), !c.activa ? [' ', chipEstado('inactiva')] : null],
    detalle: [TIPOS[c.tipo] || c.tipo, c.banco, c.numero_enmascarado, c.caja ? 'Caja ' + c.caja : null,
      c.politica_saldo_negativo && c.politica_saldo_negativo !== 'no_permitir' ? POLITICAS[c.politica_saldo_negativo] : null].filter(Boolean).join(' · '),
    derecha: [monto(dinero(c.saldo_centavos), { negativo: c.saldo_centavos < 0 }), c.saldo_centavos < 0 ? chip('En negativo', 'rojo') : null],
    abajo: h('div', { class: 'botones' },
      dueno && c.activa && c.tipo !== 'transito' ? h('button', { type: 'button', class: 'boton', 'aria-label': `Saldo negativo de ${c.nombre}`, onclick: () => politica(c) }, 'Saldo negativo') : null,
      ['efectivo_caja', 'banco', 'caja_chica'].includes(c.tipo) ? h('button', { type: 'button', class: `boton ${c.activa ? 'boton-peligro' : ''}`, 'aria-label': `${c.activa ? 'Desactivar' : 'Activar'} ${c.nombre}`,
        onclick: () => activar(c) }, c.activa ? 'Desactivar' : 'Activar') : null),
    props: { dataset: { cuenta: c.cuenta_dinero_id } },
  }));

  async function activar(c) {
    const ok = await pedirMotivo({ titulo: c.activa ? `Desactivar ${c.nombre}` : `Activar ${c.nombre}`, peligro: c.activa,
      textoBoton: c.activa ? 'Desactivar' : 'Activar',
      explicacion: c.activa ? 'Solo se puede con saldo L 0.00, sin turno abierto ni depósitos en camino. No se borra nada.' : null,
      accion: (motivo) => rpc(c.activa ? 'desactivar_cuenta_dinero' : 'reactivar_cuenta_dinero', { p_empresa_id: E, p_cuenta_dinero_id: c.cuenta_dinero_id, p_motivo: motivo }) });
    if (ok) { aviso(c.activa ? `Cuenta desactivada · ${c.nombre}` : `Cuenta activada · ${c.nombre}`); recargar(); }
  }

  function politica(c) {
    const sel = h('select', { id: 'politica-sel' }, Object.entries(POLITICAS).map(([k, v]) => h('option', { value: k }, v)));
    sel.value = c.politica_saldo_negativo || 'no_permitir';
    const limite = h('input', { id: 'politica-limite', type: 'text', inputmode: 'decimal', value: c.sobregiro_limite_centavos ? (c.sobregiro_limite_centavos / 100).toFixed(2) : '' });
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Siguiente');
    const form = h('form', { class: 'formulario', novalidate: true }, campo('Si una salida deja la cuenta en negativo', sel),
      campo('Sobregiro máximo (L), solo para "Sobregiro hasta"', limite), zona, boton,
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      zona.replaceChildren();
      const lim = sel.value === 'sobregiro_hasta' ? aCentavos(limite.value) : null;
      if (sel.value === 'sobregiro_hasta' && !lim) { zona.append(errorSimple('Escriba el sobregiro máximo.')); return; }
      const ok = await pedirMotivo({ titulo: `Saldo negativo · ${c.nombre}`, textoBoton: 'Guardar', explicacion: POLITICAS[sel.value],
        accion: (motivo) => rpc('configurar_saldo_negativo', { p_empresa_id: E, p_cuenta_dinero_id: c.cuenta_dinero_id, p_politica: sel.value, p_limite_centavos: lim, p_motivo: motivo }) });
      if (ok) { aviso(`Guardado · ${c.nombre}: ${POLITICAS[sel.value].toLowerCase()}`); recargar(); }
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta' }, titulo('h1', 'reglas', `Saldo negativo · ${c.nombre}`), form));
  }

  function nueva() {
    const tipo = h('select', { id: 'cuenta-tipo' }, ['efectivo_caja', 'banco', 'caja_chica'].map((t) => h('option', { value: t }, TIPOS[t])));
    const nombre = h('input', { id: 'cuenta-nombre', type: 'text', maxlength: 80 });
    const banco = h('input', { id: 'cuenta-banco', type: 'text', maxlength: 80 });
    const numero = h('input', { id: 'cuenta-numero', type: 'text', inputmode: 'numeric', maxlength: 40, autocomplete: 'off' });
    const tipoCuenta = h('select', { id: 'cuenta-tipo-cuenta' }, h('option', { value: 'cheques' }, 'Cheques'), h('option', { value: 'ahorro' }, 'Ahorro'));
    const caja = h('select', { id: 'cuenta-caja' }, h('option', { value: '' }, 'Ninguna (caja general o caja fuerte)'),
      cajas.filter((x) => !cuentas.some((c) => c.caja_id === x.id && c.activa)).map((x) => h('option', { value: x.id }, `${x.nombre} (${x.punto_emision})`)));
    const fondo = h('input', { id: 'cuenta-fondo', type: 'text', inputmode: 'decimal' });
    const inicio = h('select', { id: 'cuenta-inicio' }, h('option', { value: 'cero' }, 'Empezar en cero'), h('option', { value: 'saldo' }, 'Tiene un saldo inicial'));
    const saldo = h('input', { id: 'cuenta-saldo', type: 'text', inputmode: 'decimal', placeholder: '0.00' });
    const zona = h('div', { 'aria-live': 'assertive' });
    const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Crear cuenta');
    const gBanco = h('div', { class: 'grupo-campos' }, campo('Banco', banco), campo('Número de cuenta', numero, 'Solo se guardan los 4 últimos números (****1234).'), campo('Tipo de cuenta', tipoCuenta));
    const gCaja = campo('¿Es el efectivo de una caja (punto de emisión)?', caja);
    const gFondo = campo('Fondo fijo de la caja chica (L)', fondo);
    const gSaldo = campo('Saldo inicial (L)', saldo);
    const ver = () => { gBanco.hidden = tipo.value !== 'banco'; gCaja.hidden = tipo.value !== 'efectivo_caja'; gFondo.hidden = tipo.value !== 'caja_chica'; gSaldo.hidden = inicio.value !== 'saldo'; };
    tipo.addEventListener('change', ver); inicio.addEventListener('change', ver); ver();
    const form = h('form', { class: 'formulario', novalidate: true }, campo('Tipo', tipo), campo('Nombre', nombre), gBanco, gCaja, gFondo,
      puede('dinero.saldo_inicial') ? [campo('¿Con cuánto empieza?', inicio), gSaldo] : null, zona, boton,
      h('button', { type: 'button', class: 'boton boton-ancho', onclick: () => recargar() }, 'Cancelar'));
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      zona.replaceChildren();
      if (nombre.value.trim().length < 2) { zona.append(errorSimple('Escriba el nombre de la cuenta.')); return; }
      const datos = { tipo: tipo.value, nombre: nombre.value.trim() };
      if (tipo.value === 'banco') {
        if (!banco.value.trim() || numero.value.replace(/\D/g, '').length < 4) { zona.append(errorSimple('Escriba el banco y el número de cuenta.')); return; }
        Object.assign(datos, { banco: banco.value.trim(), numero_cuenta: numero.value.trim(), tipo_cuenta: tipoCuenta.value });
      }
      if (tipo.value === 'efectivo_caja' && caja.value) datos.caja_id = caja.value;
      if (tipo.value === 'caja_chica') {
        const f = aCentavos(fondo.value);
        if (!f) { zona.append(errorSimple('Escriba el fondo fijo de la caja chica.')); return; }
        datos.fondo_fijo_centavos = f;
      }
      const conSaldo = puede('dinero.saldo_inicial') && inicio.value === 'saldo';
      const monto = conSaldo ? aCentavos(saldo.value) : null;
      if (conSaldo && !monto) { zona.append(errorSimple('Escriba el saldo inicial o elija "Empezar en cero".')); return; }
      if (!await confirmar({ titulo: 'Crear cuenta', texto: `${TIPOS[datos.tipo]}: ${datos.nombre}${conSaldo ? ' con ' + dinero(monto) : ''}.`, textoBoton: 'Sí, crear' })) return;
      const c = await conBoton(boton, zona, () => rpc('crear_cuenta_dinero', { p_empresa_id: E, p_datos: datos }), 'Creando…');
      if (!c) return;
      // La cuenta ya existe; si el saldo inicial falla se avisa (no se vuelve a crear la cuenta).
      try {
        if (conSaldo) await escribir('registrar_saldo_inicial_dinero', { p_empresa_id: E, p_datos: { cuenta_dinero_id: c.cuenta_dinero_id, monto_centavos: monto, fecha: perfilActual().empresa.hoy } });
        else if (puede('dinero.saldo_inicial')) await rpc('empezar_cuenta_en_cero', { p_empresa_id: E, p_cuenta_dinero_id: c.cuenta_dinero_id });
        aviso(`Cuenta creada · ${datos.nombre}${conSaldo ? ' con ' + dinero(monto) : ''}`);
      } catch {
        aviso('La cuenta se creó, pero el saldo inicial no se guardó. Cárguelo otra vez más tarde.', 'info', 9000);
      }
      recargar();
    });
    vista.replaceChildren(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-ncta' }, titulo('h1', 'mas', 'Nueva caja o banco', { id: 't-ncta' }), form));
    nombre.focus();
  }

  vista.append(h('section', { class: 'tarjeta', 'aria-labelledby': 't-cajas' },
    h('div', { class: 'titulo-con-boton' }, titulo('h1', 'banco', 'Cajas y bancos', { id: 't-cajas' }),
      filas.length ? h('button', { type: 'button', class: 'boton boton-principal', id: 'nueva-cuenta', onclick: () => nueva() }, icono('mas'), 'Nueva caja o banco') : null),
    filas.length ? h('div', { class: 'lista-filas' }, filas)
      : estadoVacio({ icono: 'banco', titulo: 'Aún no tiene cajas ni bancos',
        texto: 'Guarde dónde tiene su dinero: la caja de la tienda, la caja chica y sus cuentas de banco.',
        boton: { texto: 'Agregar la primera', onclick: () => nueva(), icono: 'mas', id: 'nueva-cuenta' } })));
}
