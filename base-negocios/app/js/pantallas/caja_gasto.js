// Caja · "Gasto de caja chica": un gasto rápido (registrar_gasto) con foto opcional del comprobante.
// La foto se sube a Supabase Storage solo si config.js trae "bucketComprobantes"; si no (como en la
// demo local, que no tiene Storage) se guarda SOLO una referencia con el nombre de la foto en la
// descripción y se avisa. Ver app/PENDIENTES.md.
import { escribir, leer, subirComprobante, config } from '../api.js';
import { empresaId } from '../sesion.js';
import { dinero, aCentavos } from '../formato.js';
import { h, aviso, cajaError, errorSimple, campo, conBoton, titulo, estadoVacio } from '../ui.js';
import { hayEnMenu } from '../menu.js';
import { cuentasDinero, olvidarDatos } from '../datos.js';

export async function mostrar(vista, ctx = {}) {
  let cuentas, categorias;
  try {
    [cuentas, categorias] = await Promise.all([cuentasDinero(true),
      leer('categoria_gasto', { empresa_id: empresaId(), activa: true }, { orden: 'nombre.asc' })]);
  } catch (err) { vista.append(await cajaError(err)); return; }
  const chicas = cuentas.filter((c) => c.tipo === 'caja_chica');
  const selCuenta = h('select', { id: 'gasto-cuenta' }, chicas.map((c) => h('option', { value: c.cuenta_dinero_id }, `${c.nombre} · ${dinero(c.saldo_centavos)}`)));
  const selCat = h('select', { id: 'gasto-categoria' }, categorias.map((c) => h('option', { value: c.id }, c.nombre)));
  const monto = h('input', { id: 'gasto-monto', type: 'text', inputmode: 'decimal', autocomplete: 'off', placeholder: '0.00' });
  const desc = h('input', { id: 'gasto-descripcion', type: 'text', maxlength: 200, placeholder: 'Ej.: agua para la tienda' });
  const foto = h('input', { id: 'gasto-foto', type: 'file', accept: 'image/*,application/pdf', capture: 'environment' });
  const zonaError = h('div', { 'aria-live': 'assertive' });
  const boton = h('button', { type: 'submit', class: 'boton boton-principal boton-ancho' }, 'Guardar gasto');
  const form = h('form', { class: 'formulario', novalidate: true },
    campo('Sale de', selCuenta), campo('¿En qué se gastó?', selCat), campo('Monto pagado (L)', monto), campo('Descripción', desc),
    campo('Foto del comprobante (opcional)', foto, config.bucketComprobantes ? null : 'Por ahora se guarda solo el nombre de la foto como referencia.'),
    zonaError, boton);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    zonaError.replaceChildren();
    const m = aCentavos(monto.value);
    if (!m) { zonaError.append(errorSimple('Escriba el monto.', 'Solo números, por ejemplo 150 o 150.50')); return; }
    if (desc.value.trim().length < 3) { zonaError.append(errorSimple('Escriba en qué se gastó (descripción).')); return; }
    const r = await conBoton(boton, zonaError, async () => {
      const datos = { cuenta_dinero_id: selCuenta.value, categoria_id: selCat.value, monto_centavos: m, descripcion: desc.value.trim() };
      const archivo = foto.files && foto.files[0];
      if (archivo) {
        const comp = await subirComprobante(empresaId(), 'gastos', archivo);
        if (comp) datos.comprobante = comp;
        else datos.descripcion = `${datos.descripcion} (foto: ${archivo.name.slice(0, 60)}, sin subir)`.slice(0, 500);
      }
      return escribir('registrar_gasto', { p_empresa_id: empresaId(), p_datos: datos });
    });
    if (r) {
      olvidarDatos('cuentas');
      // Monto que devuelve el servidor y nombre de la cuenta tomado del dato (no del texto de la opción).
      const cuenta = chicas.find((c) => c.cuenta_dinero_id === selCuenta.value);
      const caja = cuenta ? cuenta.nombre : 'la caja chica';
      const monto = r.monto_centavos ?? m;
      aviso(r.estado === 'pendiente_aprobacion' ? `Gasto #${r.numero} de ${dinero(monto)} en espera de aprobación · pasa su tope, todavía no sale dinero`
        : `Gasto #${r.numero} de ${dinero(monto)} guardado · sale de ${caja}`, r.estado === 'pendiente_aprobacion' ? 'info' : 'ok', 7000);
      vista.replaceChildren();
      mostrar(vista, ctx);
    }
  });
  vista.append(h('section', { class: 'tarjeta tarjeta-angosta', 'aria-labelledby': 't-gasto' },
    titulo('h1', 'recibo', 'Gasto de caja chica', { id: 't-gasto' }),
    chicas.length ? form : estadoVacio({ icono: 'billetes', titulo: 'Aún no tiene caja chica',
      texto: 'La caja chica es el dinero para gastos pequeños (agua, pasajes, limpieza). Créela una vez y aquí anota cada gasto.',
      boton: hayEnMenu(ctx.menu || [], 'ajustes', 'cajas') ? { texto: 'Crear la caja chica', href: '#/ajustes/cajas', icono: 'mas' } : null })));
}
