open Hf_hub

let get = function
  | Ok x -> x
  | Error e -> Format.kasprintf failwith "%a" Error.pp e

let repo = get (Repo_id.of_string "timm/mobilenetv2_050.lamb_in1k")

let%expect_test "repo ids" =
  List.iter
    (fun s ->
      match Repo_id.of_string s with
      | Ok r -> Printf.printf "%s -> %s\n" s (Repo_id.folder_name r)
      | Error e -> Format.printf "%s -> %a\n" s Error.pp e)
    [
      "timm/mobilenetv2_050.lamb_in1k";
      "gpt2";
      "a/b/c";
      "../x";
      "a/..";
      "";
      "a b/c";
    ];
  [%expect
    {|
    timm/mobilenetv2_050.lamb_in1k -> models--timm--mobilenetv2_050.lamb_in1k
    gpt2 -> models--gpt2
    a/b/c -> invalid repo id "a/b/c"
    ../x -> invalid repo id "../x"
    a/.. -> invalid repo id "a/.."
     -> invalid repo id ""
    a b/c -> invalid repo id "a b/c"
    |}]

let%expect_test "revisions" =
  List.iter
    (fun s ->
      match Revision.of_string s with
      | Ok (Commit c) -> Printf.printf "%s -> commit %s\n" s c
      | Ok (Ref r) -> Printf.printf "%s -> ref %s\n" s r
      | Error e -> Format.printf "%s -> %a\n" s Error.pp e)
    [
      "main";
      "refs/pr/1";
      "0123456789abcdef0123456789abcdef01234567";
      "0123456789ABCDEF0123456789abcdef01234567";
      "../x";
      "";
    ];
  [%expect
    {|
    main -> ref main
    refs/pr/1 -> ref refs/pr/1
    0123456789abcdef0123456789abcdef01234567 -> commit 0123456789abcdef0123456789abcdef01234567
    0123456789ABCDEF0123456789abcdef01234567 -> ref 0123456789ABCDEF0123456789abcdef01234567
    ../x -> invalid revision "../x"
     -> invalid revision ""
    |}]

let%expect_test "layout and urls" =
  let root = "/c" in
  let commit = "0123456789abcdef0123456789abcdef01234567" in
  print_endline (Cache_layout.blob_path ~root repo ~etag:"E");
  print_endline (Cache_layout.incomplete_path ~root repo ~etag:"E");
  print_endline
    (Cache_layout.snapshot_path ~root repo ~commit ~filename:"a/b.json");
  print_endline (Cache_layout.ref_path ~root repo ~ref_:"refs/pr/1");
  print_endline
    (Cache_layout.symlink_target ~filename:"m.safetensors" ~etag:"E");
  print_endline (Cache_layout.symlink_target ~filename:"a/b/c.bin" ~etag:"E");
  let env = Env.make ~cache_dir:root ~endpoint:"https://hub.example/" () in
  print_endline
    (Download.resolve_url env repo (Revision.Ref "refs/pr/1")
       ~filename:"a b/c.bin");
  let ds = get (Repo_id.of_string ~kind:Dataset "o/d") in
  print_endline (Download.resolve_url env ds Revision.main ~filename:"f");
  List.iter
    (fun f ->
      match Cache_layout.check_filename f with
      | Ok () -> Printf.printf "%S ok\n" f
      | Error e -> Format.printf "%a\n" Error.pp e)
    [ "x"; "a/b"; "../x"; "a//b"; "/x"; ""; "a\\b" ];
  [%expect
    {|
    /c/models--timm--mobilenetv2_050.lamb_in1k/blobs/E
    /c/models--timm--mobilenetv2_050.lamb_in1k/blobs/E.incomplete
    /c/models--timm--mobilenetv2_050.lamb_in1k/snapshots/0123456789abcdef0123456789abcdef01234567/a/b.json
    /c/models--timm--mobilenetv2_050.lamb_in1k/refs/refs/pr/1
    ../../blobs/E
    ../../../../blobs/E
    https://hub.example/timm/mobilenetv2_050.lamb_in1k/resolve/refs%2Fpr%2F1/a%20b/c.bin
    https://hub.example/datasets/o/d/resolve/main/f
    "x" ok
    "a/b" ok
    invalid file name "../x"
    invalid file name "a//b"
    invalid file name "/x"
    invalid file name ""
    invalid file name "a\\b"
    |}]

let sha = String.make 64 'a'
let commit = "0123456789abcdef0123456789abcdef01234567"
let received status headers = { Response.Received.status; headers }

let show label r =
  match Metadata.of_response "u" r with
  | Ok m ->
      Printf.printf "%s: commit=%s etag=%s sha256=%s size=%s\n" label
        (String.sub m.commit 0 7) m.etag
        (match m.sha256 with Some _ -> "yes" | None -> "no")
        (match m.size with Some n -> Int64.to_string n | None -> "-")
  | Error e -> Format.printf "%s: %a\n" label Error.pp e

let%expect_test "metadata" =
  show "lfs"
    (received 302
       [
         ("x-repo-commit", commit);
         ("X-Linked-ETag", "\"" ^ sha ^ "\"");
         ("ETag", "\"ignored\"");
         ("X-Linked-Size", "42");
         ("Content-Length", "7");
       ]);
  show "git"
    (received 200
       [
         ("X-Repo-Commit", commit);
         ("ETag", "W/\"deadbeef\"");
         ("Content-Length", "7");
       ]);
  show "redirect without linked size"
    (received 307
       [
         ("X-Repo-Commit", commit);
         ("X-Linked-ETag", "\"deadbeef\"");
         ("Content-Length", "264");
       ]);
  show "no commit" (received 200 [ ("ETag", "x") ]);
  show "no etag" (received 200 [ ("X-Repo-Commit", commit) ]);
  show "bad etag"
    (received 200 [ ("X-Repo-Commit", commit); ("ETag", "\"../x\"") ]);
  show "bad size"
    (received 200
       [ ("X-Repo-Commit", commit); ("ETag", "x"); ("Content-Length", "-1") ]);
  show "404" (received 404 []);
  [%expect
    {|
    lfs: commit=0123456 etag=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa sha256=yes size=42
    git: commit=0123456 etag=deadbeef sha256=no size=7
    redirect without linked size: commit=0123456 etag=deadbeef sha256=no size=-
    no commit: response lacks the X-Repo-Commit header
    no etag: response lacks the ETag header
    bad etag: invalid ETag header "\"../x\""
    bad size: invalid Content-Length header "-1"
    404: HTTP 404 for u
    |}]
