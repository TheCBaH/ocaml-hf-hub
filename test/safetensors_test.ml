open Hf_hub

let header = {|{"x":{"dtype":"U8","shape":[5],"data_offsets":[0,5]}}|}

let file =
  let p = Bytes.create 8 in
  Bytes.set_int64_le p 0 (Int64.of_int (String.length header));
  Bytes.to_string p ^ header ^ "hello"

let%expect_test "open_mmap downloads, verifies and maps" =
  let dir = Filename.temp_file "hf-hub-st-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let tmp = Filename.temp_file "hf-hub-st-" ".bin" in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc file);
  let sha = Result.get_ok (Hf_hub_unix.sha256sum tmp) in
  Sys.remove tmp;
  let commit = String.make 40 'c' in
  let env = Env.make ~cache_dir:dir ~endpoint:"https://hub" () in
  let http : Hf_hub_unix.http = function
    | Request.Head _ ->
        Response.Received
          {
            status = 200;
            headers =
              [
                ("X-Repo-Commit", commit);
                ("X-Linked-Etag", "\"" ^ sha ^ "\"");
                ("X-Linked-Size", string_of_int (String.length file));
              ];
          }
    | Get { sink; _ } ->
        Out_channel.with_open_bin
          (Cache_layout.incomplete_path ~root:dir sink.repo ~etag:sink.etag)
          (fun oc -> output_string oc file);
        Response.Received { status = 200; headers = [] }
  in
  let repo = Result.get_ok (Repo_id.of_string "o/m") in
  (match
     Hf_hub_safetensors.open_mmap ~env ~http ~repo ~filename:"m.safetensors" ()
   with
  | Error e -> Format.printf "error: %a@." Hf_hub_safetensors.pp_error e
  | Ok (memory, blob) ->
      let view = Result.get_ok (Safetensors.Memory.tensor_view memory "x") in
      Printf.printf "x = %s, etag is sha256: %b\n"
        (String.init (Bigarray.Array1.dim view) (Bigarray.Array1.get view))
        (blob.etag = Some sha));
  [%expect {| x = hello, etag is sha256: true |}]
