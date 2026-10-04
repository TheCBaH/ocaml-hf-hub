type t = {
  commit : string;
  etag : string;
  sha256 : string option;
  size : int64 option;
}

let is_hex64 s =
  String.length s = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

(* [W/"abc"] and ["abc"] both name the content [abc]. *)
let normalize_etag s =
  let s = String.trim s in
  let s =
    if String.length s > 2 && String.sub s 0 2 = "W/" then
      String.sub s 2 (String.length s - 2)
    else s
  in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

(* The etag becomes a file name in the cache, so it is constrained. *)
let safe_etag s =
  s <> ""
  && String.length s <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true | _ -> false)
       s

let of_response url (r : Response.Received.t) =
  if r.status < 200 || r.status >= 400 then
    Error (Error.Http_status { status = r.status; url })
  else
    let ( let* ) = Result.bind in
    let get = Response.header r in
    let* commit =
      match get "X-Repo-Commit" with
      | None -> Error (Error.Missing_header "X-Repo-Commit")
      | Some c when Revision.is_commit c -> Ok c
      | Some value ->
          Error (Error.Invalid_header { name = "X-Repo-Commit"; value })
    in
    let linked = get "X-Linked-Etag" in
    let* etag_name, raw =
      match (linked, get "ETag") with
      | Some v, _ -> Ok ("X-Linked-Etag", v)
      | None, Some v -> Ok ("ETag", v)
      | None, None -> Error (Error.Missing_header "ETag")
    in
    let etag = normalize_etag raw in
    let* () =
      if safe_etag etag then Ok ()
      else Error (Error.Invalid_header { name = etag_name; value = raw })
    in
    let size_name, size_raw =
      match get "X-Linked-Size" with
      | Some v -> ("X-Linked-Size", Some v)
      | None ->
          (* On a redirect, Content-Length is the size of the redirect's own
             body, not of the file. *)
          ( "Content-Length",
            if r.status = 200 then get "Content-Length" else None )
    in
    let* size =
      match size_raw with
      | None -> Ok None
      | Some v -> (
          match Int64.of_string_opt v with
          | Some n when n >= 0L -> Ok (Some n)
          | _ -> Error (Error.Invalid_header { name = size_name; value = v }))
    in
    let sha256 = if is_hex64 etag && linked <> None then Some etag else None in
    Ok { commit; etag; sha256; size }
