type t = {
  cache_dir : string;
  endpoint : string;
  offline : bool;
  token : string option;
}

let default_endpoint = "https://huggingface.co"

let strip_slashes s =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = '/' do
    decr n
  done;
  String.sub s 0 !n

let make ~cache_dir ?(endpoint = default_endpoint) ?(offline = false) ?token ()
    =
  { cache_dir; endpoint = strip_slashes endpoint; offline; token }
