# JavaScript backends

These examples run `Hf_hub.Download` under js_of_ocaml and Melange. The same
OCaml driver handles `Need_http`, `Need_store` and `Done` for both backends.
Only the small `Runtime` binding differs. Melange recompiles copies of the
original `src/*.{ml,mli}` through Dune, so there is no fork of the core.

The examples are opt-in through the `javascript` Dune profile. Native package
builds do not acquire JavaScript dependencies. These are example drivers, not
additional opam packages.

## Build and test

Use OCaml >= 4.14, Dune >= 3.17, Node.js >= 20 and npm. Install the two
JavaScript compilers in your opam switch if they are not already available:

```sh
opam install js_of_ocaml melange
make build.javascript
make test.javascript
```

The repo's devcontainer installs Node.js/npm and both OCaml JavaScript
compilers, and its post-create hook installs the locked npm dependencies.
Rebuild an existing container to pick up these toolchain changes. CI runs
`test.javascript` inside the devcontainer for each supported OCaml version;
the published image's smoke test also builds the JavaScript examples.

All OCaml tooling is run through `opam exec`. The build creates
`_build/default/javascript/jsoo/main.bc.js` and the Melange output directory,
then bundles browser assets into `javascript/dist/`. The npm dependency is
esbuild, used only to bundle Melange's runtime for the browser; Node uses the
Dune-generated CommonJS modules directly.

To build only one compiler's output, without npm or browser bundling:

```sh
opam exec -- dune build --profile javascript javascript/jsoo/main.bc.js
opam exec -- dune build --profile javascript @hf-hub-melange
```

`test.javascript` uses loopback HTTP servers and both generated backends. It
checks binary downloads, UTF-8 filenames, metadata redirects, cache reuse,
pinned and offline reads, partial resumes, rejected byte ranges, checksum
failures, and credential removal on cross-origin redirects. It also runs the
browser bundles in isolated JavaScript contexts with Fetch and Web Crypto.
No Hub access is required. Native cache compatibility is checked by opening a
JavaScript-created cache with the existing Unix CLI. The local browser proxy
is checked for metadata preservation and streamed range responses. These
automated checks use Node; they do not launch a real browser.

## Node.js: a cache on disk

```sh
node javascript/node.cjs jsoo timm/mobilenetv2_050.lamb_in1k config.json
node javascript/node.cjs melange timm/mobilenetv2_050.lamb_in1k config.json

# Optional positional arguments: revision, then repo type.
node javascript/node.cjs jsoo o/d data.bin main dataset
HF_HUB_OFFLINE=1 node javascript/node.cjs melange o/m config.json
```

The CLI prints the snapshot path. `HF_HOME`, `HF_HUB_CACHE`,
`HUGGINGFACE_HUB_CACHE`, `XDG_CACHE_HOME`, `HF_ENDPOINT`, `HF_HUB_OFFLINE`,
`HF_TOKEN` and `HUGGING_FACE_HUB_TOKEN` follow the Unix driver's conventions.
With no token environment variable, it reads `HF_HOME/token`. Tokens are
passed as HTTP headers, never command-line arguments.

`node-host.cjs` streams Fetch responses to `.incomplete` files, hashes through
Node's streaming SHA256 API, renames complete blobs, creates relative snapshot
symlinks and writes refs. The layout is shared with the Python and Unix
drivers. A resumed response must have a matching `206 Content-Range`; ignored
or invalid ranges reach the core's discard-and-restart logic. HEAD metadata
redirects remain visible, while GET redirects are followed up to ten times.
Credentials are removed when redirects change origin. Each HTTP operation has
a 60-second timeout covering redirects and the response body.

This example uses POSIX-style snapshot symlinks; Windows may require extra
permissions. Serialize downloads that write the same blob; there is no cache
locking. Completed cached blobs are reused according to the core's policy.

## Browser: Fetch and an in-memory cache

Start the local example server:

```sh
node javascript/serve.cjs
```

Open `http://localhost:8000/browser.html?backend=jsoo` or
`http://localhost:8000/browser.html?backend=melange`. The form defaults to the
server's `/hub` metadata proxy, so public Hub downloads work without a separate
service. The proxy fetches HEAD metadata server-side and streams GET bodies;
`HF_ENDPOINT` selects its upstream and `PORT` selects its localhost port.
This is a local development server, not a production proxy. It serves only the
example assets and binds to loopback. The form uses the same download function
you can call from your own application:

```js
const blob = await hfHubDownload({
  endpoint: 'https://your-metadata-proxy.example',
  repo: 'timm/mobilenetv2_050.lamb_in1k',
  filename: 'config.json',
  revision: 'main',
  // token, kind, cacheDir and offline are optional.
});
console.log(blob.commit, blob.bytes); // bytes is a Uint8Array copy
```

Load `fetch.js`, `browser-host.js` and either `dist/jsoo.js` or
`dist/melange.js` before calling it. The cache stays in memory until the page
closes; `offline: true` reuses bytes downloaded in that page. It is not a disk
cache, OPFS adapter or mmap. The returned bytes can be handed to a browser
safetensors reader, but these examples do not link the native mmap package.
Browser downloads buffer the whole file, so prefer Node for large checkpoints.
SHA256 requires Web Crypto in a secure context (HTTPS or localhost).

### Metadata and CORS

The core needs `X-Repo-Commit`, `X-Linked-Etag`/`ETag` and
`X-Linked-Size`/`Content-Length` from the initial HEAD response. With
`redirect: 'manual'`, browsers return an opaque redirect response that hides
those headers. Following the redirect would lose the initial Hub metadata.
The example reports that restriction instead of silently losing it.

Use an endpoint that returns metadata in a nonredirecting HEAD response.
A same-origin proxy can fetch the Hub HEAD without following it, copy the
metadata headers onto a `200` response, and proxy GET responses (including
Range and Content-Range). A cross-origin endpoint also needs CORS support and
must expose metadata and range headers via `Access-Control-Expose-Headers`.
Authenticated requests need the corresponding allowed request headers.
Browser GET redirects have the same opaque-redirect restriction: the proxy
must perform them server-side or return bytes directly.

Browsers control headers such as Accept-Encoding. The example requests
identity encoding where permitted and rejects encoded GET responses so that
resume offsets refer to the actual saved bytes. CORS or network failures
become transport errors and can fall back to an existing cache entry.

## Host boundary

`Runtime.call` passes an operation name and an array of strings to
`globalThis.hfHubHost.call`, which invokes its callback once with another array
of strings. HTTP replies are `['received', status, ...headerPairs]` or
`['error', message]`; store replies are decoded into the existing typed
`Hf_hub.Store.reply` variants. Sizes travel as decimal int64 strings, avoiding
JavaScript-number rounding at the boundary. Both bindings preserve UTF-8 file
names. Download sequencing, validation policy and cache fallback remain in
the OCaml core.
