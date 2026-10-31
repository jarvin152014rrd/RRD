// PRUEBA (app 0.14.0): la lista del cascarón de app/sw.js tiene TODOS los archivos de la app y nada que no exista.
// Sin internet la app abre solo con lo que guardó el service worker: un archivo que falte en la lista rompe la app
// sin conexión (la pantalla que lo importa no abre). Sin navegador. La corre herramientas/probar_app.sh.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const app = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'app');
const sw = readFileSync(path.join(app, 'sw.js'), 'utf8');
const lista = JSON.parse('[' + /const CASCARON = \[([\s\S]*?)\];/.exec(sw)[1].replace(/'/g, '"').replace(/,\s*$/, '') + ']');

// Archivos de la app que van en el cascarón: todo menos sw.js, la documentación, las licencias y el ejemplo de config.
const NO_VAN = /(^sw\.js$|\.md$|\.txt$|^config\.ejemplo\.js$)/;
const reales = [];
(function recorrer(dir, base) {
  for (const n of readdirSync(dir)) {
    const p = path.join(dir, n), r = base ? `${base}/${n}` : n;
    if (statSync(p).isDirectory()) recorrer(p, r); else if (!NO_VAN.test(r)) reales.push(r);
  }
})(app, '');

let fallas = 0;
const afirmar = (c, que) => { if (!c) { fallas++; console.log('  FALLA  ' + que); } };
for (const r of reales) afirmar(lista.includes(r), `falta en la lista del cascarón de sw.js: ${r}`);
for (const x of lista) {
  if (x === './' || x === 'config.js') continue;            // la raíz y config.js (lo arma armar_app.sh)
  afirmar(existsSync(path.join(app, x)), `la lista del cascarón tiene un archivo que no existe: ${x}`);
}
afirmar(new Set(lista).size === lista.length, 'la lista del cascarón tiene archivos repetidos');
afirmar(lista.includes('config.js') && lista.includes('./'), 'faltan "./" o config.js en el cascarón');
// Cada import de la app apunta a un archivo de la lista (también los import() de las pantallas del menú).
const menu = readFileSync(path.join(app, 'js', 'menu_datos.js'), 'utf8');
for (const m of menu.matchAll(/pantalla: '([a-z_]+)'/g)) afirmar(lista.includes(`js/pantallas/${m[1]}.js`), `la pantalla ${m[1]} del menú no está en el cascarón`);
const version = /const VERSION = 'cascaron-([0-9.]+)'/.exec(sw)[1];
const versionApp = /VERSION_APP\s*=\s*'([0-9.]+)'/.exec(readFileSync(path.join(app, 'js', 'pantallas', 'aj_datos.js'), 'utf8'));
if (versionApp) afirmar(version === versionApp[1], `la versión del cascarón (${version}) no es la de la app (${versionApp[1]})`);
console.log(`  ${fallas ? 'FALLA' : 'OK   '}  cascarón: ${lista.length} archivos en sw.js, ${reales.length} archivos reales en app/`);
console.log(`\nRESULTADO cascarón: ${fallas ? 'FALLA' : 'TODO OK'}`);
process.exit(fallas ? 1 : 0);
