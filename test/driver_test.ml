open Hf_hub

let get = function
  | Ok x -> x
  | Error e -> Format.kasprintf failwith "%a" Error.pp e

let repo = get (Repo_id.of_string "o/m")
let commit = "0123456789abcdef0123456789abcdef01234567"
let content = "hello"

(* sha256 of "hello" *)
let sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

let temp_dir () =
  let d = Filename.temp_file "hf-hub-test-" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  d

let rec rm_rf p =
  match Unix.lstat p with
  | exception Unix.Unix_error _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun f -> rm_rf (Filename.concat p f)) (Sys.readdir p);
      Unix.rmdir p
  | _ -> Unix.unlink p

let with_cache ?offline f =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      f (Env.make ~cache_dir:dir ?offline ~endpoint:"https://hub" ()) dir)

let ls dir =
  let out = ref [] in
  let rec walk rel =
    let abs = if rel = "" then dir else Filename.concat dir rel in
    match Unix.lstat abs with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter
          (fun f -> walk (if rel = "" then f else Filename.concat rel f))
          (let a = Sys.readdir abs in
           Array.sort compare a;
           a)
    | { Unix.st_kind = Unix.S_LNK; _ } ->
        out := Printf.sprintf "%s -> %s" rel (Unix.readlink abs) :: !out
    | _ -> out := rel :: !out
  in
  walk "";
  List.iter print_endline (List.rev !out)

type server = {
  mutable body : string;
  mutable head_headers : (string * string) list;
  mutable fail_get : string option;  (** transport error on the next GET *)
  mutable log : string list;
}

let server () =
  {
    body = content;
    head_headers =
      [
        ("X-Repo-Commit", commit);
        ("X-Linked-Etag", "\"" ^ sha ^ "\"");
        ("X-Linked-Size", string_of_int (String.length content));
      ];
    fail_get = None;
    log = [];
  }

let http (s : server) (env : Env.t) : Hf_hub_unix.http = function
  | Request.Head { url; _ } ->
      s.log <- ("HEAD " ^ url) :: s.log;
      Response.Received { status = 200; headers = s.head_headers }
  | Get { url; resume_from; sink; _ } -> (
      s.log <- Printf.sprintf "GET %s from %Ld" url resume_from :: s.log;
      match s.fail_get with
      | Some m ->
          s.fail_get <- None;
          Response.Transport_error m
      | None ->
          let path =
            Cache_layout.incomplete_path ~root:env.cache_dir sink.repo
              ~etag:sink.etag
          in
          (* Honour the contract: write after [resume_from] bytes. *)
          let from = Int64.to_int resume_from in
          let flags = [ Open_wronly; Open_creat; Open_binary ] in
          let flags = if from = 0 then Open_trunc :: flags else flags in
          let oc = open_out_gen flags 0o644 path in
          seek_out oc from;
          output_string oc
            (String.sub s.body from (String.length s.body - from));
          close_out oc;
          Response.Received
            { status = (if from > 0 then 206 else 200); headers = [] })

let run ?(revision = Revision.main) ?(filename = "w.bin") s env =
  let r =
    Hf_hub_unix.download ~env ~http:(http s env) ~revision ~repo ~filename ()
  in
  List.iter print_endline (List.rev s.log);
  s.log <- [];
  match r with
  | Ok (b : Hf_hub.Blob.t) ->
      let short e = if String.length e > 8 then String.sub e 0 8 else e in
      Printf.printf "ok %s/%s (blob %s)\n"
        (short (Filename.basename (Filename.dirname b.path)))
        (Filename.basename b.path)
        (Option.fold ~none:"-" ~some:short b.etag)
  | Error e -> Format.printf "error: %a@." Error.pp e

let%expect_test "miss downloads, then hit still HEADs a branch" =
  with_cache (fun env dir ->
      let s = server () in
      run s env;
      ls dir;
      run s env);
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 0
    ok 01234567/w.bin (blob 2cf24dba)
    models--o--m/blobs/2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    models--o--m/refs/main
    models--o--m/snapshots/0123456789abcdef0123456789abcdef01234567/w.bin -> ../../blobs/2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    HEAD https://hub/o/m/resolve/main/w.bin
    ok 01234567/w.bin (blob 2cf24dba)
    |}]

let%expect_test "a pinned commit in the cache makes no request" =
  with_cache (fun env _ ->
      let s = server () in
      run s env;
      run ~revision:(Revision.Commit commit) s env;
      ignore s);
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 0
    ok 01234567/w.bin (blob 2cf24dba)
    ok 01234567/w.bin (blob 2cf24dba) |}]

let%expect_test "offline hit and offline miss" =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let online = Env.make ~cache_dir:dir ~endpoint:"https://hub" () in
      let offline = Env.make ~cache_dir:dir ~offline:true () in
      let s = server () in
      run ~filename:"w.bin" s offline;
      run ~filename:"w.bin" s online;
      run ~filename:"w.bin" s offline;
      run ~filename:"other.bin" s offline);
  [%expect
    {|
    error: w.bin@main of o/m is not in the cache and the network is off
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 0
    ok 01234567/w.bin (blob 2cf24dba)
    ok 01234567/w.bin (blob 2cf24dba)
    error: other.bin@main of o/m is not in the cache and the network is off |}]

let%expect_test "sha mismatch is refused and leaves no blob" =
  with_cache (fun env dir ->
      let s = server () in
      s.body <- "hellp";
      run s env;
      ls dir);
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 0
    error: sha256 mismatch: expected 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824, got fdd7585e08c4e2afd71dcabdb4636c89d557a3f42db9e2040c8bbd1708aa4ce7 |}]

let%expect_test "an interrupted download resumes" =
  with_cache (fun env dir ->
      let s = server () in
      (* A previous run left "hel" behind. *)
      let path = Cache_layout.incomplete_path ~root:dir repo ~etag:sha in
      let rec mk d =
        if not (Sys.file_exists d) then (
          mk (Filename.dirname d);
          Unix.mkdir d 0o755)
      in
      mk (Filename.dirname path);
      Out_channel.with_open_bin path (fun oc -> output_string oc "hel");
      run s env;
      ls dir);
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 3
    ok 01234567/w.bin (blob 2cf24dba)
    models--o--m/blobs/2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    models--o--m/refs/main
    models--o--m/snapshots/0123456789abcdef0123456789abcdef01234567/w.bin -> ../../blobs/2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 |}]

let%expect_test "an unreachable hub falls back to the cache" =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let env = Env.make ~cache_dir:dir ~endpoint:"https://hub" () in
      let s = server () in
      run s env;
      let dead : Hf_hub_unix.http =
       fun _ -> Response.Transport_error "no route"
      in
      let show = function
        | Ok (b : Hf_hub.Blob.t) ->
            print_endline ("ok " ^ Filename.basename b.path)
        | Error e -> Format.printf "error: %a@." Error.pp e
      in
      show (Hf_hub_unix.download ~env ~http:dead ~repo ~filename:"w.bin" ());
      show (Hf_hub_unix.download ~env ~http:dead ~repo ~filename:"other.bin" ()));
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 0
    ok 01234567/w.bin (blob 2cf24dba)
    ok w.bin
    error: transport: no route |}]

let%expect_test "a corrupt partial is discarded and fetched again from byte 0" =
  with_cache (fun env dir ->
      let s = server () in
      let path = Cache_layout.incomplete_path ~root:dir repo ~etag:sha in
      let rec mk d =
        if not (Sys.file_exists d) then (
          mk (Filename.dirname d);
          Unix.mkdir d 0o755)
      in
      mk (Filename.dirname path);
      Out_channel.with_open_bin path (fun oc -> output_string oc "xyz");
      run s env;
      print_endline
        (In_channel.with_open_bin
           (Cache_layout.blob_path ~root:dir repo ~etag:sha)
           In_channel.input_all));
  [%expect
    {|
    HEAD https://hub/o/m/resolve/main/w.bin
    GET https://hub/o/m/resolve/main/w.bin from 3
    GET https://hub/o/m/resolve/main/w.bin from 0
    ok 01234567/w.bin (blob 2cf24dba)
    hello |}]
