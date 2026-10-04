/* Shared Fetch transport for the Node and browser example hosts. */
globalThis.hfHubFetch = async function (args, storage) {
  const [method, initialUrl, path, offset, ...fields] = args;
  const resume = BigInt(offset);
  const headers = new Headers();
  for (let i = 0; i < fields.length; i += 2) headers.set(fields[i], fields[i + 1]);
  if (resume > 0n) headers.set('Range', `bytes=${resume}-`);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60000);
  let writer;
  try {
    let url = new URL(initialUrl);
    let response;
    for (let redirects = 0; ; redirects++) {
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password)
        throw new Error('expected an HTTP(S) URL without embedded credentials');
      response = await fetch(url, {
        method, headers, redirect: 'manual', signal: controller.signal,
        credentials: 'omit',
      });
      if (response.type === 'opaqueredirect' || response.type === 'opaque')
        throw new Error('browser Fetch cannot expose Hub redirect metadata; use a same-origin metadata proxy or a CORS endpoint that returns metadata without redirecting');
      if (method === 'HEAD' || ![301, 302, 303, 307, 308].includes(response.status)) break;
      await response.body?.cancel();
      if (redirects >= 10) throw new Error('too many download redirects');
      const location = response.headers.get('location');
      if (!location) throw new Error('redirect lacks Location');
      const next = new URL(location, url);
      if (next.origin !== url.origin) {
        headers.delete('authorization');
        headers.delete('cookie');
        headers.delete('proxy-authorization');
      }
      url = next;
    }
    const received = ['received', String(response.status), ...Array.from(response.headers).flat()];
    if (method === 'HEAD' || ![200, 206].includes(response.status)) {
      await response.body?.cancel();
      return received;
    }
    if (resume > 0n && response.status !== 206) {
      await response.body?.cancel();
      throw new Error('server ignored the requested byte range');
    }
    let expected;
    if (response.status === 206) {
      const range = /^bytes (\d+)-(\d+)\/(\d+|\*)$/.exec(response.headers.get('content-range') || '');
      if (!range || BigInt(range[1]) !== resume || BigInt(range[2]) < resume ||
          (range[3] !== '*' && BigInt(range[2]) >= BigInt(range[3]))) {
        await response.body?.cancel();
        throw new Error('invalid Content-Range for the requested offset');
      }
      expected = BigInt(range[2]) - resume + 1n;
    }
    const encoding = response.headers.get('content-encoding');
    if (encoding && encoding.toLowerCase() !== 'identity') {
      await response.body?.cancel();
      throw new Error('encoded downloads are unsupported: byte ranges require identity encoding');
    }
    writer = await storage.open(path, resume);
    let count = 0n;
    if (response.body) {
      for await (const chunk of response.body) {
        count += BigInt(chunk.byteLength);
        if (expected !== undefined && count > expected) throw new Error('body exceeds Content-Range');
        await writer.write(chunk);
      }
    }
    if (expected !== undefined && count !== expected) throw new Error('body is shorter than Content-Range');
    return received;
  } finally {
    try { await writer?.close(); } finally { clearTimeout(timer); }
  }
};
