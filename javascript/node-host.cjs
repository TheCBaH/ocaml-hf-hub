const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const { createHash } = require('node:crypto');
require('./fetch.js');

const missing = error => ['ENOENT', 'ENOTDIR'].includes(error.code);
async function stat(file) {
  try { return await fsp.stat(file, { bigint: true }); }
  catch (error) { if (missing(error)) return null; throw error; }
}
async function read(file) {
  try { return (await fsp.readFile(file, 'utf8')).trim(); }
  catch (error) { if (missing(error)) return ''; throw error; }
}
async function unlink(file) {
  try { await fsp.unlink(file); } catch (error) { if (!missing(error)) throw error; }
}
async function atomic(file, text) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  try { await fsp.writeFile(tmp, text); await fsp.rename(tmp, file); }
  finally { await unlink(tmp); }
}
async function snapshotEtag(file) {
  try { return path.basename(await fsp.readlink(file)); }
  catch (error) { if (missing(error) || error.code === 'EINVAL') return ''; throw error; }
}

const storage = {
  async open(file, resume) {
    await fsp.mkdir(path.dirname(file), { recursive: true });
    if (resume > 0n && (await stat(file))?.size !== resume)
      throw new Error('partial size changed before download');
    const handle = await fsp.open(file, resume > 0n ? 'a' : 'w');
    return {
      async write(chunk) {
        let written = 0;
        while (written < chunk.byteLength) {
          const result = await handle.write(chunk, written, chunk.byteLength - written);
          if (!result.bytesWritten) throw new Error('zero-length file write');
          written += result.bytesWritten;
        }
      },
      close: () => handle.close(),
    };
  },
};

async function operation(op, args) {
  const [file, second, third] = args;
  switch (op) {
    case 'http': return globalThis.hfHubFetch(args, storage);
    case 'ref': return ['ref', await read(file)];
    case 'snapshot': {
      if (!await stat(file)) return ['absent'];
      const etag = await snapshotEtag(file);
      return second && second !== etag ? ['absent'] : ['present', etag];
    }
    case 'blob': {
      if (await stat(file)) return ['complete'];
      const partial = await stat(second);
      return partial ? ['partial', String(partial.size)] : ['absent'];
    }
    case 'check': {
      const info = await stat(file);
      if (!info) throw new Error('download left no partial blob');
      if (third && info.size !== BigInt(third)) return ['size-mismatch', String(info.size)];
      if (second) {
        const hash = createHash('sha256');
        for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
        const actual = hash.digest('hex');
        if (actual !== second) return ['sha-mismatch', actual];
      }
      return ['verified'];
    }
    case 'discard': await unlink(file); return ['stored'];
    case 'commit': {
      const [blob, partial, snapshot, target, ref, commit] = args;
      await fsp.mkdir(path.dirname(blob), { recursive: true });
      if (await stat(partial)) await fsp.rename(partial, blob);
      await fsp.mkdir(path.dirname(snapshot), { recursive: true });
      let current;
      try { current = await fsp.readlink(snapshot); }
      catch (error) { if (!missing(error) && error.code !== 'EINVAL') throw error; }
      if (current !== target) { await unlink(snapshot); await fsp.symlink(target, snapshot); }
      if (ref) await atomic(ref, commit);
      return ['stored'];
    }
    default: throw new Error(`unknown host operation ${op}`);
  }
}

module.exports = {
  call(op, args, callback) {
    operation(op, args).then(callback, error => callback(['error', error.message]));
  },
};
