module Blob_state = struct
  type t = Absent | Complete | Partial of int64
end

module Check = struct
  type t = Mismatch of Error.t | Verified
end

module Op = struct
  type t =
    | Check_blob of {
        etag : string;
        repo : Repo_id.t;
        sha256 : string option;
        size : int64 option;
      }
    | Commit of {
        commit : string;
        etag : string;
        filename : string;
        ref_ : string option;
        repo : Repo_id.t;
      }
    | Discard_partial of { etag : string; repo : Repo_id.t }
    | Find_blob of { etag : string; repo : Repo_id.t }
    | Find_ref of { ref_ : string; repo : Repo_id.t }
    | Find_snapshot of {
        commit : string;
        etag : string option;
        filename : string;
        repo : Repo_id.t;
      }
end

module Snapshot_state = struct
  type t = Absent | Present of { etag : string option }
end

type reply =
  | Blob_state of Blob_state.t
  | Check of Check.t
  | Ref of string option
  | Snapshot of Snapshot_state.t
  | Store_error of string
  | Stored
