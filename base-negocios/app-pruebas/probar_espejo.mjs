// PRUEBA: pruebas espejo (app 0.14.0, núcleo 0.20.0, G5): la cuenta de la venta en el equipo (app/js/calculo_local.js,
// con la foto del catálogo de preparar_sin_internet) da EXACTAMENTE lo mismo que calcular_venta_previa del servidor
// (precio, total por línea, ISV, total con ISV, promoción elegida o sugerida, mayorista por cantidad y por cliente,
// exento con decimales, servicio) en 200 carritos al azar de la base de demo, o el mismo error; y el total en letras.
// Sin navegador: Node y psql. La corre herramientas/probar_app.sh. Variables: BASE_DEMO, PG* del servidor local.
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const { calcularVentaLocal, montoEnLetras, fechaLocal } = await import(pathToFileURL(path.join(aqui, '..', 'app', 'js', 'calculo_local.js')).href);
const BASE = process.env.BASE_DEMO || 'demo_pruebas_app';
const DUENO = 'dueno@demo.hn';

// Corre una consulta con la sesión de la dueña (claims del JWT; el guion previo crea la función temporal) y devuelve su texto.
function sql(consulta, previo = '') {
  const guion = `BEGIN;\n${previo}\nSELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM auth.users WHERE email = '${DUENO}'), 'role', 'authenticated')::text, true) \\g /dev/null\nSELECT '@@' || (${consulta})::text;\nROLLBACK;`;
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: guion, encoding: 'utf8', maxBuffer: 64 << 20 });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  return r.stdout.split('\n').find((l) => l.startsWith('@@')).slice(2);
}
const comoSuper = (consulta) => {
  const r = spawnSync('psql', ['-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', BASE], { input: `SELECT '@@' || (${consulta})::text;`, encoding: 'utf8', maxBuffer: 64 << 20 });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  return r.stdout.split('\n').find((l) => l.startsWith('@@')).slice(2);
};

let fallas = 0, total = 0;
function afirmar(c, que) { total++; if (!c) { fallas++; console.log('  FALLA  ' + que); } }

const empresa = comoSuper(`(SELECT valor FROM demo.dato WHERE clave = 'EMPRESA')`);
const foto = JSON.parse(comoSuper(`interno.armar_catalogo('${empresa}', (SELECT sucursal_id FROM public.caja WHERE empresa_id = '${empresa}' AND punto_emision = '001'))`));
const clientes = JSON.parse(comoSuper(`(SELECT jsonb_agg(id) FROM public.tercero WHERE empresa_id = '${empresa}' AND es_cliente)`));
const zona = comoSuper(`(SELECT zona_horaria FROM public.empresa WHERE id = '${empresa}')`);
const hoy = fechaLocal(Date.now(), zona);
const prods = Object.keys(foto.productos);

// Carritos al azar (semilla fija).
let semilla = 1234567;
const azar = () => { semilla = (semilla * 1103515245 + 12345) % 2147483648; return semilla / 2147483648; };
const casos = [];
for (let i = 0; i < 200; i++) {
  const n = 1 + Math.floor(azar() * 4);
  const lineas = [];
  for (let k = 0; k < n; k++) {
    const id = prods[Math.floor(azar() * prods.length)];
    const p = foto.productos[id];
    const cantidad = p.permite_fracciones ? Math.round((0.25 + azar() * 12) * 100) / 100 : 1 + Math.floor(azar() * 40);
    const tipo = ['normal', 'mayorista', null, null][Math.floor(azar() * 4)];
    lineas.push({ producto_id: id, cantidad, ...(tipo ? { precio_tipo: tipo } : {}) });
  }
  casos.push({ lineas, ...(azar() < 0.35 ? { cliente_id: clientes[Math.floor(azar() * clientes.length)] } : {}) });
}

// El servidor: calcular_venta_previa de cada carrito, con su error si da error (una sola llamada a psql).
const previo = `CREATE FUNCTION pg_temp.previa(c jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  RETURN public.calcular_venta_previa('${empresa}', c);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLERRM);
END $f$;`;
const servidor = JSON.parse(sql(`(SELECT jsonb_agg(pg_temp.previa(c.caso) ORDER BY c.k)
  FROM jsonb_array_elements($j$${JSON.stringify(casos)}$j$::jsonb) WITH ORDINALITY c(caso, k))`, previo));

let iguales = 0, errores = 0;
casos.forEach((caso, i) => {
  const s = servidor[i];
  let l = null, error = null;
  try { l = calcularVentaLocal(foto, { lineas: caso.lineas, cliente_id: caso.cliente_id || null, fecha: hoy, sugerir: true }); } catch (e) { error = e.message; }
  if (s.error || error) {
    const clave = (x) => (/^([A-Z_]+):/.exec(x || '') || [])[1];
    afirmar(clave(s.error) === clave(error), `caso ${i + 1}: error distinto: servidor "${s.error}" / equipo "${error}" ${JSON.stringify(caso)}`);
    errores++;
    return;
  }
  const comparar = (a, b, que) => afirmar(a === b, `caso ${i + 1}: ${que}: servidor ${a} / equipo ${b} ${JSON.stringify(caso)}`);
  comparar(s.total_centavos, l.total_centavos, 'total');
  comparar(s.impuesto_centavos, l.impuesto_centavos, 'ISV');
  comparar(s.subtotal_centavos, l.subtotal_centavos, 'subtotal sin ISV');
  comparar(s.subtotal_con_isv_centavos, l.subtotal_con_isv_centavos, 'subtotal con ISV');
  comparar(s.descuento_con_isv_centavos, l.descuento_con_isv_centavos, 'descuento con ISV');
  comparar(s.exento_centavos, l.exento_centavos, 'exento');
  s.lineas.forEach((x, k) => {
    const y = l.lineas[k];
    comparar(x.precio_unitario_centavos, y.precio_unitario_centavos, `línea ${k + 1} precio`);
    comparar(x.total_centavos, y.total_centavos, `línea ${k + 1} total`);
    comparar(x.impuesto_centavos, y.impuesto_centavos, `línea ${k + 1} ISV`);
    comparar(x.precio_tipo, y.precio_tipo, `línea ${k + 1} tipo de precio`);
    comparar(x.promocion_id || null, y.promocion_id || null, `línea ${k + 1} promoción`);
    comparar(Boolean(x.precio_mayorista_disponible), Boolean(y.precio_mayorista_disponible), `línea ${k + 1} mayorista disponible`);
  });
  iguales++;
});
afirmar(iguales >= 100 && errores >= 10, `pocos casos calculados: ${iguales}`);
console.log(`  ${fallas ? 'FALLA' : 'OK   '}  pruebas espejo: ${iguales} carritos dan lo mismo en el equipo y en el servidor, ${errores} dan el mismo error (200 casos)`);

// Total en letras como el servidor.
for (const c of [0, 1500, 100, 2100, 100000, 115000, 2100000, 100000000, 123456789, 99]) {
  const s = comoSuper(`interno.monto_en_letras(${c})`);
  afirmar(s === montoEnLetras(c), `letras de ${c}: servidor "${s}" / equipo "${montoEnLetras(c)}"`);
}
console.log(`  ${fallas ? 'FALLA' : 'OK   '}  total en letras igual que el servidor`);
console.log(`\nRESULTADO espejo: ${fallas ? 'FALLA' : 'TODO OK'} (${total - fallas} de ${total} comprobaciones)`);
process.exit(fallas ? 1 : 0);
