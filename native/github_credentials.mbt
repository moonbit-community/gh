///|
/// Resolve GitHub authentication without exposing credential material in an
/// output or error. Environment credentials are selected before any config
/// directory lookup, matching gh's process-level override behavior.
pub async fn resolve_github_auth(
  environment : @github_auth.Environment,
) -> Result[@github_auth.Config, @github_cli.Output] {
  let direct = match @github_auth.resolve(environment) {
    Ok(config) => config
    Err(_) =>
      return Err(
        @github_cli.failure(
          message="invalid GitHub authentication configuration",
          exit_code=4,
        ),
      )
  }
  if direct.token() is Some(_) {
    return Ok(direct)
  }
  let path = config_hosts_path()
  match path {
    None => Ok(direct)
    Some(path) => resolve_github_auth_file(environment, path)
  }
}

///|
/// Resolve authentication for a command that can use the host keyring. The
/// plain resolver intentionally stops at hosts.yml so it remains deterministic
/// and portable; executable commands opt into this helper with their native
/// CredentialBackend. Environment variables and an explicit hosts.yml token
/// always win over keyring data.
pub async fn resolve_github_auth_with_backend(
  environment : @github_auth.Environment,
  backend : CredentialBackend,
) -> Result[@github_auth.Config, @github_cli.Output] {
  let direct = match resolve_github_auth(environment) {
    Ok(config) => config
    Err(error) => return Err(error)
  }
  if direct.token() is Some(_) {
    return Ok(direct)
  }
  let path = match config_hosts_path() {
    Some(path) => path
    None => return Ok(direct)
  }
  let hosts = local_read_yaml(path) catch { _ => return Ok(direct) }
  let values = match hosts.get(direct.host()) {
    Some(LocalYaml::Mapping(values)) => values
    _ => return Ok(direct)
  }
  let token = match auth_active_name(values) {
    Some(user) => backend.read_async(direct.host(), user)
    None => None
  }
  match token {
    Some(token) => {
      let maybe_token : String? = Some(token)
      match
        @github_auth.resolve(
          @github_auth.Environment::new(gh_host=direct.host()),
          stored_token?=maybe_token,
        ) {
        Ok(config) => Ok(config)
        Err(_) => Ok(direct)
      }
    }
    None => Ok(direct)
  }
}

///|
/// Resolve from an explicitly selected hosts.yml path. The path is supplied by
/// the native boundary and never appears in a user-facing diagnostic.
pub async fn resolve_github_auth_file(
  environment : @github_auth.Environment,
  path : String,
) -> Result[@github_auth.Config, @github_cli.Output] {
  let direct = match @github_auth.resolve(environment) {
    Ok(config) => config
    Err(_) =>
      return Err(
        @github_cli.failure(
          message="invalid GitHub authentication configuration",
          exit_code=4,
        ),
      )
  }
  if direct.token() is Some(_) {
    return Ok(direct)
  }
  guard !path.is_empty() && path.length() <= 4096 else {
    return Err(
      @github_cli.failure(message="invalid GitHub config path", exit_code=4),
    )
  }
  let source = try {
    if !@fs.exists(path) {
      return Ok(direct)
    }
    guard @fs.kind(path) == @fs.Regular && @fs.file_size(path) <= 1048576L else {
      return Err(
        @github_cli.failure(message="invalid GitHub credentials", exit_code=4),
      )
    }
    @fs.read_file(path).text()
  } catch {
    err if @async.is_being_cancelled() => raise err
    _ =>
      return Err(
        @github_cli.failure(
          message="cannot read GitHub credentials",
          exit_code=4,
        ),
      )
  }
  resolve_github_auth_source(environment, source)
}

///|
/// Pure credential-file integration point used by fixture tests and callers
/// that already own file I/O. The parser itself never reads another host's
/// token and does not serialize the selected value.
pub fn resolve_github_auth_source(
  environment : @github_auth.Environment,
  source : String,
) -> Result[@github_auth.Config, @github_cli.Output] {
  match @github_auth.resolve_with_hosts(environment, source) {
    Ok(config) => Ok(config)
    Err(@github_auth.InvalidHost)
    | Err(@github_auth.InvalidConfig)
    | Err(@github_auth.InvalidToken) =>
      Err(
        @github_cli.failure(message="invalid GitHub credentials", exit_code=4),
      )
  }
}

///|
/// Choose gh's config file according to its documented environment roots.
/// Missing roots are treated as an unauthenticated configuration, not an
/// error. Filesystem access remains entirely within the native adapter.
fn config_hosts_path() -> String? {
  let root = @env.get_env_var("GH_CONFIG_DIR").map(value => {
    value.trim().to_owned()
  })
  match root {
    Some(value) if !value.is_empty() => Some(value + "/hosts.yml")
    _ =>
      match @env.get_env_var("XDG_CONFIG_HOME") {
        Some(value) if !value.trim().is_empty() =>
          Some(value.trim().to_owned() + "/gh/hosts.yml")
        _ =>
          @env.get_env_var("HOME").map(value => {
            value.trim().to_owned() + "/.config/gh/hosts.yml"
          })
      }
  }
}

///|
async test "native GitHub credential source fixture never leaks token" {
  let source =
    #|github.com:
    #|  user: fixture
    #|  oauth_token: fixture-token
  let environment = @github_auth.Environment::new(gh_host="github.com")
  let result = resolve_github_auth_source(environment, source)
  guard result is Ok(config) else { fail("fixture credentials were rejected") }
  assert_eq(config.token(), Some("fixture-token"))
  let output = match result {
    Ok(_) => @github_cli.success(stdout="ok")
    Err(output) => output
  }
  assert_false(output.stdout().contains("fixture-token"))
  assert_false(output.stderr().contains("fixture-token"))
}

///|
test "native GitHub credential source keeps environment precedence" {
  let environment = @github_auth.Environment::new(
    gh_host="github.com",
    gh_token="environment-token",
  )
  let result = resolve_github_auth_source(
    environment, "github.com:\n  oauth_token: file-token",
  )
  guard result is Ok(config) else {
    fail("environment credential was rejected")
  }
  assert_eq(config.token(), Some("environment-token"))
}

///|
async test "missing credential files resolve without raising" {
  let directory = @fs.tmpdir(prefix="gh-credential-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let result = resolve_github_auth_file(
    @github_auth.Environment::new(),
    directory + "/missing/hosts.yml",
  )
  guard result is Ok(config) else {
    fail("missing file must be unauthenticated")
  }
  assert_eq(config.token(), None)
}

///|
async test "environment credential bypasses every file operation" {
  let environment = @github_auth.Environment::new(gh_token="fixture-env-token")
  for path in ["", "/unreadable/fixture/hosts.yml", "/"] {
    let result = resolve_github_auth_file(environment, path)
    guard result is Ok(config) else {
      fail("environment token must bypass disk")
    }
    assert_eq(config.token(), Some("fixture-env-token"))
  }
  let source = resolve_github_auth_source(environment, "invalid: [yaml")
  guard source is Ok(config) else { fail("environment token must bypass YAML") }
  assert_eq(config.token(), Some("fixture-env-token"))
}

///|
async test "directories and malformed credentials fail with sanitized output" {
  let directory = @fs.tmpdir(prefix="gh-credential-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let environment = @github_auth.Environment::new()
  guard resolve_github_auth_file(environment, directory) is Err(output) else {
    fail("credential directory must be rejected")
  }
  assert_eq(output.exit_code(), 4)
  assert_false(output.stderr().contains(directory))
  let path = directory + "/hosts.yml"
  @fs.write_file(path, "github.com:\n  oauth_token: fixture-secret value\n")
  guard resolve_github_auth_file(environment, path) is Err(output) else {
    fail("malformed token must be rejected")
  }
  assert_false(output.stderr().contains("fixture-secret"))
}
