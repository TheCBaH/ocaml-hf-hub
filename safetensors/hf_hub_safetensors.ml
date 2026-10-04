type error = Hub of Hf_hub.Error.t | Safetensors of Safetensors.Error.t

let pp_error ppf = function
  | Hub e -> Hf_hub.Error.pp ppf e
  | Safetensors e -> Safetensors.Error.pp ppf e

let open_mmap ?env ?http ?limits ?revision ~repo ~filename () =
  match Hf_hub_unix.download ?env ?http ?revision ~repo ~filename () with
  | Error e -> Error (Hub e)
  | Ok blob -> (
      match Safetensors_unix.Mmap.open_file ?limits blob.Hf_hub.Blob.path with
      | Error e -> Error (Safetensors e)
      | Ok memory -> Ok (memory, blob))
