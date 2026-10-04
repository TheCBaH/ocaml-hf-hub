type error = Hub of Hf_hub.Error.t | Safetensors of Safetensors.Error.t

val pp_error : Format.formatter -> error -> unit

val open_mmap :
  ?env:Hf_hub.Env.t ->
  ?http:Hf_hub_unix.http ->
  ?limits:Safetensors.Limits.t ->
  ?revision:Hf_hub.Revision.t ->
  repo:Hf_hub.Repo_id.t ->
  filename:string ->
  unit ->
  (Safetensors.Memory.t * Hf_hub.Blob.t, error) result
(** Resolve [filename] through the cache (downloading it if needed), then map
    the cached blob read-only with [Safetensors_unix.Mmap.open_file]. The blob
    is content-addressed and never rewritten, which is what makes mapping it
    safe. The {!Hf_hub.Blob.t} gives the cache path and the blob's etag (the
    file's sha256 for an LFS file). *)
