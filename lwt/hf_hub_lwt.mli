(** Cohttp/Lwt HTTP transport with native OCaml TLS and system trust roots.
    Bodies stream to disk; HEAD keeps Hub metadata redirects visible. *)

type http = Hf_hub.Request.t -> Hf_hub.Response.t Lwt.t

val cohttp : ?timeout:float -> ?max_redirects:int -> Hf_hub.Env.t -> http
(** [timeout] defaults to 60 seconds per request including redirects and body
    streaming. [max_redirects] defaults to 10. GET follows HTTP(S) redirects,
    dropping credentials on an origin change and refusing HTTPS downgrades. A
    resumed GET must return a matching Content-Range before it can append.
    Cancellation propagates to the caller. *)

val blocking :
  ?timeout:float -> ?max_redirects:int -> Hf_hub.Env.t -> Hf_hub_unix.http
(** Adapter for [Hf_hub_unix.download] and [Hf_hub_safetensors.open_mmap]. Runs
    [Lwt_main.run]; use {!download} within an existing Lwt event loop. *)

val run :
  ?http:http ->
  ?hasher:Hf_hub_unix.hasher ->
  Hf_hub.Env.t ->
  Hf_hub.Download.step ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result Lwt.t
(** Drive the core asynchronously; blocking cache and hashing operations run in
    Lwt's worker pool. Concurrent writes to the same cache blob require caller
    synchronization, as with the blocking driver. *)

val download :
  ?env:Hf_hub.Env.t ->
  ?http:http ->
  ?hasher:Hf_hub_unix.hasher ->
  ?revision:Hf_hub.Revision.t ->
  repo:Hf_hub.Repo_id.t ->
  filename:string ->
  unit ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result Lwt.t
