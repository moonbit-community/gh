///|
/// The live scope gate covers process side effects as well as HTTP. A denied
/// process is never launched, even if an HTTP request would later be denied.
async fn acceptance_process_allowed(
  program : String,
  args : Array[String],
  policy_path? : String,
) -> Bool {
  let policy_path = match policy_path {
    Some(_) => policy_path
    None => @env.get_env_var("GH_ACCEPTANCE_POLICY")
  }
  if @env.get_env_var("GH_LIVE_ACCEPTANCE") != Some("1") && policy_path is None {
    return true
  }
  guard policy_path is Some(path) else { return false }
  try {
    guard @fs.kind(path) == @fs.Regular && @fs.file_size(path) <= 262144L else {
      return false
    }
    let policy = @live_scope.Policy::from_json(
      @json.parse(@fs.read_file(path).text()),
    )
    policy.allows_process(program, args)
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ => false
  }
}
