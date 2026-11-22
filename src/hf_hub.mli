module Blob = Blob
module Cache_layout = Cache_layout
module Download = Download
module Env = Env
module Error = Error
module Repo_id = Repo_id
module Request = Request
module Response = Response
module Revision = Revision
module Store = Store

module Private : sig
  (** Unstable test helpers. *)
  module Metadata : sig
    type t = {
      commit : string;
      etag : string;
      sha256 : string option;
      size : int64 option;
    }

    val of_response : string -> Response.Received.t -> (t, Error.t) result
  end
end
