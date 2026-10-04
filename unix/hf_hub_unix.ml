open Hf_hub

let getenv name =
  match Sys.getenv_opt name with None | Some "" -> None | Some v -> Some v

let first_env names = List.find_map getenv names

let read_file path =
  try Some (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error _ -> None

module Env = struct
  let of_environment () =
    let home =
      match getenv "HF_HOME" with
      | Some h -> h
      | None ->
          let cache =
            match getenv "XDG_CACHE_HOME" with
            | Some c -> c
            | None ->
                Filename.concat
                  (Option.value (getenv "HOME") ~default:".")
                  ".cache"
          in
          Filename.concat cache "huggingface"
    in
    let cache_dir =
      match first_env [ "HF_HUB_CACHE"; "HUGGINGFACE_HUB_CACHE" ] with
      | Some d -> d
      | None -> Filename.concat home "hub"
    in
    let token =
      match first_env [ "HF_TOKEN"; "HUGGING_FACE_HUB_TOKEN" ] with
      | Some _ as t -> t
      | None ->
          Option.bind
            (read_file (Filename.concat home "token"))
            (fun s -> match String.trim s with "" -> None | t -> Some t)
    in
    let offline =
      match getenv "HF_HUB_OFFLINE" with
      | Some v ->
          List.mem (String.lowercase_ascii v) [ "1"; "true"; "yes"; "on" ]
      | None -> false
    in
    Hf_hub.Env.make ~cache_dir ?endpoint:(getenv "HF_ENDPOINT") ~offline ?token
      ()
end

type http = Request.t -> Response.t
type hasher = string -> (string, string) result

(* ---- subprocesses ---- *)

let run_capture prog args =
  match Unix.open_process_args_in prog (Array.of_list (prog :: args)) with
  | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
  | ic -> (
      let out = In_channel.input_all ic in
      match Unix.close_process_in ic with
      | Unix.WEXITED code -> Ok (code, out)
      | Unix.WSIGNALED s | Unix.WSTOPPED s ->
          Error (Printf.sprintf "%s killed by signal %d" prog s))

let is_hex64 s =
  String.length s = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let sha256sum path =
  let attempt prog args =
    match run_capture prog (args @ [ path ]) with
    | Ok (0, out) when String.length out >= 64 ->
        let h = String.lowercase_ascii (String.sub out 0 64) in
        if is_hex64 h then Some h else None
    | _ -> None
  in
  match attempt "sha256sum" [ "--" ] with
  | Some h -> Ok h
  | None -> (
      match attempt "shasum" [ "-a"; "256"; "--" ] with
      | Some h -> Ok h
      | None -> Error "neither sha256sum nor shasum produced a digest")

let rec mkdir_p dir =
  if dir <> "" && dir <> "/" && dir <> "." && not (Sys.file_exists dir) then (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

(* Headers go in a 0600 curl config file, not argv, so a token never shows in
   [ps]. *)
let with_config headers f =
  let path =
    Filename.temp_file
      ~temp_dir:(Filename.get_temp_dir_name ())
      "hf-hub-" ".curl"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      Unix.chmod path 0o600;
      let esc s =
        let b = Buffer.create (String.length s) in
        String.iter
          (fun c ->
            if c = '"' || c = '\\' then Buffer.add_char b '\\';
            Buffer.add_char b c)
          s;
        Buffer.contents b
      in
      Out_channel.with_open_bin path (fun oc ->
          List.iter
            (fun (k, v) ->
              Printf.fprintf oc "header = \"%s: %s\"\n" (esc k) (esc v))
            headers);
      f path)

(* The last header block of [curl -I] output: earlier ones are 100-continue or
   proxy preambles. *)
let parse_head out =
  let lines =
    String.split_on_char '\n' out
    |> List.map (fun l ->
        if String.ends_with ~suffix:"\r" l then
          String.sub l 0 (String.length l - 1)
        else l)
  in
  let blocks =
    List.fold_left
      (fun acc l ->
        match (l, acc) with
        | "", _ -> [] :: acc
        | l, cur :: rest -> (l :: cur) :: rest
        | l, [] -> [ [ l ] ])
      [ [] ] lines
    |> List.map List.rev
    |> List.filter (fun b -> b <> [])
  in
  match blocks with
  | [] -> None
  | last :: _ -> (
      match last with
      | status_line :: rest -> (
          match String.split_on_char ' ' status_line with
          | proto :: code :: _
            when String.length proto >= 4 && String.sub proto 0 4 = "HTTP" -> (
              match int_of_string_opt code with
              | None -> None
              | Some status ->
                  let headers =
                    List.filter_map
                      (fun l ->
                        match String.index_opt l ':' with
                        | None -> None
                        | Some i ->
                            Some
                              ( String.sub l 0 i,
                                String.trim
                                  (String.sub l (i + 1)
                                     (String.length l - i - 1)) ))
                      rest
                  in
                  Some { Response.Received.status; headers })
          | _ -> None)
      | [] -> None)

let curl (env : Hf_hub.Env.t) : http =
  ignore env;
  function
  | Request.Head { headers; url } ->
      with_config headers (fun cfg ->
          match
            run_capture "curl"
              [ "-sS"; "-I"; "--max-time"; "60"; "-K"; cfg; "--"; url ]
          with
          | Error m -> Response.Transport_error m
          | Ok (0, out) -> (
              match parse_head out with
              | Some r -> Response.Received r
              | None -> Response.Transport_error "unparseable HEAD response")
          | Ok (code, _) ->
              Response.Transport_error
                (Printf.sprintf "curl exited with %d" code))
  | Get { headers; resume_from; sink; url } ->
      let path =
        Cache_layout.incomplete_path ~root:env.cache_dir sink.repo
          ~etag:sink.etag
      in
      with_config headers (fun cfg ->
          let resume = if resume_from > 0L then [ "-C"; "-" ] else [] in
          (* [-f] keeps an error page out of the blob; [-w] still reports the
             status on failure, which is how a 404 is told from a dead
             network. *)
          match
            run_capture "curl"
              ([
                 "-sS"; "-L"; "-f"; "-K"; cfg; "-o"; path; "-w"; "%{http_code}";
               ]
              @ resume @ [ "--"; url ])
          with
          | Error m -> Response.Transport_error m
          | Ok (code, out) -> (
              match int_of_string_opt (String.trim out) with
              | Some status when (code = 0 || code = 22) && status > 0 ->
                  Response.Received { status; headers = [] }
              | _ ->
                  Response.Transport_error
                    (Printf.sprintf "curl exited with %d" code)))

(* ---- store ---- *)

let lstat_opt path =
  try Some (Unix.LargeFile.lstat path)
  with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None

let remove_if_exists path =
  try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let write_atomic path contents =
  mkdir_p (Filename.dirname path);
  let tmp = path ^ ".tmp" in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc contents);
  Unix.rename tmp path

let snapshot_etag path =
  match Unix.readlink path with
  | target -> Some (Filename.basename target)
  | exception Unix.Unix_error _ -> None

let store ~(hasher : hasher) (env : Hf_hub.Env.t) (op : Store.Op.t) :
    Store.reply =
  let root = env.cache_dir in
  try
    match op with
    | Find_snapshot { commit; etag; filename; repo } -> (
        let path = Cache_layout.snapshot_path ~root repo ~commit ~filename in
        match (lstat_opt path, etag) with
        | None, _ -> Snapshot Absent
        | Some _, None -> Snapshot (Present { etag = snapshot_etag path })
        | Some _, Some want ->
            if snapshot_etag path = Some want then
              Snapshot (Present { etag = Some want })
            else Snapshot Absent)
    | Find_ref { ref_; repo } -> (
        match read_file (Cache_layout.ref_path ~root repo ~ref_) with
        | Some s when Revision.is_commit (String.trim s) ->
            Ref (Some (String.trim s))
        | _ -> Ref None)
    | Find_blob { etag; repo } -> (
        match lstat_opt (Cache_layout.blob_path ~root repo ~etag) with
        | Some _ -> Blob_state Complete
        | None -> (
            match lstat_opt (Cache_layout.incomplete_path ~root repo ~etag) with
            | Some st when st.Unix.LargeFile.st_size > 0L ->
                Blob_state (Partial st.Unix.LargeFile.st_size)
            | _ -> Blob_state Absent))
    | Check_blob { etag; repo; sha256; size } -> (
        let path = Cache_layout.incomplete_path ~root repo ~etag in
        match lstat_opt path with
        | None -> Store_error "downloaded blob is missing"
        | Some st -> (
            let actual = st.Unix.LargeFile.st_size in
            match (size, sha256) with
            | Some expected, _ when expected <> actual ->
                Check (Mismatch (Error.Size_mismatch { actual; expected }))
            | _, None -> Check Verified
            | _, Some expected -> (
                match hasher path with
                | Error m -> Store_error m
                | Ok actual when actual = expected -> Check Verified
                | Ok actual ->
                    Check
                      (Mismatch (Error.Sha256_mismatch { actual; expected })))))
    | Discard_partial { etag; repo } ->
        remove_if_exists (Cache_layout.incomplete_path ~root repo ~etag);
        Stored
    | Commit { commit; etag; filename; ref_; repo } ->
        let blob = Cache_layout.blob_path ~root repo ~etag in
        let incomplete = Cache_layout.incomplete_path ~root repo ~etag in
        mkdir_p (Filename.dirname blob);
        if lstat_opt incomplete <> None then Unix.rename incomplete blob;
        let link = Cache_layout.snapshot_path ~root repo ~commit ~filename in
        mkdir_p (Filename.dirname link);
        let target = Cache_layout.symlink_target ~filename ~etag in
        (match Unix.readlink link with
        | t when t = target -> ()
        | _ ->
            remove_if_exists link;
            Unix.symlink target link
        | exception Unix.Unix_error ((Unix.ENOENT | Unix.EINVAL), _, _) ->
            remove_if_exists link;
            Unix.symlink target link);
        Option.iter
          (fun ref_ ->
            write_atomic (Cache_layout.ref_path ~root repo ~ref_) commit)
          ref_;
        Stored
  with
  | Unix.Unix_error (e, call, arg) ->
      Store_error (Printf.sprintf "%s(%s): %s" call arg (Unix.error_message e))
  | Sys_error m -> Store_error m

let run ?http ?(hasher = sha256sum) env step =
  let http = match http with Some h -> h | None -> curl env in
  let rec go : Download.step -> _ = function
    | Done r -> r
    | Need_http (req, k) ->
        (match req with
        | Get { sink; _ } ->
            mkdir_p
              (Filename.dirname
                 (Cache_layout.incomplete_path ~root:env.cache_dir sink.repo
                    ~etag:sink.etag))
        | Head _ -> ());
        go (k (http req))
    | Need_store (op, k) -> go (k (store ~hasher env op))
  in
  go step

let download ?env ?http ?hasher ?revision ~repo ~filename () =
  let env = match env with Some e -> e | None -> Env.of_environment () in
  run ?http ?hasher env (Download.start env ~repo ?revision ~filename ())

let sha256sum = sha256sum
