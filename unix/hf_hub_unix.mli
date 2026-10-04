(** Blocking driver: [curl] for HTTP, the filesystem for the cache, [sha256sum]
    (or [shasum -a 256]) for hashing. No opam dependency beyond [unix]. *)

module Env : sig
  val of_environment : unit -> Hf_hub.Env.t
  (** [HF_HUB_CACHE] (else [$HF_HOME/hub]); [HF_HOME] (else
      [$XDG_CACHE_HOME/huggingface] or [~/.cache/huggingface]); [HF_TOKEN] (else
      [$HF_HOME/token]); [HF_HUB_OFFLINE] ([1]/[true]/[yes]/[on]);
      [HF_ENDPOINT]. *)
end

type http = Hf_hub.Request.t -> Hf_hub.Response.t
(** Performs one request. A [Get] writes its body to
    [Hf_hub.Cache_layout.incomplete_path] of its sink, after [resume_from]
    bytes; {!run} has already created that file's directory. *)

type hasher = string -> (string, string) result
(** Lowercase hex sha256 of a file. *)

val curl : Hf_hub.Env.t -> http
val sha256sum : hasher

val prepare_http : Hf_hub.Env.t -> Hf_hub.Request.t -> unit
(** Create a GET sink's parent directory. *)

val store :
  hasher:hasher -> Hf_hub.Env.t -> Hf_hub.Store.Op.t -> Hf_hub.Store.reply
(** Filesystem operations shared by Unix drivers. *)

val run :
  ?http:http ->
  ?hasher:hasher ->
  Hf_hub.Env.t ->
  Hf_hub.Download.step ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result
(** Drive a step machine to completion. Defaults are {!curl} and {!sha256sum}.
*)

val download :
  ?env:Hf_hub.Env.t ->
  ?http:http ->
  ?hasher:hasher ->
  ?revision:Hf_hub.Revision.t ->
  repo:Hf_hub.Repo_id.t ->
  filename:string ->
  unit ->
  (Hf_hub.Blob.t, Hf_hub.Error.t) result
(** [env] defaults to {!Env.of_environment}. *)
