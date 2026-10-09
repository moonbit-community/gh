///|
/// Query an explicitly selected local JSONL trace without loading credentials
/// or constructing a network client. Supply known secrets when reading files
/// produced outside this client's redacting recorder.
pub async fn read_trace(
  path : String,
  query? : @gh.TraceQuery,
  secrets? : Array[String] = [],
) -> Result[@gh.TraceQueryResult, @gh.ApiError] {
  @trace.read(path, query?, secrets~)
}
