///|
async fn read_locked_trace(path : String) -> String {
  if @fs.kind(path, follow_symlink=false) != @fs.Regular {
    fail("trace input must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    fail("trace input must be a regular file")
  }
  file.lock(Shared)
  defer file.unlock()
  let size = file.size()
  if size > 8388608L {
    fail("trace input exceeds 8 MiB")
  }
  @utf8.decode(file.read_exactly_at(size.to_int(), position=0L))
}

///|
/// Read an explicitly selected UTF-8 JSONL file without network or credentials.
/// Shared advisory locking gives a consistent snapshot with cooperating
/// appenders. Read/open/lock are bounded to 30 seconds, input to 8 MiB.
/// Symlinks and nonregular files are refused. As with append(), the upstream
/// API does not provide no-follow open; callers must control the directory.
/// Input paths and OS/parser messages are never included in failures.
pub async fn read(
  path : String,
  query? : @gh.TraceQuery,
  secrets? : Array[String] = [],
) -> Result[@gh.TraceQueryResult, @gh.ApiError] {
  if path.is_empty() || path == "-" {
    return Err(
      @gh.InvalidRequest(
        message="trace input requires an explicit regular file",
      ),
    )
  }
  let content = @async.with_timeout(30000, () => read_locked_trace(path)) catch {
    error if @async.is_cancellation_error(error) => raise error
    _ =>
      return Err(
        @gh.InvalidRequest(
          message="cannot read trace input as bounded UTF-8 text",
        ),
      )
  }
  @gh.parse_trace_jsonl(content, query?, secrets~)
}
