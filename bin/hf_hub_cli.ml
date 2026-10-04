open Cmdliner

let fail fmt = Format.kasprintf (fun s -> Error s) fmt

let download repo filename revision kind =
  let ( let* ) = Result.bind in
  let pp e = Format.asprintf "%a" Hf_hub.Error.pp e in
  let* repo = Hf_hub.Repo_id.of_string ~kind repo |> Result.map_error pp in
  let* revision =
    match revision with
    | None -> Ok None
    | Some r ->
        Hf_hub.Revision.of_string r
        |> Result.map (fun r -> Some r)
        |> Result.map_error pp
  in
  match Hf_hub_unix.download ?revision ~repo ~filename () with
  | Ok blob ->
      print_endline blob.Hf_hub.Blob.path;
      Ok ()
  | Error e -> fail "%a" Hf_hub.Error.pp e

let repo =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"REPO"
        ~doc:"Repository id, e.g. timm/mobilenetv2_050.lamb_in1k.")

let file =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~docv:"FILE" ~doc:"Path of the file inside the repository.")

let revision =
  Arg.(
    value
    & opt (some string) None
    & info [ "revision" ] ~docv:"REV"
        ~doc:"Branch, tag or commit sha (default: main).")

let kind =
  Arg.(
    value
    & opt
        (enum
           [
             ("dataset", Hf_hub.Repo_id.Kind.Dataset);
             ("model", Hf_hub.Repo_id.Kind.Model);
             ("space", Hf_hub.Repo_id.Kind.Space);
           ])
        Hf_hub.Repo_id.Kind.Model
    & info [ "repo-type" ] ~docv:"KIND" ~doc:"model, dataset or space.")

let cmd =
  Cmd.v
    (Cmd.info "download"
       ~doc:
         "Download one file into the huggingface_hub cache and print its path.")
    Term.(term_result' (const download $ repo $ file $ revision $ kind))

let () = exit (Cmd.eval cmd)
