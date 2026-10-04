open Lwt.Infix

let main () =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
  >>= fun () ->
  Lwt_unix.listen socket 16;
  let port =
    match Lwt_unix.getsockname socket with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
  let env = Transport_cases.cache ~endpoint () in
  let callback _ request body =
    Cohttp_lwt.Body.drain_body body >>= fun () ->
    let path = Uri.path (Cohttp.Request.uri request) in
    (if path = "/slow" then Lwt_unix.sleep 0.5 else Lwt.return_unit)
    >>= fun () ->
    let status, headers, body =
      Transport_cases.response ~endpoint
        (Cohttp.Request.meth request)
        path
        (Cohttp.Header.to_list (Cohttp.Request.headers request))
    in
    Cohttp_lwt_unix.Server.respond_string
      ~status:(Cohttp.Code.status_of_code status)
      ~headers:(Cohttp.Header.of_list headers)
      ~body ()
  in
  let stop, stopper = Lwt.wait () in
  let server =
    Cohttp_lwt_unix.Server.create ~stop
      ~mode:(`TCP (`Socket socket))
      (Cohttp_lwt_unix.Server.make ~callback ())
  in
  Lwt.finalize
    (fun () ->
      let http = Hf_hub_lwt.cohttp ~timeout:0.2 ~max_redirects:2 env in
      Lwt_list.iter_s
        (fun ((request, _, check) as case) ->
          Transport_cases.prepare env case;
          http request >|= check)
        (Transport_cases.cases env)
      >>= fun () ->
      let cancellable =
        http (Hf_hub.Request.Head { url = endpoint ^ "/slow"; headers = [] })
      in
      Lwt.cancel cancellable;
      Lwt.catch
        (fun () ->
          cancellable >>= fun _ -> Lwt.fail_with "cancellation swallowed")
        (function Lwt.Canceled -> Lwt.return_unit | exn -> Lwt.fail exn)
      >>= fun () ->
      Hf_hub_lwt.download ~env ~repo:Transport_cases.repo ~filename:"file" ()
      >>= fun result ->
      Transport_cases.check_download result;
      let offline = Hf_hub.Env.make ~cache_dir:env.cache_dir ~offline:true () in
      Hf_hub_lwt.download ~env:offline ~repo:Transport_cases.repo
        ~filename:"file" ()
      >|= Transport_cases.check_download)
    (fun () ->
      Lwt.wakeup_later stopper ();
      server >>= fun () ->
      Transport_cases.remove env.cache_dir;
      Lwt.return_unit)

let () =
  Lwt_main.run (main ());
  print_endline "Cohttp/Lwt transport tests passed"
