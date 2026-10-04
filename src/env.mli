(** Everything a download needs to know about its surroundings. The core reads
    no environment variables; a driver builds this (see [Hf_hub_unix.Env]). *)

type t = {
  cache_dir : string;  (** The hub cache: holds the [models--*] folders. *)
  endpoint : string;  (** No trailing slash. *)
  offline : bool;  (** Answer from the cache only; never emit [Need_http]. *)
  token : string option;
}

val default_endpoint : string

val make :
  cache_dir:string ->
  ?endpoint:string ->
  ?offline:bool ->
  ?token:string ->
  unit ->
  t
