///|
/// A runner must establish that the supplied executable implements the scope
/// protocol before providing real credentials. Older executables ignore this
/// environment variable and cannot echo the fresh challenge in this format.
async fn acceptance_probe(
  path : String?,
  challenge : String,
) -> @github_cli.Output {
  guard challenge.length() == 32 &&
    challenge.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f')) &&
    path is Some(path) else {
    return @github_cli.failure(message="invalid acceptance probe")
  }
  try {
    guard @fs.kind(path) == @fs.Regular && @fs.file_size(path) <= 262144L else {
      return @github_cli.failure(message="invalid acceptance policy")
    }
    ignore(
      @live_scope.Policy::from_json(@json.parse(@fs.read_file(path).text())),
    )
    @github_cli.success(
      stdout=Json::object({ "scope_protocol": 1, "challenge": Json(challenge) }).stringify() +
        "\n",
    )
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ => @github_cli.failure(message="invalid acceptance policy")
  }
}
