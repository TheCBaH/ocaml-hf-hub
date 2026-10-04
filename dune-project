(lang dune 3.17)
(name hf-hub)
(generate_opam_files true)
(source (github TheCBaH/ocaml-hf-hub))
(license MIT)
(authors "Vladimir N. Silyaev")
(maintainers "Vladimir N. Silyaev")
(package
 (name hf-hub)
 (synopsis "Sans-IO Hugging Face Hub file resolution and huggingface_hub-compatible cache")
 (description "A download is a step machine that asks its driver for HTTP and cache-store operations; the core does no IO.")
 (depends (ocaml (>= 4.14)) dune (ppx_expect :with-test)))
(package
 (name hf-hub-unix)
 (synopsis "Blocking Unix driver for hf-hub: curl transport, on-disk cache, CLI")
 (depends (ocaml (>= 4.14)) dune cmdliner (hf-hub (= :version))))
(package
 (name hf-hub-safetensors)
 (synopsis "Open a Hub safetensors checkpoint as a read-only mmap")
 (depends (ocaml (>= 4.14)) dune (hf-hub-unix (= :version)) safetensors-unix))
(package
 (name hf-hub-lwt)
 (synopsis "Lwt Hub driver using Cohttp and native OCaml TLS")
 (depends
  (ocaml (>= 4.14))
  dune
  (hf-hub-unix (= :version))
  (cohttp-lwt-unix (>= 6.2.1))
  conduit-lwt
  conduit-lwt-unix
  lwt
  tls-lwt
  uri))
(package
 (name hf-hub-async)
 (synopsis "Async Hub driver using h2 and native OCaml TLS")
 (depends
  (ocaml (>= 4.14))
  dune
  (hf-hub-unix (= :version))
  async
  bigstringaf
  ca-certs
  core
  domain-name
  (h2-async (>= 0.13.0))
  (h2-lwt-unix :with-test)
  tls-async
  uri))
