type t =
  | Http_status of { status : int; url : string }
  | Invalid_filename of string
  | Invalid_header of { name : string; value : string }
  | Invalid_repo_id of string
  | Invalid_revision of string
  | Missing_header of string
  | Offline_miss of { filename : string; repo : string; revision : string }
  | Sha256_mismatch of { actual : string; expected : string }
  | Size_mismatch of { actual : int64; expected : int64 }
  | Store of string
  | Transport of string

val pp : Format.formatter -> t -> unit
