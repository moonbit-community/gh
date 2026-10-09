///|
/// Whether a write is known to have taken effect. Unknown must never be
/// interpreted as permission to retry; read the resource before deciding.
pub(all) enum MutationOutcome {
  NotSent
  Rejected
  Applied
  Accepted
  Unknown
}

///|
pub fn MutationOutcome::as_string(self : MutationOutcome) -> String {
  match self {
    NotSent => "not_sent"
    Rejected => "rejected"
    Applied => "applied"
    Accepted => "accepted"
    Unknown => "unknown"
  }
}

///|
pub struct MutationResult[T] {
  value : Result[T, @gh.ApiFailure]
  trace_failed : Bool
  etag : EntityTag?
  outcome : MutationOutcome
}

///|
/// The current server records comments as events rather than public resources.
/// number identifies the issue or merge request that received the comment.
pub struct CommentReceipt {
  number : Int
  kind : String
}

///|
/// A merge is queued asynchronously. Acceptance is not evidence of completion.
pub struct MergeReceipt {
  number : Int
  version : String
  job_status : String
}

///|
pub extend CommentReceipt with @json.FromJson::{from_json}

///|
pub extend MergeReceipt with @json.FromJson::{from_json}

///|
pub impl @json.FromJson for CommentReceipt with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let kind : String = required_field(fields, "kind", path)
  guard kind == "commented" else { resource_invalid(path.add_key("kind")) }
  { number: positive_number(fields, "number", path), kind, }
}

///|
pub impl @json.FromJson for MergeReceipt with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let version : String = required_field(fields, "version", path)
  guard decimal_string(version, allow_zero=true) else {
    resource_invalid(path.add_key("version"))
  }
  let job_status : String = required_field(fields, "job_status", path)
  guard job_status is ("pending" | "running") else {
    resource_invalid(path.add_key("job_status"))
  }
  { number: positive_number(fields, "number", path), version, job_status, }
}

///|
pub fn CommentReceipt::to_json(self : CommentReceipt) -> Json {
  { "number": self.number.to_json(), "kind": self.kind.to_json() }
}

///|
pub fn MergeReceipt::to_json(self : MergeReceipt) -> Json {
  {
    "number": self.number.to_json(),
    "version": self.version.to_json(),
    "job_status": self.job_status.to_json(),
  }
}
