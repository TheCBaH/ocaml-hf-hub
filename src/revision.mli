(** What to resolve: a commit sha (immutable, answerable from the cache alone)
    or a branch/tag name (needs the network, or [refs/], to find its commit). *)

type t = Commit of string | Ref of string

val of_string : string -> (t, Error.t) result
(** Forty lowercase hex digits is a [Commit]; any other safe path-like name is a
    [Ref], which may contain [/] ([refs/pr/1]). *)

val main : t
val to_string : t -> string
val is_commit : string -> bool
