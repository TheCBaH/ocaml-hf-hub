open Hf_hub
open Lwt.Infix

module Native_net = struct
  include Cohttp_lwt_unix.Net

  let default_ctx =
    lazy
      (init
         ~resolver:
           (Resolver_lwt.init ~service:Resolver_lwt_unix.static_service
              ~rewrites:[ ("", Resolver_lwt_unix.system_resolver) ]
              ())
         ())

  let connect_client ~ctx client =
    let client =
      match client with `TLS config -> `TLS_native config | c -> c
    in
    Cohttp_lwt_unix.Net.connect_client ~ctx client

  let connect_endp ~ctx endp =
    Conduit_lwt_unix.endp_to_client ~ctx:ctx.ctx endp >>= connect_client ~ctx

  let connect_uri ~ctx uri = resolve ~ctx uri >>= connect_endp ~ctx
end

module Client = Cohttp_lwt.Client.Make (Cohttp_lwt.Connection.Make (Native_net))

type http = Request.t -> Response.t Lwt.t

let received response =
  Response.Received
    {
      status = Cohttp.Code.code_of_status (Cohttp.Response.status response);
      headers = Cohttp.Header.to_list (Cohttp.Response.headers response);
    }

let origin uri =
  let scheme = Uri.scheme uri in
  let port =
    match Uri.port uri with
    | Some p -> Some p
    | None -> if scheme = Some "https" then Some 443 else Some 80
  in
  (scheme, Option.map String.lowercase_ascii (Uri.host uri), port)

let check_uri uri =
  if
    (not (List.mem (Uri.scheme uri) [ Some "http"; Some "https" ]))
    || Uri.host uri = None
    || Uri.userinfo uri <> None
  then failwith "HTTP transport requires an HTTP(S) URL without userinfo"

let check_range headers offset =
  match Cohttp.Header.get headers "content-range" with
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

let write_body env sink offset body =
  let path =
    Cache_layout.incomplete_path ~root:env.Env.cache_dir sink.Request.Sink.repo
      ~etag:sink.etag
  in
  (if offset > 0L then (
     Lwt_unix.LargeFile.stat path >|= fun st ->
     if st.Unix.LargeFile.st_size <> offset then
       failwith "partial blob size changed before resume")
   else Lwt.return_unit)
  >>= fun () ->
  let flags =
    [ Unix.O_WRONLY; Unix.O_CREAT ]
    @ if offset > 0L then [ Unix.O_APPEND ] else [ Unix.O_TRUNC ]
  in
  Lwt_io.with_file ~mode:Lwt_io.Output ~flags path (fun output ->
      Lwt_stream.iter_s (Lwt_io.write output) (Cohttp_lwt.Body.to_stream body))

let cohttp ?(timeout = 60.) ?(max_redirects = 10) env : http =
  if timeout <= 0. || not (Float.is_finite timeout) then
    invalid_arg "timeout must be positive and finite";
  if max_redirects < 0 then invalid_arg "max_redirects must be nonnegative";
  let rec get remaining headers uri sink offset =
    check_uri uri;
    Client.get ~headers uri >>= fun (response, body) ->
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    let response_headers = Cohttp.Response.headers response in
    if List.mem status [ 301; 302; 303; 307; 308 ] then (
      Cohttp_lwt.Body.drain_body body >>= fun () ->
      if remaining = 0 then Lwt.fail_with "too many HTTP redirects"
      else
        match Cohttp.Header.get response_headers "location" with
        | None -> Lwt.fail_with "HTTP redirect has no Location header"
        | Some location ->
            let next = Uri.resolve "" uri (Uri.of_string location) in
            check_uri next;
            if Uri.scheme uri = Some "https" && Uri.scheme next <> Some "https"
            then Lwt.fail_with "refusing HTTPS to HTTP redirect"
            else
              let headers =
                if origin uri = origin next then headers
                else
                  List.fold_left Cohttp.Header.remove headers
                    [ "authorization"; "proxy-authorization"; "cookie"; "host" ]
              in
              get (remaining - 1) headers next sink offset)
    else if
      (status = 200 && offset = 0L)
      || (status = 206 && check_range response_headers offset)
    then write_body env sink offset body >|= fun () -> received response
    else
      Cohttp_lwt.Body.drain_body body >>= fun () ->
      if status = 200 || status = 206 then
        Lwt.fail_with "server did not honor the requested byte range"
      else Lwt.return (received response)
  in
  fun request ->
    Lwt.catch
      (fun () ->
        Lwt_unix.with_timeout timeout (fun () ->
            match request with
            | Request.Head { url; headers } ->
                let uri = Uri.of_string url in
                check_uri uri;
                Client.head ~headers:(Cohttp.Header.of_list headers) uri
                >|= received
            | Get { url; headers; sink; resume_from } ->
                let headers =
                  Cohttp.Header.of_list headers |> fun h ->
                  Cohttp.Header.replace h "accept-encoding" "identity"
                  |> fun h -> Cohttp.Header.remove h "range"
                in
                let headers =
                  if resume_from > 0L then
                    Cohttp.Header.add headers "range"
                      (Printf.sprintf "bytes=%Ld-" resume_from)
                  else headers
                in
                get max_redirects headers (Uri.of_string url) sink resume_from))
      (function
        | Lwt.Canceled -> Lwt.fail Lwt.Canceled
        | exn -> Lwt.return (Response.Transport_error (Printexc.to_string exn)))

let blocking ?timeout ?max_redirects env =
  let http = cohttp ?timeout ?max_redirects env in
  fun request -> Lwt_main.run (http request)

let run ?http ?(hasher = Hf_hub_unix.sha256sum) env step =
  let http = match http with Some h -> h | None -> cohttp env in
  let rec go = function
    | Download.Done result -> Lwt.return result
    | Need_http (request, continue) ->
        Lwt_preemptive.detach (Hf_hub_unix.prepare_http env) request
        >>= fun () ->
        http request >>= fun response -> go (continue response)
    | Need_store (operation, continue) ->
        Lwt_preemptive.detach (Hf_hub_unix.store ~hasher env) operation
        >>= fun response -> go (continue response)
  in
  go step

let download ?env ?http ?hasher ?revision ~repo ~filename () =
  let env =
    match env with Some e -> e | None -> Hf_hub_unix.Env.of_environment ()
  in
  run ?http ?hasher env (Download.start env ~repo ?revision ~filename ())
