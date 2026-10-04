(** A download as a step machine: the core never performs IO, it returns what it
    needs next and a continuation for the answer. A driver loops until [Done],
    in whatever effect model suits it (blocking, [Promise], ...).

    Online: HEAD the resolve URL for [commit]/[etag]/[size]/[sha256]; if the
    snapshot already links that blob, done; otherwise reuse a complete blob, or
    GET into [blobs/<etag>.incomplete] (resuming a partial one), verify, then
    commit (rename, symlink, [refs/]). A commit-sha revision already in the
    cache is answered with no request, and an unreachable Hub falls back to the
    cache. [env.offline] never emits [Need_http]. *)

type step =
  | Done of (Blob.t, Error.t) result
  | Need_http of Request.t * (Response.t -> step)
  | Need_store of Store.Op.t * (Store.reply -> step)

val start :
  Env.t ->
  repo:Repo_id.t ->
  ?revision:Revision.t ->
  filename:string ->
  unit ->
  step
(** [revision] defaults to [Revision.main]. *)

val resolve_url : Env.t -> Repo_id.t -> Revision.t -> filename:string -> string
