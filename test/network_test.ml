(* Hits the real Hub; runs only with HF_HUB_TEST_NETWORK=1. *)
let () =
  if Sys.getenv_opt "HF_HUB_TEST_NETWORK" <> Some "1" then
    print_endline "network test skipped (set HF_HUB_TEST_NETWORK=1)"
  else
    let dir = Filename.temp_file "hf-hub-net-" "" in
    Sys.remove dir;
    let env = Hf_hub.Env.make ~cache_dir:dir () in
    let repo =
      Result.get_ok (Hf_hub.Repo_id.of_string "timm/mobilenetv2_050.lamb_in1k")
    in
    let fetch () = Hf_hub_unix.download ~env ~repo ~filename:"config.json" () in
    let show = function
      | Ok (b : Hf_hub.Blob.t) -> b.path
      | Error e -> Format.kasprintf failwith "%a" Hf_hub.Error.pp e
    in
    let first = show (fetch ()) in
    assert (Sys.file_exists first);
    let offline = Hf_hub.Env.make ~cache_dir:dir ~offline:true () in
    let again =
      show (Hf_hub_unix.download ~env:offline ~repo ~filename:"config.json" ())
    in
    assert (first = again);
    print_endline "network test ok"
