// Caja · "Depósito o retiro": llevar efectivo al banco (queda en tránsito hasta confirmar)
// o traer efectivo del banco a una caja. Llama trasladar_dinero (dinero.trasladar).
import { escribir } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, aCentavos } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, titulo, estadoVacio } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, olvidarDatos } from '../datos.js';

const ES_CAJA = (c) => c.tipo === 'efectivo_caja' || c.tipo === 'caja_chica';

export async function mostrar(vista, ctx = {}) {
  let cuentas;
  try { cuentas = await cuentasDinero(true); } catch (err) { vista.append(await cajaError(err)); return; }
  const cajas = cuentas.filter(ES_CAJA);
  const bancos = cuentas.filter((c) => c.tipo === 'banco');
  const opcion = (c) => h('option', { value: c.cuenta_dinero_id },
    `${c.nombre}${c.numero_enmascarado ? ' ' + c.numero_enmascarado : ''} · ${dinero(c.saldo_centavos)}`);

  const tipo = { valor: 'deposito' };
  const selCaja = h('select', { id: 'mov-caja' }, cajas.map(opcion));
  const selBanco = h('select', { id: 'mov-banco' }, bancos.map(opcion));
  const monto = h('input', { id: 'mov-monto', type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00' });
  const referencia = h('input', { id: 'mov-referencia', type: 'text', maxlength: 100 });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Registrar depósito');
  const lblCaja = campo('Sale de (caja)', selCaja);
  const lblBanco = campo('Entra a (banco)', selBanco);
  const ayudaTipo = h('p', { class: 'ayuda' });
  const radio = (v, texto) => {
    const r = h('input', { type: 'radio', name: 'mov-tipo', value: v, checked: v === tipo.valor });
    r.addEventListener('change', () => { tipo.valor = v; pintarTipo(); });
    return h('label', {}, r, ' ' + texto);
  };
  const lugar = h('div', { class: 'mov-lugares' });
  function pintarTipo() {
    const dep = tipo.valor === 'deposito';
    lblCaja.querySelector('label').textContent = dep ? 'Sale de (caja)' : 'Entra a (caja)';
    lblBanco.querySelector('label').textContent = dep ? 'Entra a (banco)' : 'Sale de (banco)';
    lugar.replaceChildren(...(dep ? [lblCaja, lblBanco] : [lblBanco, lblCaja]));
    ayudaTipo.textContent = dep ? 'El depósito queda "en tránsito" hasta que se confirme que el banco lo tiene.'
      : 'El retiro saca el dinero del banco y lo pone en la caja.';
    boton.textContent = dep ? 'Registrar depósito' : 'Registrar retiro';
  }
  const form = h('form', { class: 'formulario', novalidate: true },
    h('fieldset', { class: 'opciones' }, h('legend', {}, '¿Qué va a hacer?'), radio('deposito', 'Depositar al banco'), radio('retiro', 'Retirar del banco')),
    ayudaTipo, lugar, campo('Monto (L)', monto), campo('Referencia (número de boleta o cheque)', referencia), zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(monto.value);
    if (!m) { zonaError.append(errorSimple('Escriba el monto.', 'Solo números, por ejemplo 2500 o 2500.50')); return; }
    if (!selCaja.value || !selBanco.value) { zonaError.append(errorSimple('Elija la caja y el banco.')); return; }
    const dep = tipo.valor === 'deposito';
    const datos = { tipo: dep ? 'deposito' : 'retiro', origen_id: dep ? selCaja.value : selBanco.value,
      destino_id: dep ? selBanco.value : selCaja.value, monto_centavos: m };
    if (referencia.value.trim()) datos.referencia = referencia.value.trim();
    const r = await conBoton(boton, zonaError, () => escribir('trasladar_dinero', { p_empresa_id: empresaId(), p_datos: datos }));
    if (r) {
      olvidarDatos('cuentas');
      const de = (sel) => (sel.selectedOptions[0] ? sel.selectedOptions[0].textContent.split(' · ')[0] : '');
      aviso(dep ? `Depósito de ${dinero(m)} registrado · sale de ${de(selCaja)} · queda en tránsito hasta confirmarlo`
        : `Retiro de ${dinero(m)} registrado · entra a ${de(selCaja)}`, 'ok', 7000);
      vista.replaceChildren();
      mostrar(vista, ctx);
    }
  });
  pintarTipo();
  vista.append(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-mov' },
    titulo('h1', 'billetes', 'Depósito o retiro', { id: 't-mov' }),
    !cajas.length || !bancos.length ? estadoVacio({ icono: 'banco', titulo: 'Primero guarde sus cajas y bancos',
      texto: 'Para meter o sacar efectivo necesita al menos una caja y una cuenta de banco.',
      boton: hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Agregar caja o banco', href: '#/ajustes/cajas', icono: 'mas' } : null }) : form));
}
