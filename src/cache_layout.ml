let join = List.fold_left Filename.concat ""

let check_filename f =
  let ok =
    f <> ""
    && (not (String.contains f '\\'))
    && List.for_all
         (fun seg -> seg <> "" && seg <> "." && seg <> "..")
         (String.split_on_char '/' f)
  in
  if ok then Ok () else Error (Error.Invalid_filename f)

let repo_dir ~root repo = Filename.concat root (Repo_id.folder_name repo)
let blob_path ~root repo ~etag = join [ repo_dir ~root repo; "blobs"; etag ]

let incomplete_path ~root repo ~etag =
  blob_path ~root repo ~etag ^ ".incomplete"

let snapshot_dir ~root repo ~commit =
  join [ repo_dir ~root repo; "snapshots"; commit ]

let snapshot_path ~root repo ~commit ~filename =
  Filename.concat (snapshot_dir ~root repo ~commit) filename

let ref_path ~root repo ~ref_ = join [ repo_dir ~root repo; "refs"; ref_ ]

let symlink_target ~filename ~etag =
  let depth = List.length (String.split_on_char '/' filename) - 1 in
  String.concat "/" (List.init (depth + 2) (fun _ -> "..")) ^ "/blobs/" ^ etag
