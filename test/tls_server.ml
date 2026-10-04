open Lwt.Infix

let certfile = "fixtures/server.pem"
let keyfile = "fixtures/server.key"

let listener () =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
  >>= fun () ->
  Lwt_unix.listen socket 16;
  let port =
    match Lwt_unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> assert false
  in
  Lwt.return (socket, port)

let serve socket handler =
  let rec accept () =
    Lwt_unix.accept socket >>= fun (client, address) ->
    Lwt.async (fun () ->
        Lwt.catch
          (fun () -> handler address client)
          (fun _ -> Lwt_unix.close client));
    accept ()
  in
  Lwt.async accept

let main () =
  let request_handler _ reqd =
    let request = H2.Reqd.request reqd in
    H2.Body.Reader.close (H2.Reqd.request_body reqd);
    let response =
      H2.Response.create
        ~headers:(H2.Headers.of_list [ ("content-length", "5") ])
        `OK
    in
    H2.Reqd.respond_with_string reqd response
      (if request.H2.Request.meth = `HEAD then "" else "hello")
  in
  let error_handler _ ?request:_ _ respond =
    H2.Body.Writer.close (respond H2.Headers.empty)
  in
  let h2_handler =
    H2_lwt_unix.Server.TLS.create_connection_handler_with_default ~certfile
      ~keyfile ~request_handler ~error_handler
  in
  let http1_handler address socket =
    Gluten_lwt_unix.Server.TLS.create_default ~certfile ~keyfile
      ~alpn_protocols:[ "http/1.1" ] address socket
    >>= fun tls ->
    let buffer = Bytes.create 4096 in
    let rec read data =
      Tls_lwt.Unix.read tls buffer >>= fun count ->
      let data = data ^ Bytes.sub_string buffer 0 count in
      if String.contains data '\n' then Lwt.return data else read data
    in
    read "" >>= fun request ->
    let response =
      if String.starts_with ~prefix:"GET /downgrade " request then
        "HTTP/1.1 302 Found\r\n\
         Location: http://localhost/ok\r\n\
         Content-Length: 0\r\n\
         \r\n"
      else
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    in
    Tls_lwt.Unix.write tls response >>= fun () -> Tls_lwt.Unix.close tls
  in
  listener () >>= fun (http1_socket, http1_port) ->
  listener () >>= fun (h2_socket, h2_port) ->
  listener () >>= fun (stall_socket, stall_port) ->
  serve http1_socket http1_handler;
  serve h2_socket h2_handler;
  serve stall_socket (fun _ socket ->
      Lwt_unix.sleep 2. >>= fun () -> Lwt_unix.close socket);
  Printf.printf "%d %d %d\n%!" http1_port h2_port stall_port;
  fst (Lwt.wait ())

let () =
  (Lwt.async_exception_hook := fun _ -> ());
  Lwt_main.run (main ())
