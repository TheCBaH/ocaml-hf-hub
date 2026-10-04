type t = {
  commit : string;
  etag : string option;
      (** The blob the snapshot link points at; [None] if the file in
          [snapshots/] is not one of our links. *)
  path : string;  (** The [snapshots/<commit>/<file>] path: open this one. *)
}
