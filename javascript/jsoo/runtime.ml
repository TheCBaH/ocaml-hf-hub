open Js_of_ocaml

let strings a = Js.array (Array.map Js.string a)
let of_strings a = Array.map Js.to_string (Js.to_array a)

let call op args callback =
  let host = Js.Unsafe.get Js.Unsafe.global "hfHubHost" in
  ignore
    (Js.Unsafe.meth_call host "call"
       [|
         Js.Unsafe.inject (Js.string op);
         Js.Unsafe.inject (strings args);
         Js.Unsafe.inject
           (Js.wrap_callback (fun reply -> callback (of_strings reply)));
       |])

let export run =
  Js.Unsafe.set Js.Unsafe.global "hfHubStart"
    (Js.wrap_callback (fun args callback ->
         run (of_strings args) (fun reply ->
             ignore
               (Js.Unsafe.fun_call callback
                  [| Js.Unsafe.inject (strings reply) |]))))
