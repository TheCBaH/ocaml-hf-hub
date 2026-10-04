module Sink = struct
  type t = { etag : string; repo : Repo_id.t }
end

type t =
  | Get of {
      headers : (string * string) list;
      resume_from : int64;
      sink : Sink.t;
      url : string;
    }
  | Head of { headers : (string * string) list; url : string }
