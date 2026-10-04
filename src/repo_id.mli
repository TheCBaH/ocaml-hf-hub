(** A Hub repository: ["owner/name"] or a bare ["name"], of one kind. *)

module Kind : sig
  type t = Dataset | Model | Space

  val url_prefix : t -> string
  (** ["datasets/"], [""] or ["spaces/"]: the part of a resolve URL before the
      repo id. *)
end

type t

val of_string : ?kind:Kind.t -> string -> (t, Error.t) result
(** Each segment is non-empty, not [.]/[..], and made of letters, digits, [.],
    [_] and [-]; so an id can never escape the cache directory. *)

val id : t -> string
val kind : t -> Kind.t

val folder_name : t -> string
(** The huggingface_hub cache folder: [models--owner--name]. *)
