(* The core operates on OCaml byte strings. Preserve UTF-8 at the JS boundary,
   especially when the core percent-encodes non-ASCII file names. *)
let call : string -> string array -> (string array -> unit) -> unit =
  [%mel.raw
    {|function(op, args, callback) {
      const decode = s => new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(s, c => c.charCodeAt(0)));
      const encode = s => Array.from(new TextEncoder().encode(s), c => String.fromCharCode(c)).join('');
      globalThis.hfHubHost.call(op, args.map(decode), reply => callback(reply.map(encode)));
    }|}]

let export : (string array -> (string array -> unit) -> unit) -> unit =
  [%mel.raw
    {|function(run) {
      const decode = s => new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(s, c => c.charCodeAt(0)));
      const encode = s => Array.from(new TextEncoder().encode(s), c => String.fromCharCode(c)).join('');
      globalThis.hfHubStart = (args, callback) => run(args.map(encode), reply => callback(reply.map(decode)));
    }|}]
