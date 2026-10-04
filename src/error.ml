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

let pp ppf = function
  | Http_status { status; url } ->
      Format.fprintf ppf "HTTP %d for %s" status url
  | Invalid_filename s -> Format.fprintf ppf "invalid file name %S" s
  | Invalid_header { name; value } ->
      Format.fprintf ppf "invalid %s header %S" name value
  | Invalid_repo_id s -> Format.fprintf ppf "invalid repo id %S" s
  | Invalid_revision s -> Format.fprintf ppf "invalid revision %S" s
  | Missing_header name ->
      Format.fprintf ppf "response lacks the %s header" name
  | Offline_miss { filename; repo; revision } ->
      Format.fprintf ppf
        "%s@%s of %s is not in the cache and the network is off" filename
        revision repo
  | Sha256_mismatch { actual; expected } ->
      Format.fprintf ppf "sha256 mismatch: expected %s, got %s" expected actual
  | Size_mismatch { actual; expected } ->
      Format.fprintf ppf "size mismatch: expected %Ld bytes, got %Ld" expected
        actual
  | Store s -> Format.fprintf ppf "cache store: %s" s
  | Transport s -> Format.fprintf ppf "transport: %s" s
