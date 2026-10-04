open Hub

let optional = function "" -> None | s -> Some s
let field = Option.value ~default:""

let rec pairs = function
  | [] -> []
  | k :: v :: rest -> (k, v) :: pairs rest
  | _ -> invalid_arg "odd number of header fields"

let http env request callback =
  let meth, url, headers, path, resume =
    match request with
    | Request.Head { url; headers } -> ("HEAD", url, headers, "", "0")
    | Get { url; headers; resume_from; sink } ->
        ( "GET",
          url,
          headers,
          Cache_layout.incomplete_path ~root:env.Env.cache_dir sink.repo
            ~etag:sink.etag,
          Int64.to_string resume_from )
  in
  let headers = List.concat_map (fun (k, v) -> [ k; v ]) headers in
  Runtime.call "http"
    (Array.of_list ([ meth; url; path; resume ] @ headers))
    (fun reply ->
      let response =
        match Array.to_list reply with
        | "received" :: status :: headers ->
            Response.Received
              { status = int_of_string status; headers = pairs headers }
        | [ "error"; message ] -> Response.Transport_error message
        | _ -> Response.Transport_error "invalid JavaScript HTTP reply"
      in
      callback response)

let store env op callback =
  let root = env.Env.cache_dir in
  let blob repo etag = Cache_layout.blob_path ~root repo ~etag in
  let partial repo etag = Cache_layout.incomplete_path ~root repo ~etag in
  let name, args =
    match op with
    | Store.Op.Find_ref { repo; ref_ } ->
        ("ref", [| Cache_layout.ref_path ~root repo ~ref_ |])
    | Find_snapshot { repo; commit; filename; etag } ->
        ( "snapshot",
          [|
            Cache_layout.snapshot_path ~root repo ~commit ~filename; field etag;
          |] )
    | Find_blob { repo; etag } ->
        ("blob", [| blob repo etag; partial repo etag |])
    | Check_blob { repo; etag; sha256; size } ->
        ( "check",
          [|
            partial repo etag;
            field sha256;
            field (Option.map Int64.to_string size);
          |] )
    | Discard_partial { repo; etag } -> ("discard", [| partial repo etag |])
    | Commit { repo; commit; etag; filename; ref_ } ->
        ( "commit",
          [|
            blob repo etag;
            partial repo etag;
            Cache_layout.snapshot_path ~root repo ~commit ~filename;
            Cache_layout.symlink_target ~filename ~etag;
            field
              (Option.map
                 (fun ref_ -> Cache_layout.ref_path ~root repo ~ref_)
                 ref_);
            commit;
            etag;
          |] )
  in
  Runtime.call name args (fun response ->
      let reply =
        match (op, Array.to_list response) with
        | _, [ "error"; message ] -> Store.Store_error message
        | Find_ref _, [ "ref"; commit ] -> Store.Ref (optional commit)
        | Find_snapshot _, [ "absent" ] -> Store.Snapshot Absent
        | Find_snapshot _, [ "present"; etag ] ->
            Store.Snapshot (Present { etag = optional etag })
        | Find_blob _, [ "absent" ] -> Store.Blob_state Absent
        | Find_blob _, [ "complete" ] -> Store.Blob_state Complete
        | Find_blob _, [ "partial"; size ] ->
            Store.Blob_state (Partial (Int64.of_string size))
        | Check_blob _, [ "verified" ] -> Store.Check Verified
        | Check_blob { size = Some expected; _ }, [ "size-mismatch"; actual ] ->
            Store.Check
              (Mismatch
                 (Error.Size_mismatch
                    { actual = Int64.of_string actual; expected }))
        | Check_blob { sha256 = Some expected; _ }, [ "sha-mismatch"; actual ]
          ->
            Store.Check (Mismatch (Error.Sha256_mismatch { actual; expected }))
        | (Discard_partial _ | Commit _), [ "stored" ] -> Store.Stored
        | _ -> Store.Store_error "invalid JavaScript store reply"
      in
      callback reply)

let run env step callback =
  let rec go = function
    | Download.Done result -> callback result
    | Need_http (request, next) ->
        http env request (fun reply -> go (next reply))
    | Need_store (op, next) -> store env op (fun reply -> go (next reply))
  in
  go step

let download args callback =
  let report = function
    | Ok (blob : Blob.t) ->
        callback [| "ok"; blob.path; blob.commit; field blob.etag |]
    | Error error -> callback [| "error"; Format.asprintf "%a" Error.pp error |]
  in
  match Array.to_list args with
  | [ cache_dir; endpoint; offline; token; repo_id; filename; revision; kind ]
    -> (
      let kind =
        match kind with
        | "model" -> Some Repo_id.Kind.Model
        | "dataset" -> Some Dataset
        | "space" -> Some Space
        | _ -> None
      in
      match kind with
      | None ->
          callback [| "error"; "repo type must be model, dataset or space" |]
      | Some kind -> (
          match
            (Repo_id.of_string ~kind repo_id, Revision.of_string revision)
          with
          | Error error, _ | _, Error error -> report (Error error)
          | Ok repo, Ok revision ->
              let env =
                Env.make ~cache_dir ~endpoint ~offline:(offline = "true")
                  ?token:(optional token) ()
              in
              run env (Download.start env ~repo ~revision ~filename ()) report))
  | _ -> callback [| "error"; "invalid JavaScript download options" |]
