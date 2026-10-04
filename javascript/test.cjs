const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { createHash, webcrypto } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const exec = promisify(execFile);
const root = path.resolve(__dirname, '..');
const commit = '0123456789abcdef0123456789abcdef01234567';
const body = Buffer.from([0, 255, 128, 104, 101, 108, 108, 111]);
const sha = createHash('sha256').update(body).digest('hex');

async function fixture(t) {
  const cache = await fs.mkdtemp(path.join(os.tmpdir(), 'hf-hub-js-'));
  const state = { requests: [], mode: 'normal', size: String(body.length) };
  const server = http.createServer((req, res) => {
    state.requests.push({ method: req.method, url: req.url, range: req.headers.range, authorization: req.headers.authorization });
    if (req.method === 'HEAD') {
      if (state.mode === 'missing') { res.writeHead(404).end(); return; }
      res.writeHead(state.mode === 'redirect' ? 302 : 200, {
        'X-Repo-Commit': commit, 'X-Linked-Etag': `"${sha}"`,
        'X-Linked-Size': state.size, Location: '/blob',
      }).end();
      return;
    }
    if (state.mode === 'redirect' && req.url !== '/blob') { res.writeHead(302, { Location: '/blob' }).end(); return; }
    const offset = Number((req.headers.range || 'bytes=0-').match(/\d+/)[0]);
    const content = state.mode === 'corrupt' ? Buffer.alloc(body.length, 7) : body;
    if (offset && state.mode !== 'ignore-range') {
      res.writeHead(206, { 'Content-Range': `bytes ${state.mode === 'bad-range' ? 0 : offset}-${body.length - 1}/${body.length}` });
      res.end(content.subarray(offset));
    } else res.end(content);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
    await fs.rm(cache, { recursive: true, force: true });
  });
  return { cache, state, server, endpoint: `http://127.0.0.1:${server.address().port}` };
}

function cli(backend, fixture, options = {}) {
  const { revision = 'main', filename = 'nested/café.bin', ...env } = options;
  return exec(process.execPath, [path.join(__dirname, 'node.cjs'), backend, 'o/m', filename, revision], {
    env: { ...process.env, HF_HOME: fixture.cache, HF_HUB_CACHE: fixture.cache,
      HF_ENDPOINT: fixture.endpoint, HF_HUB_OFFLINE: '0', HF_TOKEN: 'example-test-token', ...env },
  });
}

for (const backend of ['jsoo', 'melange']) {
  test(`${backend}: download, branch hit, pinned hit, offline and native cache interoperability`, async t => {
    const f = await fixture(t);
    const first = (await cli(backend, f)).stdout.trim();
    assert.deepEqual(await fs.readFile(first), body);
    assert.equal(await fs.readlink(first), `../../../blobs/${sha}`);
    assert.deepEqual(f.state.requests.map(r => r.method), ['HEAD', 'GET']);
    assert.equal(f.state.requests[0].url, '/o/m/resolve/main/nested/caf%C3%A9.bin');
    assert.equal(f.state.requests[0].authorization, 'Bearer example-test-token');
    await cli(backend, f);
    assert.deepEqual(f.state.requests.map(r => r.method), ['HEAD', 'GET', 'HEAD']);
    await cli(backend, f, { revision: commit });
    await cli(backend, f, { HF_HUB_OFFLINE: '1' });
    assert.equal(f.state.requests.length, 3);
    const native = await exec('opam', ['exec', '--', 'dune', 'exec', 'bin/hf_hub_cli.exe', '--', 'o/m', 'nested/café.bin'], {
      cwd: root, env: { ...process.env, HF_HUB_CACHE: f.cache, HF_HUB_OFFLINE: '1' },
    });
    assert.equal(native.stdout.trim(), first);
    await assert.rejects(cli(backend, f, { filename: 'absent.bin', HF_HUB_OFFLINE: '1' }), /not in the cache/);
  });

  for (const mode of ['normal', 'ignore-range', 'bad-range', 'corrupt-partial']) {
    test(`${backend}: resumes partial (${mode})`, async t => {
      const f = await fixture(t);
      f.state.mode = mode;
      const partial = path.join(f.cache, 'models--o--m', 'blobs', `${sha}.incomplete`);
      await fs.mkdir(path.dirname(partial), { recursive: true });
      await fs.writeFile(partial, mode === 'corrupt-partial' ? Buffer.from('bad') : body.subarray(0, 3));
      const output = (await cli(backend, f)).stdout.trim();
      assert.deepEqual(await fs.readFile(output), body);
      assert.equal(f.state.requests[1].range, 'bytes=3-');
      assert.equal(f.state.requests.length, mode === 'normal' ? 2 : 3);
      if (mode !== 'normal') assert.equal(f.state.requests[2].range, undefined);
    });
  }

  test(`${backend}: checksum failure discards unverified data`, async t => {
    const f = await fixture(t);
    f.state.mode = 'corrupt';
    await assert.rejects(cli(backend, f), /sha256 mismatch/);
    assert.deepEqual(await fs.readdir(path.join(f.cache, 'models--o--m', 'blobs')), []);
  });

  test(`${backend}: metadata sizes preserve int64 precision and reject short bodies`, async t => {
    const f = await fixture(t);
    f.state.size = '9007199254740993';
    await assert.rejects(cli(backend, f), /9007199254740993/);
    assert.deepEqual(await fs.readdir(path.join(f.cache, 'models--o--m', 'blobs')), []);
  });

  test(`${backend}: HTTP errors stay distinct from transport and offline errors`, async t => {
    const f = await fixture(t);
    f.state.mode = 'missing';
    await assert.rejects(cli(backend, f), /HTTP 404/);
    assert.equal(f.state.requests.length, 1);
    await assert.rejects(cli(backend, f, { filename: '../bad' }), /invalid file name/);
    assert.equal(f.state.requests.length, 1);
  });

  test(`${backend}: HEAD metadata redirects stay visible, GET follows`, async t => {
    const f = await fixture(t);
    f.state.mode = 'redirect';
    assert.deepEqual(await fs.readFile((await cli(backend, f)).stdout.trim()), body);
    assert.deepEqual(f.state.requests.map(r => r.method), ['HEAD', 'GET', 'GET']);
  });

  test(`${backend}: browser bundle with Fetch, Web Crypto and memory store`, async t => {
    const f = await fixture(t);
    const context = vm.createContext({ console, URL, Headers, fetch, AbortController,
      Uint8Array, TextEncoder, TextDecoder, crypto: webcrypto, setTimeout, clearTimeout });
    for (const file of ['fetch.js', 'browser-host.js', `dist/${backend}.js`])
      vm.runInContext(await fs.readFile(path.join(__dirname, file), 'utf8'), context, { filename: file });
    const options = { endpoint: f.endpoint, repo: 'o/m', filename: 'nested/café.bin' };
    const first = await context.hfHubDownload(options);
    assert.deepEqual(Buffer.from(first.bytes), body);
    first.bytes.fill(0);
    const cached = await context.hfHubDownload({ ...options, revision: commit });
    assert.deepEqual(Buffer.from(cached.bytes), body);
    await context.hfHubDownload({ ...options, offline: true });
    assert.equal(f.state.requests.length, 2);
    await assert.rejects(context.hfHubDownload({ ...options, filename: '../bad' }), /invalid file name/);
    await assert.rejects(context.hfHubDownload({ ...options, filename: 'absent', offline: true }), /not in the cache/);
    context.fetch = async () => ({ type: 'opaqueredirect' });
    const fallback = await context.hfHubDownload(options);
    assert.deepEqual(Buffer.from(fallback.bytes), body);
    await assert.rejects(context.hfHubDownload({ ...options, filename: 'uncached' }), /metadata proxy/);
  });
}

test('Fetch strips credentials on cross-origin redirects', async t => {
  const f = await fixture(t);
  const redirect = http.createServer((req, res) => res.writeHead(302, { Location: `${f.endpoint}/blob` }).end());
  await new Promise(resolve => redirect.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { redirect.close(resolve); redirect.closeAllConnections(); }));
  require('./fetch.js');
  const chunks = [];
  await globalThis.hfHubFetch([
    'GET', `http://127.0.0.1:${redirect.address().port}/blob`, '', '0', 'Authorization', 'Bearer secret',
  ], { async open() { return { async write(bytes) { chunks.push(bytes); }, async close() {} }; } });
  assert.deepEqual(Buffer.concat(chunks), body);
  assert.equal(f.state.requests[0].authorization, undefined);
});

test('browser metadata proxy exposes HEAD redirect headers and streams GET ranges', async t => {
  const f = await fixture(t);
  f.state.mode = 'redirect';
  const proxy = require('./serve.cjs').createServer({ endpoint: f.endpoint });
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { proxy.close(resolve); proxy.closeAllConnections(); }));
  const endpoint = `http://127.0.0.1:${proxy.address().port}`;
  const metadata = await fetch(`${endpoint}/hub/o/m/resolve/main/nested/caf%C3%A9.bin`, { method: 'HEAD', redirect: 'manual' });
  assert.equal(metadata.status, 200);
  assert.equal(metadata.headers.get('x-repo-commit'), commit);
  assert.equal(metadata.headers.get('x-linked-etag'), `"${sha}"`);
  assert.equal(metadata.headers.get('location'), null);
  const response = await fetch(`${endpoint}/hub/o/m/resolve/main/nested/caf%C3%A9.bin`, { headers: { Range: 'bytes=3-' } });
  assert.equal(response.status, 206);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), body.subarray(3));
  assert.equal((await fetch(`${endpoint}/browser.html`)).status, 200);
  assert.equal((await fetch(`${endpoint}/node-host.cjs`)).status, 404);
});
