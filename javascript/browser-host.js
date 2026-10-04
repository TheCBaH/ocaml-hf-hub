/* This cache is in memory for the lifetime of the page. No Unix, mmap or fs. */
globalThis.hfHubHost = (() => {
  const files = new Map();
  const snapshots = new Map();
  const refs = new Map();
  const storage = {
    async open(path, resume) {
      if (resume > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('browser buffer offset is too large');
      const previous = resume > 0n ? files.get(path) : new Uint8Array();
      if (!previous || BigInt(previous.byteLength) !== resume)
        throw new Error('partial size changed before download');
      // Keep partial bytes if the stream fails, so a later call can resume.
      const chunks = [previous];
      let size = previous.byteLength;
      return {
        async write(chunk) { chunks.push(chunk.slice()); size += chunk.byteLength; },
        async close() {
          const bytes = new Uint8Array(size);
          let offset = 0;
          for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
          files.set(path, bytes);
        },
      };
    },
  };
  async function operation(op, args) {
    const [file, second, third] = args;
    switch (op) {
      case 'http': return globalThis.hfHubFetch(args, storage);
      case 'ref': return ['ref', refs.get(file) || ''];
      case 'snapshot': {
        const snapshot = snapshots.get(file);
        return snapshot && files.has(snapshot.blob) && (!second || snapshot.etag === second)
          ? ['present', snapshot.etag] : ['absent'];
      }
      case 'blob':
        return files.has(file) ? ['complete'] : files.has(second)
          ? ['partial', String(files.get(second).byteLength)] : ['absent'];
      case 'check': {
        const bytes = files.get(file);
        if (!bytes) throw new Error('download left no partial blob');
        if (third && BigInt(bytes.byteLength) !== BigInt(third)) return ['size-mismatch', String(bytes.byteLength)];
        if (second) {
          const digest = await crypto.subtle.digest('SHA-256', bytes);
          const actual = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
          if (actual !== second) return ['sha-mismatch', actual];
        }
        return ['verified'];
      }
      case 'discard': files.delete(file); return ['stored'];
      case 'commit': {
        const [blob, partial, snapshot, , ref, commit, etag] = args;
        if (files.has(partial)) { files.set(blob, files.get(partial)); files.delete(partial); }
        if (!files.has(blob)) throw new Error('missing completed blob');
        snapshots.set(snapshot, { blob, etag });
        if (ref) refs.set(ref, commit);
        return ['stored'];
      }
      default: throw new Error(`unknown host operation ${op}`);
    }
  }
  return {
    call(op, args, callback) {
      operation(op, args).then(callback, error => callback(['error', error.message]));
    },
    bytes(path) {
      const snapshot = snapshots.get(path);
      return snapshot ? files.get(snapshot.blob)?.slice() : undefined;
    },
  };
})();

globalThis.hfHubDownload = function (options) {
  return new Promise((resolve, reject) => {
    if (typeof globalThis.hfHubStart !== 'function') return reject(new Error('load an OCaml JavaScript bundle first'));
    globalThis.hfHubStart([
      options.cacheDir || '/hub', options.endpoint || 'https://huggingface.co',
      String(Boolean(options.offline)), options.token || '', options.repo,
      options.filename, options.revision || 'main', options.kind || 'model',
    ], reply => {
      if (reply[0] === 'error') reject(new Error(reply[1]));
      else resolve({ path: reply[1], commit: reply[2], etag: reply[3] || null, bytes: globalThis.hfHubHost.bytes(reply[1]) });
    });
  });
};
