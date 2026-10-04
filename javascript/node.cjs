const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
globalThis.hfHubHost = require('./node-host.cjs');
const [backend, repo, filename, revision = 'main', kind = 'model'] = process.argv.slice(2);
if (!['jsoo', 'melange'].includes(backend) || !repo || !filename) {
  console.error('usage: node javascript/node.cjs jsoo|melange REPO FILE [REVISION] [model|dataset|space]');
  process.exit(2);
}
const root = path.resolve(__dirname, '..');
require(backend === 'jsoo'
  ? `${root}/_build/default/javascript/jsoo/main.bc.js`
  : `${root}/_build/default/javascript/melange/output/javascript/melange/main.js`);
const env = process.env;
const home = env.HF_HOME || path.join(env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache'), 'huggingface');
let token = env.HF_TOKEN || env.HUGGING_FACE_HUB_TOKEN || '';
if (!token) {
  try { token = fs.readFileSync(path.join(home, 'token'), 'utf8').trim(); }
  catch (error) { if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error; }
}
globalThis.hfHubStart([
  env.HF_HUB_CACHE || env.HUGGINGFACE_HUB_CACHE || path.join(home, 'hub'),
  env.HF_ENDPOINT || 'https://huggingface.co',
  String(['1', 'true', 'yes', 'on'].includes((env.HF_HUB_OFFLINE || '').toLowerCase())),
  token, repo, filename, revision, kind,
], reply => {
  if (reply[0] === 'ok') console.log(reply[1]);
  else { console.error(reply[1]); process.exitCode = 1; }
});
