// Local example server: static assets plus a same-origin Hub metadata proxy.
const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const assets = new Map([
  ['/browser.html', 'text/html; charset=utf-8'],
  ['/fetch.js', 'text/javascript; charset=utf-8'],
  ['/browser-host.js', 'text/javascript; charset=utf-8'],
  ['/dist/jsoo.js', 'text/javascript; charset=utf-8'],
  ['/dist/melange.js', 'text/javascript; charset=utf-8'],
]);

function createServer({ endpoint = 'https://huggingface.co' } = {}) {
  const upstream = new URL(endpoint);
  if (!['http:', 'https:'].includes(upstream.protocol) || upstream.username || upstream.password)
    throw new Error('HF_ENDPOINT must be an HTTP(S) URL without embedded credentials');
  return http.createServer(async (req, res) => {
    let timer;
    try {
      if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405).end(); return; }
      const requested = new URL(req.url, 'http://localhost');
      const resource = requested.pathname === '/' ? '/browser.html' : requested.pathname;
      if (!resource.startsWith('/hub/')) {
        if (!assets.has(resource)) { res.writeHead(404).end(); return; }
        const bytes = await fs.readFile(path.join(__dirname, resource.slice(1)));
        res.writeHead(200, { 'Content-Type': assets.get(resource) });
        res.end(req.method === 'HEAD' ? undefined : bytes);
        return;
      }
      let url = new URL(upstream);
      url.pathname = upstream.pathname.replace(/\/$/, '') + resource.slice(4);
      url.search = requested.search;
      const headers = new Headers({ 'Accept-Encoding': 'identity' });
      for (const name of ['authorization', 'range', 'user-agent'])
        if (req.headers[name]) headers.set(name, req.headers[name]);
      const controller = new AbortController();
      timer = setTimeout(() => controller.abort(), 60000);
      res.on('close', () => controller.abort());
      let response;
      for (let redirects = 0; ; redirects++) {
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password)
          throw new Error('unsupported upstream redirect');
        response = await fetch(url, { method: req.method, headers, redirect: 'manual', signal: controller.signal });
        if (req.method === 'HEAD' || ![301, 302, 303, 307, 308].includes(response.status)) break;
        await response.body?.cancel();
        if (redirects >= 10) throw new Error('too many upstream redirects');
        const location = response.headers.get('location');
        if (!location) throw new Error('redirect lacks Location');
        const next = new URL(location, url);
        if (next.origin !== url.origin) headers.delete('authorization');
        url = next;
      }
      const outgoing = {};
      for (const name of ['x-repo-commit', 'x-linked-etag', 'x-linked-size', 'etag', 'content-range', 'content-type']) {
        const value = response.headers.get(name);
        if (value !== null) outgoing[name] = value;
      }
      if (req.method === 'HEAD') {
        const status = response.status >= 300 && response.status < 400 ? 200 : response.status;
        // Redirect Content-Length describes the redirect body, not the blob.
        if (response.status === 200 && response.headers.has('content-length'))
          outgoing['content-length'] = response.headers.get('content-length');
        res.writeHead(status, outgoing).end();
      } else {
        const encoding = response.headers.get('content-encoding');
        if (encoding && encoding.toLowerCase() !== 'identity') {
          await response.body?.cancel();
          throw new Error('upstream returned encoded bytes despite identity request');
        }
        if (response.headers.has('content-length')) outgoing['content-length'] = response.headers.get('content-length');
        res.writeHead(response.status, outgoing);
        if (response.body) await pipeline(Readable.fromWeb(response.body), res);
        else res.end();
      }
    } catch (error) {
      if (!res.headersSent) {
        res.writeHead(error.code === 'ENOENT' ? 404 : 502, { 'Content-Type': 'text/plain' });
        res.end(error.message);
      } else res.destroy(error);
    } finally { clearTimeout(timer); }
  });
}

module.exports = { createServer };
if (require.main === module) {
  const server = createServer({ endpoint: process.env.HF_ENDPOINT || 'https://huggingface.co' });
  server.listen(Number(process.env.PORT || 8000), '127.0.0.1', () => {
    console.log(`Browser example: http://localhost:${server.address().port}/browser.html?backend=jsoo`);
    console.log(`Melange example: http://localhost:${server.address().port}/browser.html?backend=melange`);
  });
}
