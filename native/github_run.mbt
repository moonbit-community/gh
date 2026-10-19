///|
/// GitHub executable dispatcher.
pub async fn run_github(args : Array[String]) -> @github_cli.Output {
  let invocation = @github_cli.parse(args) catch {
    @github_cli.MissingValue(option) =>
      return @github_cli.Output::new(
        stderr="missing value for " + option + "\n",
        exit_code=1,
      )
    @github_cli.InvalidValue(message) =>
      return @github_cli.Output::new(stderr=message + "\n", exit_code=1)
    @github_cli.UnknownOption(option) =>
      return @github_cli.Output::new(
        stderr="unknown flag: " + option + "\n",
        exit_code=1,
      )
    @github_cli.UnexpectedArgument(argument) =>
      return @github_cli.Output::new(
        stderr="unexpected argument: " + argument + "\n",
        exit_code=1,
      )
  }
  match invocation {
    @github_cli.Help =>
      @github_cli.success(stdout=@github_cli.help_text() + "\n")
    @github_cli.HelpTopic(topic) => command_help(topic)
    @github_cli.Version =>
      @github_cli.success(stdout="gh version 2.102.0 (2026-09-30)\n")
    @github_cli.Completion(shell~) => completion_output(shell)
    @github_cli.Config(arguments) => github_config_command(arguments)
    @github_cli.Alias(arguments) => github_alias_command(arguments)
    // The native executable selects the platform credential store. Embedders
    // can still inject their own CredentialBackend explicitly.
    @github_cli.Auth(arguments) =>
      github_auth_command(
        arguments,
        oauth_adapter?=default_oauth_adapter(arguments),
        credential_backend=system_credential_backend(),
      )
    @github_cli.Api(options) => run_api(options)
    @github_cli.Business(options) => run_business(options)
    @github_cli.Unsupported(command) =>
      @github_cli.failure(message="unknown command: " + command)
  }
}

///|
/// Command help is kept local and deterministic. The API topic documents the
/// raw REST/GraphQL surface that is implemented by the native runner; other
/// top-level topics fall back to the corresponding static business help.
fn command_help(topic : String) -> @github_cli.Output {
  if topic == "api" {
    return @github_cli.success(
      stdout=(
        #|Makes an authenticated HTTP request to the GitHub API and prints the response.
        #|
        #|The endpoint is a REST path or `graphql`. `{owner}`, `{repo}`, and `{branch}`
        #|are resolved from the current repository or `GH_REPO`.
        #|
        #|USAGE
        #|  gh api <endpoint> [flags]
        #|
        #|FLAGS
        #|  -F, --field key=value       Add a typed parameter
        #|  -H, --header key:value      Add an HTTP request header
        #|      --hostname string       GitHub hostname (default "github.com")
        #|  -i, --include               Include response status and headers
        #|      --input file            Read a request body, or - for stdin
        #|  -q, --jq string             Select response values with jq
        #|  -X, --method string         HTTP method (default GET)
        #|      --paginate              Request all REST/GraphQL pages
        #|  -p, --preview strings       Opt into API previews
        #|  -f, --raw-field key=value   Add a string parameter
        #|      --silent                Suppress the response body
        #|      --slurp                 Wrap paginated responses in an array
        #|  -t, --template string       Format JSON with a Go template
        #|      --verbose               Include request and response details
        #|
        #|Use `gh help formatting` for jq and template output.
        #|
      ),
    )
  }
  if topic
    is ("repo" | "status" | "issue" | "pr" | "release" | "run" | "ruleset") {
    return @github_cli.success(stdout=business_help(topic) + "\n")
  }
  @github_cli.success(stdout=@github_cli.help_text() + "\n")
}

///|
/// Execute one of gh's core resource commands through the same configured
/// client used by `gh api`. The command implementation is deliberately
/// fixture-friendly: tests can call `execute_github_business` with an injected
/// transport while the executable resolves credentials and git here.
async fn run_business(
  options : @github_cli.BusinessOptions,
) -> @github_cli.Output {
  if business_help_requested(options) {
    return @github_cli.success(stdout=business_help(options.command()) + "\n")
  }
  // Browsing is a local process operation. It must not require a GitHub
  // token or construct an API client just to hand a URL to the configured
  // browser opener.
  if options.command() == "browse" {
    return run_browse(options)
  }
  // These two commands are local Git workflows. They deliberately run before
  // API authentication: Git's configured credential helper owns any remote
  // credential exchange, and the repository URL never contains a token.
  let parsed = parse_business(options)
  if options.command() == "repo" && parsed.subcommand == "clone" {
    return run_repo_clone(options, parsed)
  }
  if options.command() == "pr" && parsed.subcommand == "checkout" {
    let repository = match
      resolve_repository_context(repo?=business_repository_arg(options)) {
      Ok(value) => value
      Err(error) => return error
    }
    return run_pr_checkout(options, parsed, repository)
  }
  let mut environment = @github_auth.Environment::from_process()
  if business_hostname_arg(options) is Some(host) {
    environment = environment.with_host(host)
  } else if business_repository_arg(options) is Some(repo) {
    match @github_cli.RepositoryContext::parse(repo) {
      Ok(context) => environment = environment.with_host(context.host())
      Err(_) =>
        return @github_cli.failure(
          message="expected the [HOST/]OWNER/REPO format",
        )
    }
  }
  let keyring = system_credential_backend()
  let config = match resolve_github_auth_with_backend(environment, keyring) {
    Ok(value) => value
    Err(error) => return error
  }
  guard config.token() is Some(_) else {
    return @github_cli.Output::new(
      stderr="To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n",
      exit_code=4,
    )
  }
  let repository = if business_needs_repository(options) {
    match resolve_repository_context(repo?=business_repository_arg(options)) {
      Ok(value) => Some(value)
      Err(error) => return error
    }
  } else {
    None
  }
  let client = match
    github_client(
      base_url=config.rest_base_url(),
      graphql_url=config.graphql_url(),
      token?=config.token(),
      trace_path?=@env.get_env_var("GH_TRACE_FILE"),
    ) {
    Ok(value) => value
    Err(error) => return error
  }
  execute_github_business(
    options,
    client~,
    base_url=config.rest_base_url(),
    repository?,
  )
}

///|
/// Clone a repository through the argv-only Git adapter. The endpoint is
/// constructed from a validated repository identity; no token or shell text
/// is ever included in the child command.
async fn run_repo_clone(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
) -> @github_cli.Output {
  guard parsed.positionals.get(0) is Some(name) else {
    return @github_cli.failure(message="repository is required")
  }
  let default_host = business_hostname_arg(options).unwrap_or(
    @env.get_env_var("GH_HOST").unwrap_or("github.com"),
  )
  let repository = match
    @github_cli.RepositoryContext::parse(name, default_host~) {
    Ok(value) => value
    Err(_) =>
      return @github_cli.failure(
        message="expected the [HOST/]OWNER/REPO format",
      )
  }
  let args : Array[String] = ["clone"]
  match parsed.values.get("depth") {
    Some(value) if !value.is_empty() &&
      value.iter().all(ch => ch is ('0'..<='9')) => {
      args.push("--depth")
      args.push(value)
    }
    Some(_) =>
      return @github_cli.failure(message="depth must be a positive integer")
    None => ()
  }
  match parsed.values.get("branch") {
    Some(value) => {
      guard valid_local_git_value(value) else {
        return @github_cli.failure(message="invalid branch")
      }
      args.push("--branch")
      args.push(value)
    }
    None => ()
  }
  args.push(
    "https://" + repository.host() + "/" + repository.full_name() + ".git",
  )
  if parsed.positionals.get(1) is Some(directory) {
    guard valid_local_git_value(directory) else {
      return @github_cli.failure(message="invalid clone directory")
    }
    args.push(directory)
  }
  let result = run_native_process("git", args, timeout_ms=600000) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return @github_cli.failure(message="git clone failed")
  }
  match result {
    Ok(value) =>
      @github_cli.Output::from_bytes(
        value.stdout(),
        stderr=@utf8.decode(value.stderr()) catch { _ => "" },
        exit_code=value.exit_code(),
      )
    Err(ProcessAdapterError::TimedOut) =>
      @github_cli.failure(message="git clone timed out")
    Err(ProcessAdapterError::OutputLimit) =>
      @github_cli.failure(message="git clone output exceeded the limit")
    Err(_) => @github_cli.failure(message="git clone failed")
  }
}

///|
/// Checkout a pull request using Git's fetch refspec. This keeps all process
/// arguments separate and uses the repository's configured `origin`; Git
/// credential setup remains the caller's responsibility.
async fn run_pr_checkout(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
  repository : @github_cli.RepositoryContext,
) -> @github_cli.Output {
  ignore(repository)
  guard parsed.positionals.get(0) is Some(number) else {
    return @github_cli.failure(message="pull request number is required")
  }
  guard number.iter().all(ch => ch is ('0'..<='9')) else {
    return @github_cli.failure(message="pull request number must be numeric")
  }
  let branch = parsed.values.get("branch").unwrap_or("pr-" + number)
  guard valid_local_git_value(branch) else {
    return @github_cli.failure(message="invalid checkout branch")
  }
  let fetch = repository_git([
    "fetch",
    "origin",
    "pull/" + number + "/head:" + branch,
  ]) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return @github_cli.failure(message="could not fetch pull request")
  }
  guard fetch.code == 0 else {
    return @github_cli.failure(message="could not fetch pull request")
  }
  let checkout = repository_git(["checkout", branch]) catch {
    error if @async.is_being_cancelled() => raise error
    _ => return @github_cli.failure(message="could not check out pull request")
  }
  guard checkout.code == 0 else {
    return @github_cli.failure(message="could not check out pull request")
  }
  ignore(options)
  @github_cli.success(
    stdout="Checked out pull request " + number + " on " + branch + "\n",
  )
}

///|
fn valid_local_git_value(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 4096 &&
  value
  .iter()
  .all(ch => {
    ch.to_int() > 32 && ch.to_int() != 127 && ch != '\\' && ch != '\u{0}'
  })
}

///|
/// Resolve gh's browser setting and invoke it through the argv-only native
/// adapter. The command itself is never passed through a shell; users can
/// still configure wrappers such as `open --background` safely.
async fn configured_browser(host : String?) -> String {
  let from_environment = match @env.get_env_var("GH_BROWSER") {
    Some(value) => Some(value)
    None => @env.get_env_var("BROWSER")
  }
  match from_environment {
    Some(value) if !value.trim().is_empty() => return value.trim().to_owned()
    _ => ()
  }
  let configured = match config_hosts_path() {
    Some(path) => {
      let directory = path
        .strip_suffix("/hosts.yml")
        .map(value => value.to_owned())
      match directory {
        Some(directory) => {
          let root = local_read_yaml(directory + "/config.yml") catch {
            _ => Map([])
          }
          let hosts = local_read_yaml(directory + "/hosts.yml") catch {
            _ => Map([])
          }
          local_config_value(root, hosts, host, "browser")
        }
        None => None
      }
    }
    None => None
  }
  configured.filter(value => !value.trim().is_empty()).unwrap_or("xdg-open")
}

///|
/// Resolve the editor exactly once at the native boundary. gh gives the
/// process environment precedence over config.yml, then falls back to `vi`.
/// The returned command is still parsed into argv by `run_editor`, so quoted
/// arguments remain literal and no shell is involved.
pub async fn configured_editor(host : String?) -> String {
  for key in ["GH_EDITOR", "GIT_EDITOR", "VISUAL", "EDITOR"] {
    match @env.get_env_var(key) {
      Some(value) if !value.trim().is_empty() => return value.trim().to_owned()
      _ => ()
    }
  }
  let configured = match config_hosts_path() {
    Some(path) => {
      let directory = path
        .strip_suffix("/hosts.yml")
        .map(value => value.to_owned())
      match directory {
        Some(directory) => {
          let root = local_read_yaml(directory + "/config.yml") catch {
            _ => Map([])
          }
          let hosts = local_read_yaml(directory + "/hosts.yml") catch {
            _ => Map([])
          }
          local_config_value(root, hosts, host, "editor")
        }
        None => None
      }
    }
    None => None
  }
  configured.filter(value => !value.trim().is_empty()).unwrap_or("vi")
}

///|
/// Invoke the configured editor with one temporary file path appended as an
/// argv element. This public seam lets issue/pr/release commands and host
/// applications share the same timeout and shell-free behavior.
pub async fn run_configured_editor(
  path : String,
  host? : String,
  timeout_ms~ : Int32 = 300000,
) -> Result[NativeProcessResult, ProcessAdapterError] {
  let command = configured_editor(host)
  run_editor(command, path, timeout_ms~)
}

///|
async fn run_browse(
  options : @github_cli.BusinessOptions,
) -> @github_cli.Output {
  let explicit = business_repository_arg(options)
  let repository = match explicit {
    Some(_) =>
      match resolve_repository_context(repo?=explicit) {
        Ok(value) => Some(value)
        Err(error) => return error
      }
    None =>
      // `gh browse` normally uses the current checkout. Keep the useful
      // default homepage when no git remote is available, matching the
      // command's URL-opening behavior without making browser use network
      // dependent.
      match resolve_repository_context() {
        Ok(value) => Some(value)
        Err(_) => None
      }
  }
  let url = match business_browse_url(options, repository) {
    Ok(value) => value
    Err(error) => return error
  }
  let host = repository.map(value => value.host())
  let command = configured_browser(host)
  let result = open_browser(command, url)
  match result {
    Ok(value) if value.exit_code() == 0 => @github_cli.success(stdout="")
    Ok(_) => @github_cli.failure(message="browser command failed")
    Err(ProcessAdapterError::TimedOut) =>
      @github_cli.failure(message="browser command timed out")
    Err(_) => @github_cli.failure(message="could not open browser")
  }
}

///|
/// Static command help keeps `gh repo --help` and friends deterministic while
/// avoiding a network call. Detailed flag acceptance remains in the command
/// request builder, which is covered by fixture tests.
fn business_help(command : String) -> String {
  match command {
    "repo" =>
      "Work with GitHub repositories.\n\nUSAGE\n  gh repo <command>\n\nCOMMANDS\n  create  clone  delete  edit  fork  list  rename  set-default  sync  view"
    "status" =>
      "Show the status of relevant notifications.\n\nUSAGE\n  gh status"
    "issue" =>
      "Manage GitHub issues.\n\nUSAGE\n  gh issue <command>\n\nCOMMANDS\n  close  create  delete  develop  edit  list  lock  reopen  status  transfer  unlock  view"
    "pr" =>
      "Manage GitHub pull requests.\n\nUSAGE\n  gh pr <command>\n\nCOMMANDS\n  checkout  checks  close  create  diff  edit  list  lock  merge  ready  reopen  review  status  unlock  view"
    "release" =>
      "Manage GitHub releases.\n\nUSAGE\n  gh release <command>\n\nCOMMANDS\n  create  delete  delete-asset  download  edit  list  upload  verify  verify-asset  view"
    "run" =>
      "View details about workflow runs.\n\nUSAGE\n  gh run <command>\n\nCOMMANDS\n  cancel  delete  download  list  rerun  view  watch"
    "search" =>
      "Search for repositories, issues, and pull requests.\n\nUSAGE\n  gh search <command>"
    "ruleset" =>
      "View repository rulesets.\n\nUSAGE\n  gh ruleset <command>\n\nCOMMANDS\n  check  list  view"
    "skill" | "skills" =>
      "Manage GitHub CLI skills.\n\nUSAGE\n  gh skill <command>"
    "preview" => "Preview GitHub CLI features.\n\nUSAGE\n  gh preview <command>"
    "accessibility" =>
      "Configure accessibility options.\n\nUSAGE\n  gh accessibility <command>"
    "send-telemetry" => "Send GitHub CLI telemetry."
    _ => "Run the GitHub " + command + " command."
  }
}

///|
fn completion_output(shell : String?) -> @github_cli.Output {
  match shell.unwrap_or("bash") {
    "bash" =>
      @github_cli.success(
        stdout="# gh completion (bash)\ncomplete -W 'api auth config alias repo status issue pr discussion release run workflow actions search org project label gist gpg-key ssh-key secret variable cache browse licenses ruleset skill skills preview accessibility send-telemetry' gh\n",
      )
    "zsh" =>
      @github_cli.success(
        stdout="#compdef gh\n_arguments '*:command:(api auth config alias repo status issue pr discussion release run workflow actions search org project label gist gpg-key ssh-key secret variable cache browse licenses ruleset skill skills preview accessibility send-telemetry)'\n",
      )
    "fish" =>
      @github_cli.success(
        stdout="complete -c gh -f -a 'api auth config alias repo status issue pr discussion release run workflow actions search org project label gist gpg-key ssh-key secret variable cache browse licenses ruleset skill skills preview accessibility send-telemetry'\n",
      )
    _ => @github_cli.failure(message="unsupported completion shell")
  }
}
