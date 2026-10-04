type t = Commit of string | Ref of string

let is_commit s =
  String.length s = 40
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let valid_ref s =
  s <> ""
  && List.for_all
       (fun seg ->
         seg <> "" && seg <> "." && seg <> ".."
         && String.for_all
              (function
                | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' | '+'
                  ->
                    true
                | _ -> false)
              seg)
       (String.split_on_char '/' s)

let of_string s =
  if is_commit s then Ok (Commit s)
  else if valid_ref s then Ok (Ref s)
  else Error (Error.Invalid_revision s)

let main = Ref "main"
let to_string = function Commit s | Ref s -> s
