# ocaml-hf-hub

[![build](https://github.com/TheCBaH/ocaml-hf-hub/actions/workflows/build.yml/badge.svg?branch=devel)](https://github.com/TheCBaH/ocaml-hf-hub/actions/workflows/build.yml?query=branch%3Adevel)
[![images](https://github.com/TheCBaH/ocaml-hf-hub/actions/workflows/images.yml/badge.svg?branch=devel)](https://github.com/TheCBaH/ocaml-hf-hub/actions/workflows/images.yml?query=branch%3Adevel)
[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?hide_repo_select=true&ref=devel&repo=1403807767)

Download files from the Hugging Face Hub into a cache that `huggingface_hub`
(Python) reads and writes too.

- **`hf-hub`** — sans-IO core. A download is a step machine
  (`Need_http | Need_store | Done`); the core never performs IO, so each platform
  can drive it in its own effect model. Depends on the standard library only.
- **`hf-hub-unix`** — blocking driver: `curl` for HTTP (headers, including the
  token, go through a private config file, never argv), the filesystem for the
  cache, `sha256sum`/`shasum` for verification. Env: `HF_HOME`, `HF_HUB_CACHE`,
  `HF_TOKEN`, `HF_HUB_OFFLINE`, `HF_ENDPOINT`. CLI: `hf-hub REPO FILE [--revision R]`
  prints the cached path.
- **`hf-hub-safetensors`** — `open_mmap`: resolve through the cache, then map the
  blob read-only via `safetensors-unix` (needs its `Mmap` reader).
- **`hf-hub-lwt`** — [Cohttp](https://github.com/mirage/ocaml-cohttp) HTTP/1.1
  client with Lwt and native [OCaml TLS](https://github.com/mirleft/ocaml-tls).
  Returns `Lwt.t`; includes a blocking adapter for the Unix/mmap API.
- **`hf-hub-async`** — [h2-async](https://github.com/anmonteiro/ocaml-h2)
  HTTP/2 client with Jane Street Async and OCaml TLS. Returns `Deferred.t`.
  HTTPS requires the server to negotiate `h2` through ALPN; plaintext HTTP
  uses prior-knowledge HTTP/2 (h2c). Use Lwt for HTTP/1-only endpoints.

The two asynchronous packages are independent. Their HTTP clients stream
downloads to disk, validate byte ranges before resuming, check certificates
and hostnames against system trust roots, and remove credentials when GET
redirects change origin. HEAD redirects remain visible for Hub metadata.
Requests default to a 60-second timeout and at most ten GET redirects;
`Hf_hub_lwt.cohttp` and `Hf_hub_async.h2` accept overrides.

Behaviour: a commit-sha revision already cached needs no request; an unreachable
Hub falls back to the cache; a partial `.incomplete` blob resumes; LFS files are
checked against their sha256 and size, and a corrupt resumed partial is discarded
and refetched once.

## Development

Open the Codespace above, or clone `devel` and reopen it in a local
devcontainer using VS Code's **Dev Containers: Reopen in Container** command:

```sh
git clone --branch devel --recurse-submodules https://github.com/TheCBaH/ocaml-hf-hub.git
cd ocaml-hf-hub
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . make build test format-check
```

The container defaults to OCaml 4.14.3; export `OCAML_VERSION=5.3.0` before
creating it to select OCaml 5.3. CI builds and tests both versions using
[devcontainer-action](https://github.com/TheCBaH/devcontainer-action).
The image workflow publishes the default toolchain to GHCR. Dependencies
are listed in [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json).

[ocaml-safetensors](https://github.com/TheCBaH/ocaml-safetensors) is pinned
as a submodule for the mmap package and its existing tests. The container
initializes submodules automatically; for an existing clone outside the
container, run `git submodule update --init --recursive`. The core and HTTP
packages do not depend on safetensors. The default test suite uses loopback
servers; the real Hub test is opt-in with `HF_HUB_TEST_NETWORK=1`.

## Lwt and Async usage

In a Lwt application:

```ocaml
let repo = Result.get_ok (Hf_hub.Repo_id.of_string "timm/mobilenetv2_050.lamb_in1k") in
Hf_hub_lwt.download ~repo ~filename:"config.json" ()
(* (Hf_hub.Blob.t, Hf_hub.Error.t) result Lwt.t *)
```

In an Async application:

```ocaml
let repo = Result.get_ok (Hf_hub.Repo_id.of_string "timm/mobilenetv2_050.lamb_in1k") in
Hf_hub_async.download ~repo ~filename:"config.json" ()
(* (Hf_hub.Blob.t, Hf_hub.Error.t) result Async.Deferred.t *)
```

To use Cohttp with the blocking driver or mmap helper:

```ocaml
let env = Hf_hub_unix.Env.of_environment () in
let http = Hf_hub_lwt.blocking env in
Hf_hub_safetensors.open_mmap ~env ~http ~repo ~filename:"model.safetensors" ()
```

The blocking adapter calls `Lwt_main.run`; use the asynchronous API within an
existing Lwt event loop. Cache and SHA256 operations run in each scheduler's
thread pool. Applications sharing a cache must serialize concurrent writes
to the same blob, as with the Unix driver. The original CLI still uses curl.
