(** HTTP/2 driver using [h2-async] and authenticated native OCaml TLS. HTTPS
    requires ALPN [h2]; HTTP uses prior-knowledge HTTP/2 (h2c). HTTP/1-only
    endpoints are unsupported; use [hf-hub-lwt] for those. *)

type http = Hf_hub.Request.t -> Hf_hub.Response.t Async.Deferred.t

val h2 : ?timeout:float -> ?max_redirects:int -> Hf_hub.Env.t -> http
(** Defaults: 60 seconds for each complete request, 10 GET redirects. HEAD
    preserves metadata redirects. GET streams to disk and validates
    Content-Range before appending. Credentials are removed on origin changes;
    HTTPS downgrades are refused. Certificates and hostnames are checked against
    the system trust store (including [SSL_CERT_FILE]). *)

val run :
  ?http:http ->
  ?hasher:Hf_hub_unix.hasher ->
  Hf_hub.Env.t ->
  Hf_hub.Download.step ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result Async.Deferred.t
(** Cache and hashing operations run in Async's thread pool. Concurrent writes
    to the same cache blob require caller synchronization. *)

val download :
  ?env:Hf_hub.Env.t ->
  ?http:http ->
  ?hasher:Hf_hub_unix.hasher ->
  ?revision:Hf_hub.Revision.t ->
  repo:Hf_hub.Repo_id.t ->
  filename:string ->
  unit ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result Async.Deferred.t
