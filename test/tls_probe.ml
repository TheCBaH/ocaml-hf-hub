let () =
  let client = Sys.argv.(1)
  and url = Sys.argv.(2)
  and expectation = Sys.argv.(3) in
  let env = Transport_cases.cache ~endpoint:url () in
  Fun.protect
    ~finally:(fun () -> Transport_cases.remove env.Hf_hub.Env.cache_dir)
    (fun () ->
      if expectation = "hub" then (
        let env = { env with Hf_hub.Env.token = None } in
        let repo =
          Result.get_ok
            (Hf_hub.Repo_id.of_string "timm/mobilenetv2_050.lamb_in1k")
        in
        let result =
          match client with
          | "lwt" ->
              Lwt_main.run
                (Hf_hub_lwt.download ~env ~repo ~filename:"config.json" ())
          | "async" ->
              Async.Thread_safe.block_on_async_exn (fun () ->
                  Hf_hub_async.download ~env ~repo ~filename:"config.json" ())
          | _ -> failwith "unknown test client"
        in
        match result with
        | Error error -> Format.kasprintf failwith "%a" Hf_hub.Error.pp error
        | Ok blob ->
            assert (
              String.length (Transport_cases.read blob.Hf_hub.Blob.path) > 0);
            Printf.printf "%s Hub download passed\n%!" client)
      else
        let request =
          Hf_hub.Request.Get
            {
              url;
              headers = [];
              resume_from = 0L;
              sink =
                { repo = Transport_cases.repo; etag = Transport_cases.etag };
            }
        in
        Hf_hub_unix.prepare_http env request;
        let response =
          match client with
          | "lwt" -> Lwt_main.run (Hf_hub_lwt.cohttp ~timeout:0.5 env request)
          | "async" ->
              Async.Thread_safe.block_on_async_exn (fun () ->
                  Hf_hub_async.h2 ~timeout:0.5 env request)
          | _ -> failwith "unknown test client"
        in
        match (expectation, response) with
        | "ok", Hf_hub.Response.Received { status = 200; _ } ->
            assert (
              Transport_cases.read (Transport_cases.sink_path env) = "hello")
        | "error", Transport_error _ -> ()
        | "timeout", Transport_error message ->
            if
              message <> "HTTP request timed out"
              && message <> "Lwt_unix.Timeout"
            then failwith (client ^ " handshake: " ^ message)
        | _ -> failwith "unexpected TLS probe result")
