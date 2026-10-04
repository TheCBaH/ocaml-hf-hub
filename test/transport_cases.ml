open Hf_hub

let repo = Result.get_ok (Repo_id.of_string "test/model")
let etag = "test-blob"
let commit = "0123456789abcdef0123456789abcdef01234567"

let response ~endpoint meth path headers =
  let header name = List.assoc_opt name headers in
  let metadata =
    [ ("x-repo-commit", commit); ("etag", etag); ("content-length", "5") ]
  in
  match (meth, path) with
  | `HEAD, "/head" | `HEAD, "/test/model/resolve/main/file" ->
      (302, ("location", "/ok") :: metadata, "")
  | _, "/relative" -> (307, [ ("location", "/ok") ], "redirect body")
  | _, "/cross" ->
      let uri =
        Uri.of_string endpoint |> fun u ->
        Uri.with_host u (Some "localhost") |> fun u -> Uri.with_path u "/auth"
      in
      (302, [ ("location", Uri.to_string uri) ], "")
  | _, "/loop" -> (302, [ ("location", "/loop") ], "")
  | _, "/missing-location" -> (302, [], "")
  | _, "/bad-scheme" -> (302, [ ("location", "file:///etc/passwd") ], "")
  | _, "/auth" ->
      (200, [], if header "authorization" = None then "public" else "secret")
  | _, "/resume" ->
      assert (header "range" = Some "bytes=2-");
      (206, [ ("content-range", "bytes 2-4/5") ], "llo")
  | _, "/wrong-range" -> (206, [ ("content-range", "bytes 1-4/5") ], "ello")
  | _, "/no-range" -> (206, [], "llo")
  | _, "/ignored-range" -> (200, [], "hello")
  | _, "/missing" -> (404, [], "error page")
  | _, "/test/model/resolve/main/file" | _, "/ok" -> (200, [], "hello")
  | _ -> (500, [], "unexpected request")

let rec remove path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun entry -> remove (Filename.concat path entry))
        (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let cache ~endpoint () =
  let path = Filename.temp_file "hf-hub-http-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Env.make ~cache_dir:path ~endpoint ~token:"secret-token" ()

let sink_path env =
  Cache_layout.incomplete_path ~root:env.Env.cache_dir repo ~etag

let read path = In_channel.with_open_bin path In_channel.input_all

let cases env =
  let head path =
    Request.Head { url = env.Env.endpoint ^ path; headers = [] }
  in
  let get ?(offset = 0L) path =
    Request.Get
      {
        url = env.endpoint ^ path;
        resume_from = offset;
        headers = [ ("authorization", "Bearer secret-token") ];
        sink = { repo; etag };
      }
  in
  let received expected = function
    | Response.Received { status; _ } -> assert (status = expected)
    | Transport_error message -> failwith message
  in
  let transport_error = function
    | Response.Transport_error _ -> ()
    | _ -> failwith "expected transport failure"
  in
  let body request expected =
    ( request,
      "old",
      fun reply ->
        received 200 reply;
        assert (read (sink_path env) = expected) )
  in
  let rejected request =
    ( request,
      "he",
      fun reply ->
        transport_error reply;
        assert (read (sink_path env) = "he") )
  in
  [
    ( head "/head",
      "keep",
      fun reply ->
        received 302 reply;
        assert (read (sink_path env) = "keep") );
    body (get "/ok") "hello";
    body (get "/relative") "hello";
    body (get "/cross") "public";
    ( get ~offset:2L "/resume",
      "he",
      fun reply ->
        received 206 reply;
        assert (read (sink_path env) = "hello") );
    rejected (get ~offset:2L "/wrong-range");
    rejected (get ~offset:2L "/no-range");
    rejected (get ~offset:2L "/ignored-range");
    rejected (get "/loop");
    rejected (get "/missing-location");
    rejected (get "/bad-scheme");
    rejected (get "/slow");
    ( get "/missing",
      "keep",
      fun reply ->
        received 404 reply;
        assert (read (sink_path env) = "keep") );
  ]

let prepare env (request, initial, _) =
  Hf_hub_unix.prepare_http env request;
  let path = sink_path env in
  Hf_hub_unix.prepare_http env
    (Request.Get
       { url = ""; headers = []; resume_from = 0L; sink = { repo; etag } });
  Out_channel.with_open_bin path (fun output -> output_string output initial)

let check_download = function
  | Error error -> Format.kasprintf failwith "%a" Error.pp error
  | Ok blob -> assert (read blob.Blob.path = "hello")
