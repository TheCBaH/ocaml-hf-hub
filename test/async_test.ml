open Async

let ( let* ) value f = Deferred.bind value ~f
let ( let+ ) value f = Deferred.map value ~f

let main () =
  let endpoint = ref "" in
  let request_handler _ reqd =
    let request = H2.Reqd.request reqd in
    H2.Body.Reader.close (H2.Reqd.request_body reqd);
    if request.H2.Request.target = "/abort-body" then (
      let response =
        H2.Response.create
          ~headers:(H2.Headers.of_list [ ("content-length", "5") ])
          `OK
      in
      let body = H2.Reqd.respond_with_streaming reqd response in
      H2.Body.Writer.write_string body "he";
      don't_wait_for
        (let+ () = Clock.after (Core.Time_float.Span.of_sec 0.01) in
         H2.Reqd.report_exn reqd (Failure "aborted response")))
    else if request.H2.Request.target <> "/slow" then
      let status, headers, body =
        Transport_cases.response ~endpoint:!endpoint request.meth request.target
          (H2.Headers.to_list request.headers)
      in
      let headers =
        if request.meth = `HEAD then headers
        else ("content-length", string_of_int (String.length body)) :: headers
      in
      let response =
        H2.Response.create
          ~headers:(H2.Headers.of_list headers)
          (H2.Status.of_code status)
      in
      H2.Reqd.respond_with_string reqd response
        (if request.meth = `HEAD then "" else body)
  in
  let error_handler _ ?request:_ _ respond =
    H2.Body.Writer.close (respond H2.Headers.empty)
  in
  let handler =
    H2_async.Server.create_connection_handler ~request_handler ~error_handler
  in
  let* server =
    Tcp.Server.create_sock ~on_handler_error:`Raise
      (Tcp.Where_to_listen.of_port 0)
      handler
  in
  endpoint :=
    Printf.sprintf "http://127.0.0.1:%d" (Tcp.Server.listening_on server);
  let env = Transport_cases.cache ~endpoint:!endpoint () in
  Monitor.protect
    (fun () ->
      let http = Hf_hub_async.h2 ~timeout:0.2 ~max_redirects:2 env in
      let* () =
        Deferred.List.iter ~how:`Sequential (Transport_cases.cases env)
          ~f:(fun ((request, _, check) as case) ->
            Transport_cases.prepare env case;
            let+ response = http request in
            check response)
      in
      let request =
        Hf_hub.Request.Get
          {
            url = !endpoint ^ "/abort-body";
            headers = [];
            resume_from = 0L;
            sink = { repo = Transport_cases.repo; etag = Transport_cases.etag };
          }
      in
      Hf_hub_unix.prepare_http env request;
      let* aborted = http request in
      (match aborted with
      | Hf_hub.Response.Transport_error _ -> ()
      | _ -> failwith "stream reset was ignored");
      let* result =
        Hf_hub_async.download ~env ~repo:Transport_cases.repo ~filename:"file"
          ()
      in
      Transport_cases.check_download result;
      let offline = Hf_hub.Env.make ~cache_dir:env.cache_dir ~offline:true () in
      let+ result =
        Hf_hub_async.download ~env:offline ~repo:Transport_cases.repo
          ~filename:"file" ()
      in
      Transport_cases.check_download result;
      print_endline "h2/Async transport tests passed")
    ~finally:(fun () ->
      let+ () = Tcp.Server.close ~close_existing_connections:true server in
      Transport_cases.remove env.cache_dir)

let () =
  don't_wait_for
    (let+ outcome = Monitor.try_with main in
     match outcome with
     | Ok () -> Shutdown.shutdown 0
     | Error exn ->
         prerr_endline (Printexc.to_string exn);
         Shutdown.shutdown 1);
  Core.never_returns (Scheduler.go ())
