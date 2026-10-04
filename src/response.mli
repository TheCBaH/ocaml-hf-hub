module Received : sig
  type t = { headers : (string * string) list; status : int }
end

type t =
  | Received of Received.t  (** The server answered, whatever the status. *)
  | Transport_error of string  (** No answer: DNS, TLS, timeout, ... *)

val header : Received.t -> string -> string option
(** Case-insensitive; the value is trimmed. *)
