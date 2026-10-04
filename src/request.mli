module Sink : sig
  type t = { etag : string; repo : Repo_id.t }
  (** Where a GET body goes: the [.incomplete] blob of this repo and etag. The
      driver maps it to a file, an OPFS handle, a buffer, ... *)
end

type t =
  | Get of {
      headers : (string * string) list;
      resume_from : int64;
          (** Bytes already in the sink; [0L] starts it afresh. The driver
              follows redirects and must append after [resume_from] bytes. *)
      sink : Sink.t;
      url : string;
    }
  | Head of { headers : (string * string) list; url : string }
      (** Not following redirects: a Hub [resolve] answers with the metadata
          headers itself, including when it redirects to a CDN. *)
