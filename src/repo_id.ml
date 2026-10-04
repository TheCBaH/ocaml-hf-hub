module Kind = struct
  type t = Dataset | Model | Space

  let folder_prefix = function
    | Dataset -> "datasets"
    | Model -> "models"
    | Space -> "spaces"

  let url_prefix = function
    | Dataset -> "datasets/"
    | Model -> ""
    | Space -> "spaces/"
end

type t = { id : string; kind : Kind.t }

let valid_segment s =
  s <> "" && s <> "." && s <> ".."
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       s

let of_string ?(kind = Kind.Model) id =
  let ok =
    match String.split_on_char '/' id with
    | [ name ] -> valid_segment name
    | [ owner; name ] -> valid_segment owner && valid_segment name
    | _ -> false
  in
  if ok then Ok { id; kind } else Error (Error.Invalid_repo_id id)

let id t = t.id
let kind t = t.kind

let folder_name t =
  String.concat "--" (Kind.folder_prefix t.kind :: String.split_on_char '/' t.id)
