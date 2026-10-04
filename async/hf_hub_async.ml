module Unix_sys = Unix
open Hf_hub
open Async

let ( let* ) value f = Deferred.bind value ~f
let ( let+ ) value f = Deferred.map value ~f

type http = Request.t -> Response.t Deferred.t

let error_message = function
  | `Exn exn -> Printexc.to_string exn
  | `Malformed_response message -> message
  | `Invalid_response_body_length _ -> "invalid HTTP/2 response body length"
  | `Protocol_error (code, message) ->
      H2.Error_code.to_string code ^ ": " ^ message

let origin uri =
  let scheme = Uri.scheme uri in
  let port =
    match Uri.port uri with
    | Some port -> port
    | None -> if scheme = Some "https" then 443 else 80
  in
  (scheme, Option.map String.lowercase_ascii (Uri.host uri), port)

let check_uri uri =
  if
    (not (List.mem (Uri.scheme uri) [ Some "http"; Some "https" ]))
    || Uri.host uri = None
    || Uri.userinfo uri <> None
  then failwith "HTTP transport requires an HTTP(S) URL without userinfo"

let check_range headers offset =
  match H2.Headers.get headers "content-range" with
  | None -> false
  | Some value -> (
      try
        Scanf.sscanf value "bytes %Ld-%Ld/%s%!" (fun first last total ->
            first = offset && last >= first
            && (total = "*"
               ||
               match Int64.of_string_opt total with
               | Some total -> total > last
               | None -> false))
      with Scanf.Scan_failure _ | End_of_file | Failure _ -> false)

let request uri meth headers consume ~interrupt =
  check_uri uri;
  let host = Option.get (Uri.host uri) in
  let _, _, port = origin uri in
  let where =
    Tcp.Where_to_connect.of_host_and_port
      (Core.Host_and_port.create ~host ~port)
  in
  let socket = Socket.create Socket.Type.tcp in
  let close_channels = ref (fun () -> Deferred.unit) in
  let result = Ivar.create () in
  let finish value = Ivar.fill_if_empty result value in
  let error_handler error = finish (Error (error_message error)) in
  let response_handler response body =
    don't_wait_for
      (let+ outcome = Monitor.try_with (fun () -> consume response body) in
       finish
         (match outcome with
         | Ok value -> Ok value
         | Error exn -> Error (Printexc.to_string exn)))
  in
  let target =
    let path = match Uri.path uri with "" -> "/" | path -> path in
    match Uri.verbatim_query uri with None -> path | Some q -> path ^ "?" ^ q
  in
  let authority =
    match Uri.port uri with
    | None -> host
    | Some port -> host ^ ":" ^ string_of_int port
  in
  let headers =
    (":authority", authority)
    :: List.filter_map
         (fun (name, value) ->
           let name = String.lowercase_ascii name in
           if List.mem name [ "host"; "connection"; "transfer-encoding" ] then
             None
           else Some (name, value))
         headers
    |> H2.Headers.of_list
  in
  let message =
    H2.Request.create ~headers ~scheme:(Option.get (Uri.scheme uri)) meth target
  in
  let work () =
    let* () =
      if Uri.scheme uri = Some "https" then (
        let* authenticator =
          In_thread.run (fun () -> Ca_certs.authenticator ())
        in
        let authenticator =
          match authenticator with Ok a -> a | Error (`Msg m) -> failwith m
        in
        let tls_config =
          match
            Tls.Config.client ~authenticator ~alpn_protocols:[ "h2" ] ()
          with
          | Ok c -> c
          | Error (`Msg m) -> failwith m
        in
        let peer = Domain_name.host_exn (Domain_name.of_string_exn host) in
        let* tls =
          Tls_async.connect ~socket ~interrupt tls_config ~host:(Some peer)
            where
        in
        let session, reader, writer = Core.Or_error.ok_exn tls in
        (close_channels :=
           fun () ->
             Deferred.all_unit [ Writer.close writer; Reader.close reader ]);
        (match Tls_async.Session.epoch session with
        | Ok epoch when epoch.Tls.Core.alpn_protocol = Some "h2" -> ()
        | _ -> failwith "server did not negotiate HTTP/2 via ALPN");
        let closed =
          Deferred.all_unit
            [ Writer.close_finished writer; Reader.close_finished reader ]
        in
        let* connection =
          H2_async.Client.TLS.create_connection ~error_handler
            (reader, writer, closed)
        in
        let body =
          H2_async.Client.TLS.request connection message ~error_handler
            ~response_handler
        in
        H2.Body.Writer.close body;
        Deferred.unit)
      else
        let* socket = Tcp.connect_sock ~socket ~interrupt where in
        let* connection =
          H2_async.Client.create_connection ~error_handler socket
        in
        let body =
          H2_async.Client.request connection message ~error_handler
            ~response_handler
        in
        H2.Body.Writer.close body;
        Deferred.unit
    in
    Ivar.read result
  in
  Monitor.protect
    (fun () ->
      let work = Monitor.try_with work in
      Deferred.choose
        [
          Deferred.choice work (function
            | Ok result -> result
            | Error exn -> Error (Printexc.to_string exn));
          Deferred.choice interrupt (fun () -> Error "HTTP request timed out");
        ])
    ~finally:(fun () ->
      let* () = !close_channels () in
      Fd.close (Socket.fd socket))

let stream ~interrupt output body =
  let complete = Ivar.create () in
  let rec read () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> Ivar.fill_if_empty complete (Ok ()))
      ~on_read:(fun buffer ~off ~len ->
        let chunk = Bigstringaf.substring buffer ~off ~len in
        don't_wait_for
          (let+ outcome =
             Monitor.try_with (fun () ->
                 Writer.write output chunk;
                 Writer.flushed output)
           in
           match outcome with
           | Ok () -> read ()
           | Error exn -> Ivar.fill_if_empty complete (Error exn)))
  in
  read ();
  let+ outcome =
    Deferred.choose
      [
        Deferred.choice (Ivar.read complete) (fun value -> value);
        Deferred.choice interrupt (fun () ->
            Error (Failure "HTTP request timed out"));
      ]
  in
  H2.Body.Reader.close body;
  match outcome with Ok () -> () | Error exn -> raise exn

let h2 ?(timeout = 60.) ?(max_redirects = 10) env : http =
  if timeout <= 0. || not (Float.is_finite timeout) then
    invalid_arg "timeout must be positive and finite";
  if max_redirects < 0 then invalid_arg "max_redirects must be nonnegative";
  fun operation ->
    let interrupt = Clock.after (Core.Time_float.Span.of_sec timeout) in
    let rec get remaining headers uri sink offset =
      let* result =
        request uri `GET headers ~interrupt (fun response body ->
            let status = H2.Status.to_code response.H2.Response.status in
            if List.mem status [ 301; 302; 303; 307; 308 ] then (
              H2.Body.Reader.close body;
              match H2.Headers.get response.headers "location" with
              | None -> failwith "HTTP redirect has no Location header"
              | Some location -> return (`Redirect location))
            else if
              (status = 200 && offset = 0L)
              || (status = 206 && check_range response.headers offset)
            then
              let path =
                Cache_layout.incomplete_path ~root:env.Env.cache_dir
                  sink.Request.Sink.repo ~etag:sink.etag
              in
              let* () =
                In_thread.run (fun () ->
                    if
                      offset > 0L
                      && (Unix_sys.LargeFile.stat path).st_size <> offset
                    then failwith "partial blob size changed before resume")
              in
              let* output = Writer.open_file ~append:(offset > 0L) path in
              let+ () =
                Monitor.protect
                  (fun () -> stream ~interrupt output body)
                  ~finally:(fun () -> Writer.close output)
              in
              `Received
                {
                  Response.Received.status;
                  headers = H2.Headers.to_list response.headers;
                }
            else (
              H2.Body.Reader.close body;
              if status = 200 || status = 206 then
                failwith "server did not honor the requested byte range";
              return
                (`Received
                   {
                     Response.Received.status;
                     headers = H2.Headers.to_list response.headers;
                   })))
      in
      match result with
      | Error message -> return (Response.Transport_error message)
      | Ok (`Received response) -> return (Response.Received response)
      | Ok (`Redirect location) ->
          if remaining = 0 then
            return (Response.Transport_error "too many HTTP redirects")
          else
            let next = Uri.resolve "" uri (Uri.of_string location) in
            check_uri next;
            if Uri.scheme uri = Some "https" && Uri.scheme next <> Some "https"
            then
              return
                (Response.Transport_error "refusing HTTPS to HTTP redirect")
            else
              let headers =
                if origin uri = origin next then headers
                else
                  List.filter
                    (fun (name, _) ->
                      not
                        (List.mem
                           (String.lowercase_ascii name)
                           [
                             "authorization";
                             "proxy-authorization";
                             "cookie";
                             "host";
                           ]))
                    headers
              in
              get (remaining - 1) headers next sink offset
    in
    let+ outcome =
      Monitor.try_with (fun () ->
          match operation with
          | Request.Head { url; headers } -> (
              let+ result =
                request (Uri.of_string url) `HEAD headers ~interrupt
                  (fun response body ->
                    H2.Body.Reader.close body;
                    return
                      {
                        Response.Received.status =
                          H2.Status.to_code response.H2.Response.status;
                        headers = H2.Headers.to_list response.headers;
                      })
              in
              match result with
              | Ok response -> Response.Received response
              | Error message -> Transport_error message)
          | Get { url; headers; sink; resume_from } ->
              let headers =
                List.filter
                  (fun (name, _) ->
                    not
                      (List.mem
                         (String.lowercase_ascii name)
                         [ "range"; "accept-encoding" ]))
                  headers
              in
              let headers = ("accept-encoding", "identity") :: headers in
              let headers =
                if resume_from > 0L then
                  ("range", Printf.sprintf "bytes=%Ld-" resume_from) :: headers
                else headers
              in
              get max_redirects headers (Uri.of_string url) sink resume_from)
    in
    match outcome with
    | Ok response -> response
    | Error exn -> Response.Transport_error (Printexc.to_string exn)

let run ?http ?(hasher = Hf_hub_unix.sha256sum) env step =
  let http = match http with Some h -> h | None -> h2 env in
  let rec go = function
    | Download.Done result -> return result
    | Need_http (operation, continue) ->
        let* () =
          In_thread.run (fun () -> Hf_hub_unix.prepare_http env operation)
        in
        let* response = http operation in
        go (continue response)
    | Need_store (operation, continue) ->
        let* response =
          In_thread.run (fun () -> Hf_hub_unix.store ~hasher env operation)
        in
        go (continue response)
  in
  go step

let download ?env ?http ?hasher ?revision ~repo ~filename () =
  let env =
    match env with Some e -> e | None -> Hf_hub_unix.Env.of_environment ()
  in
  run ?http ?hasher env (Download.start env ~repo ?revision ~filename ())
