type step =
  | Done of (Blob.t, Error.t) result
  | Need_http of Request.t * (Response.t -> step)
  | Need_store of Store.Op.t * (Store.reply -> step)

let user_agent = "hf-hub-ocaml/0"

(* Percent-encode a path segment; [/] is encoded too, which is what a branch
   name such as [refs/pr/1] needs in a resolve URL. *)
let encode_segment s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~') as c ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let resolve_url (env : Env.t) repo revision ~filename =
  let file =
    String.concat "/"
      (List.map encode_segment (String.split_on_char '/' filename))
  in
  Printf.sprintf "%s/%s%s/resolve/%s/%s" env.endpoint
    (Repo_id.Kind.url_prefix (Repo_id.kind repo))
    (Repo_id.id repo)
    (encode_segment (Revision.to_string revision))
    file

let headers (env : Env.t) =
  let base = [ ("User-Agent", user_agent); ("Accept-Encoding", "identity") ] in
  match env.token with
  | None -> base
  | Some t -> ("Authorization", "Bearer " ^ t) :: base

let unexpected = Done (Error (Error.Store "unexpected reply from the store"))

let start (env : Env.t) ~repo ?(revision = Revision.main) ~filename () =
  match Cache_layout.check_filename filename with
  | Error e -> Done (Error e)
  | Ok () -> (
      let root = env.cache_dir in
      let blob ~commit ~etag =
        {
          Blob.commit;
          etag;
          path = Cache_layout.snapshot_path ~root repo ~commit ~filename;
        }
      in
      let ask op k = Need_store (op, k) in
      let offline_miss () =
        Error.Offline_miss
          {
            filename;
            repo = Repo_id.id repo;
            revision = Revision.to_string revision;
          }
      in
      (* Resolve without the network: [on_miss] is what a miss means here. *)
      let from_cache ~on_miss =
        let lookup commit =
          ask
            (Store.Op.Find_snapshot { commit; etag = None; filename; repo })
            (function
              | Store.Snapshot (Present { etag }) ->
                  Done (Ok (blob ~commit ~etag))
              | Snapshot Absent -> Done (Error on_miss)
              | Store_error m -> Done (Error (Error.Store m))
              | _ -> unexpected)
        in
        match revision with
        | Commit commit -> lookup commit
        | Ref ref_ ->
            ask
              (Store.Op.Find_ref { ref_; repo })
              (function
                | Store.Ref (Some commit) -> lookup commit
                | Ref None -> Done (Error on_miss)
                | Store_error m -> Done (Error (Error.Store m))
                | _ -> unexpected)
      in
      let url = resolve_url env repo revision ~filename in
      let finish (m : Metadata.t) =
        ask
          (Store.Op.Commit
             {
               commit = m.commit;
               etag = m.etag;
               filename;
               ref_ = (match revision with Ref r -> Some r | Commit _ -> None);
               repo;
             })
          (function
            | Store.Stored ->
                Done (Ok (blob ~commit:m.commit ~etag:(Some m.etag)))
            | Store_error e -> Done (Error (Error.Store e))
            | _ -> unexpected)
      in
      (* [fresh] records that the download already started from byte 0, so a
         failure after it is final rather than worth one more try. *)
      let rec download (m : Metadata.t) ~resume_from ~fresh =
        let restart () =
          ask
            (Store.Op.Discard_partial { etag = m.etag; repo })
            (function
              | Store.Stored -> download m ~resume_from:0L ~fresh:true
              | Store_error e -> Done (Error (Error.Store e))
              | _ -> unexpected)
        in
        let fail e =
          ask
            (Store.Op.Discard_partial { etag = m.etag; repo })
            (fun _ -> Done (Error e))
        in
        Need_http
          ( Get
              {
                headers = headers env;
                resume_from;
                sink = { etag = m.etag; repo };
                url;
              },
            function
            | Response.Transport_error e ->
                if fresh then Done (Error (Error.Transport e)) else restart ()
            | Received { status; _ }
              when status = 200 || status = 206
                   || (status = 416 && resume_from > 0L) ->
                ask
                  (Store.Op.Check_blob
                     { etag = m.etag; repo; sha256 = m.sha256; size = m.size })
                  (function
                    | Store.Check Verified -> finish m
                    | Check (Mismatch e) -> if fresh then fail e else restart ()
                    | Store_error e -> Done (Error (Error.Store e))
                    | _ -> unexpected)
            | Received { status; _ } ->
                Done (Error (Error.Http_status { status; url })) )
      in
      let with_metadata (m : Metadata.t) =
        ask
          (Store.Op.Find_snapshot
             { commit = m.commit; etag = Some m.etag; filename; repo })
          (function
            | Store.Snapshot (Present _) -> finish m
            | Snapshot Absent ->
                ask
                  (Store.Op.Find_blob { etag = m.etag; repo })
                  (function
                    | Store.Blob_state Complete -> finish m
                    | Blob_state (Partial n) ->
                        download m ~resume_from:n ~fresh:false
                    | Blob_state Absent ->
                        download m ~resume_from:0L ~fresh:true
                    | Store_error e -> Done (Error (Error.Store e))
                    | _ -> unexpected)
            | Store_error e -> Done (Error (Error.Store e))
            | _ -> unexpected)
      in
      let online () =
        Need_http
          ( Head { headers = headers env; url },
            function
            | Response.Transport_error e ->
                (* Like huggingface_hub: an unreachable Hub falls back to the
                   cache; the error survives only if the cache has no answer. *)
                from_cache ~on_miss:(Error.Transport e)
            | Received r -> (
                match Metadata.of_response url r with
                | Ok m -> with_metadata m
                | Error e -> Done (Error e)) )
      in
      if env.offline then from_cache ~on_miss:(offline_miss ())
      else
        match revision with
        | Commit commit ->
            (* A commit's files never change, so a cached one needs no HEAD. *)
            ask
              (Store.Op.Find_snapshot { commit; etag = None; filename; repo })
              (function
                | Store.Snapshot (Present { etag }) ->
                    Done (Ok (blob ~commit ~etag))
                | Snapshot Absent -> online ()
                | Store_error e -> Done (Error (Error.Store e))
                | _ -> unexpected)
        | Ref _ -> online ())
