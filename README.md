# ocaml-hf-hub

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

Behaviour: a commit-sha revision already cached needs no request; an unreachable
Hub falls back to the cache; a partial `.incomplete` blob resumes; LFS files are
checked against their sha256 and size, and a corrupt resumed partial is discarded
and refetched once.

## Development

`vendor/` is an untracked link to a checkout of
[ocaml-safetensors](https://github.com/TheCBaH/ocaml-safetensors) on a branch
that has `Safetensors_unix.Mmap`. `dune runtest`; the network test runs only with
`HF_HUB_TEST_NETWORK=1`.
