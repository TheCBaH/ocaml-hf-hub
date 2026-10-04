const path = require('node:path');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const esbuild = require('esbuild');
const root = path.resolve(__dirname, '..');
const opamLib = execFileSync('opam', ['var', 'lib'], { encoding: 'utf8' }).trim();
fs.mkdirSync(path.join(__dirname, 'dist'), { recursive: true });
const jsooBundle = path.join(__dirname, 'dist/jsoo.js');
fs.rmSync(jsooBundle, { force: true });
fs.copyFileSync(path.join(root, '_build/default/javascript/jsoo/main.bc.js'), jsooBundle);
fs.chmodSync(jsooBundle, 0o644);
esbuild.buildSync({
  entryPoints: [path.join(root, '_build/default/javascript/melange/output/javascript/melange/main.mjs')],
  outfile: path.join(__dirname, 'dist/melange.js'),
  bundle: true, format: 'iife', platform: 'browser',
  nodePaths: [path.join(opamLib, 'melange/js')],
});
