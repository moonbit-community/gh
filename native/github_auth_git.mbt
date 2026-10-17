///|
/// Git's credential helper protocol used by `gh auth setup-git`.
///
/// The helper only receives credentials over stdin/stdout. Tokens never enter
/// argv, traces, or diagnostics. `get` resolves the selected account, while
/// `store` and `erase` update the injected keyring backend when one is
/// available.
async fn github_auth_git_credential(
  args : Array[String],
  environment : @github_auth.Environment,
  directory : String?,
  backend : CredentialBackend?,
) -> @github_cli.Output {
  let input = @stdio.stdin.read_all().text() catch {
      _ => return local_error("failed to read credential request")
    }
  github_auth_git_credential_input(args, input, environment, directory, backend)
}

///|
async fn github_auth_git_credential_input(
  args : Array[String],
  input : String,
  environment : @github_auth.Environment,
  directory : String?,
  backend : CredentialBackend?,
) -> @github_cli.Output {
  // Git invokes helpers as `get`, `store`, or `erase`. Refuse extra argv
  // values so a malformed invocation cannot silently select a different
  // operation or hide a caller bug.
  guard args.length() <= 2 else {
    return local_error("unsupported credential operation")
  }
  let operation = args.get(1).unwrap_or("get")
  guard operation is ("get" | "store" | "erase") else {
    return local_error("unsupported credential operation")
  }
  let mut host : String? = None
  let mut user : String? = None
  let mut password : String? = None
  let mut protocol : String? = None
  for line in input.split("\n") {
    match line.split_once("=") {
      Some((name, value)) =>
        match name {
          "protocol" => protocol = Some(value.trim().to_owned())
          "host" => host = Some(value.trim().to_owned())
          "username" => user = Some(value.trim().to_owned())
          "password" => password = Some(value.to_owned())
          _ => ()
        }
      None => ()
    }
  }
  // `gh auth setup-git` installs an HTTPS helper. Git can still invoke a
  // helper for another protocol when a user has a broad credential rule; do
  // not return a GitHub token for that request.
  match protocol {
    Some(value) if value != "https" => return @github_cli.Output::new()
    _ => ()
  }
  let host = match host {
    Some(value) if !value.is_empty() => value
    _ =>
      match @github_auth.resolve(environment) {
        Ok(config) => config.host()
        Err(_) => return local_error("invalid hostname", code=4)
      }
  }
  let environment = environment.with_host(host)
  let config = match @github_auth.resolve(environment) {
    Ok(config) => config
    Err(_) => return local_error("invalid hostname", code=4)
  }
  let path = match directory {
    Some(value) => value + "/hosts.yml"
    None => config_hosts_path().unwrap_or("")
  }
  let active_user = match auth_git_active_user(path, config.host(), user) {
    Ok(value) => value
    Err(message) => return local_error(message)
  }
  match operation {
    "get" => {
      let token = match config.token() {
        Some(value) => Some(value)
        None =>
          match backend {
            Some(value) => value.read_async(config.host(), active_user)
            None => None
          }
      }
      match token {
        Some(token) =>
          @github_cli.success(
            stdout="protocol=https\nhost=" +
              config.host() +
              "\nusername=x-access-token\npassword=" +
              token +
              "\n\n",
          )
        None => @github_cli.Output::new()
      }
    }
    "store" => {
      let token = match password {
        Some(value) if !value.trim().is_empty() => value.trim().to_owned()
        _ => return @github_cli.Output::new()
      }
      match backend {
        Some(value) if value.write_async(config.host(), active_user, token) =>
          @github_cli.Output::new()
        _ => local_error("credential store is unavailable")
      }
    }
    "erase" =>
      match backend {
        Some(value) if value.delete_async(config.host(), active_user) =>
          @github_cli.Output::new()
        _ => @github_cli.Output::new()
      }
    _ => @github_cli.Output::new()
  }
}

///|
/// Resolve an account name from hosts.yml, preferring the protocol username
/// when Git supplies one and otherwise using the active account.
async fn auth_git_active_user(
  path : String,
  host : String,
  requested : String?,
) -> Result[String, String] {
  match requested {
    Some(value) if !value.is_empty() &&
      value != "x-access-token" &&
      value != "oauth2" => Ok(value)
    _ => {
      guard !path.is_empty() else { return Ok("default") }
      let root = local_read_yaml(path) catch { _ => return Ok("default") }
      match root.get(host) {
        Some(Mapping(values)) =>
          Ok(auth_active_name(values).unwrap_or("default"))
        _ => Ok("default")
      }
    }
  }
}
