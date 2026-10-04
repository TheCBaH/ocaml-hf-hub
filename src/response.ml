module Received = struct
  type t = { headers : (string * string) list; status : int }
end

type t = Received of Received.t | Transport_error of string

let header (r : Received.t) name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (k, v) ->
      if String.lowercase_ascii k = name then Some (String.trim v) else None)
    r.headers
