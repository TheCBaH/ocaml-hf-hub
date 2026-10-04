(** The huggingface_hub cache layout, so the two tools share one cache:

    {v
    <root>/models--owner--name/
      blobs/<etag>                    content, named by its etag (LFS: sha256)
      blobs/<etag>.incomplete         a download in progress
      snapshots/<commit>/<file>       relative symlink to ../../blobs/<etag>
      refs/<branch>                   a file holding a commit sha
    v} *)

val check_filename : string -> (unit, Error.t) result
(** A relative [/]-separated path with no empty, [.] or [..] segment. *)

val repo_dir : root:string -> Repo_id.t -> string
val blob_path : root:string -> Repo_id.t -> etag:string -> string
val incomplete_path : root:string -> Repo_id.t -> etag:string -> string
val snapshot_dir : root:string -> Repo_id.t -> commit:string -> string

val snapshot_path :
  root:string -> Repo_id.t -> commit:string -> filename:string -> string

val ref_path : root:string -> Repo_id.t -> ref_:string -> string

val symlink_target : filename:string -> etag:string -> string
(** Relative to the link's directory; one more [..] per [/] in [filename]. *)
