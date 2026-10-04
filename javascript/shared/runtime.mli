val call : string -> string array -> (string array -> unit) -> unit
(** The host accepts and returns arrays of strings. Only this small binding
    differs between js_of_ocaml and Melange; the download policy stays in OCaml.
*)

val export : (string array -> (string array -> unit) -> unit) -> unit
