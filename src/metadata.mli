type t = {
  commit : string;  (** [X-Repo-Commit]: the commit the revision resolved to. *)
  etag : string;
      (** [X-Linked-Etag] (an LFS file's sha256) else [ETag]; quotes and [W/]
          stripped, and restricted to characters safe in a file name. *)
  sha256 : string option;
      (** Present only when [X-Linked-Etag] is a sha256: the content hash to
          verify. Plain git blobs carry a sha1, which is not checked. *)
  size : int64 option;
      (** [X-Linked-Size] else, on a [200] only, [Content-Length]. *)
}

val of_response : string -> Response.Received.t -> (t, Error.t) result
(** [of_response url r] reads the answer to a HEAD of [url]; any 2xx or 3xx
    status is accepted, because a CDN redirect still carries the headers. *)

val normalize_etag : string -> string
