///|
fn auth_source(source : @github_auth.TokenSource) -> String {
  match source {
    @github_auth.GhToken => "GH_TOKEN"
    @github_auth.GithubToken => "GITHUB_TOKEN"
    @github_auth.GhEnterpriseToken => "GH_ENTERPRISE_TOKEN"
    @github_auth.GithubEnterpriseToken => "GITHUB_ENTERPRISE_TOKEN"
    @github_auth.Stored => "hosts.yml"
    @github_auth.Unspecified => ""
  }
}

///|
fn auth_native_transport(
  config : @github_auth.Config,
) -> @github.Transport raise {
  let origin = if config.host() == "github.com" {
    "https://api.github.com"
  } else {
    "https://" + config.host()
  }
  let raw = @transport.native_raw_transport(base_url=origin)
  @github.Transport::new(send=request => {
    guard request.url().strip_prefix(origin) is Some(path) else {
      return Err(@github.TransportError::Failed)
    }
    let response = raw.send(
      @gh.RawRequest::new(
        verb=request.verb(),
        path=path.to_owned(),
        body?=request.body(),
        headers=request.headers(),
      ),
    ) catch {
      err if @async.is_being_cancelled() => raise err
      _ => return Err(@github.TransportError::Failed)
    }
    Ok(
      @github.RawResponse::new(
        status=response.status(),
        headers=response.headers(),
        body=response.body(),
      ),
    )
  })
}

///|
/// Execute `auth status` for the selected active account and `auth token`.
/// Network status is verified with /user; merely finding a token never marks
/// an account as authenticated. Explicit token export is the only default
/// command path that emits credentials. All diagnostics remain sanitized.
pub async fn github_auth_command(
  args : Array[String],
  environment? : @github_auth.Environment,
  config_dir? : String,
  transport? : @github.Transport,
  credential_backend? : CredentialBackend,
  oauth_adapter? : OAuthAdapter,
) -> @github_cli.Output {
  github_auth_local(
    args,
    environment.unwrap_or_else(() => @github_auth.Environment::from_process()),
    config_dir,
    transport,
    credential_backend,
    oauth_adapter,
  ) catch {
    err if @async.is_being_cancelled() => raise err
    _ => local_error("failed to read or verify GitHub authentication")
  }
}

///|
async fn github_auth_local(
  args : Array[String],
  environment : @github_auth.Environment,
  directory : String?,
  transport : @github.Transport?,
  credential_backend : CredentialBackend?,
  oauth_adapter : OAuthAdapter?,
) -> @github_cli.Output {
  guard args.get(0) is Some(command) else {
    return local_error("this auth command is not implemented")
  }
  if command == "git-credential" {
    return github_auth_git_credential(
      args, environment, directory, credential_backend,
    )
  }
  if command == "login" || command == "refresh" {
    let directory = local_config_dir(directory) catch {
      _ => return local_error("failed to read or write GitHub credentials")
    }
    return github_auth_login_local(
      command, args, environment, directory, credential_backend, oauth_adapter,
    )
  }
  if command == "switch" {
    let directory = local_config_dir(directory) catch {
      _ => return local_error("failed to read or write GitHub credentials")
    }
    return github_auth_switch_local(args, environment, directory)
  }
  if command == "logout" {
    let directory = local_config_dir(directory) catch {
      _ => return local_error("failed to read or write GitHub credentials")
    }
    return github_auth_logout_local(
      args, environment, directory, credential_backend,
    )
  }
  if command == "setup-git" {
    return github_auth_setup_git_local(args, environment)
  }
  guard command is ("status" | "token") else {
    return local_error("this auth command is not implemented")
  }
  let mut host : String? = None
  let mut user : String? = None
  let mut show_token = false
  let mut json_output = false
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    index += 1
    if arg is ("--hostname" | "-h" | "--user" | "-u" | "--json") {
      guard args.get(index) is Some(value) else {
        return local_error("flag needs an argument: " + arg)
      }
      index += 1
      match arg {
        "--hostname" | "-h" => host = Some(value)
        "--user" | "-u" if command == "token" => user = Some(value)
        "--json" if command == "status" && value == "hosts" =>
          json_output = true
        _ => return local_error("unsupported auth flag or field")
      }
    } else if arg.has_prefix("--hostname=") {
      host = Some(arg[11:].to_owned())
    } else if arg is ("--active" | "-a") && command == "status" {
      ()
    } else if arg is ("--show-token" | "-t") && command == "status" {
      show_token = true
    } else {
      return local_error("unknown flag: " + arg)
    }
  }
  let environment = match host {
    Some(host) => environment.with_host(host)
    None => environment
  }
  // `auth status --json hosts` enumerates every stored account when no
  // process-level token or explicit host is forcing a single selection.
  if command == "status" && json_output && host is None && user is None {
    match @github_auth.resolve(environment) {
      Ok(config) if config.token_source() is @github_auth.Unspecified =>
        return github_auth_status_all(directory, transport, credential_backend)
      _ => ()
    }
  }
  let mut token_source_override : String? = None
  let config = if user is Some(user) {
    let direct = match @github_auth.resolve(environment) {
      Ok(config) => config
      Err(_) =>
        return local_error(
          "invalid GitHub authentication configuration",
          code=4,
        )
    }
    let hosts = local_read_yaml(local_config_dir(directory) + "/hosts.yml")
    let stored = match hosts.get(direct.host()) {
      Some(Mapping(host)) =>
        match host.get("users") {
          Some(Mapping(users)) =>
            match users.get(user) {
              Some(Mapping(account)) => local_get(account, "oauth_token")
              _ => None
            }
          _ =>
            if local_get(host, "user") == Some(user) {
              local_get(host, "oauth_token")
            } else {
              None
            }
        }
      _ => None
    }
    let stored = match stored {
      Some(token) => Some(token)
      None =>
        match credential_backend {
          Some(backend) => {
            let token = backend.read_async(direct.host(), user)
            if token is Some(_) {
              token_source_override = Some("keyring")
            }
            token
          }
          None => None
        }
    }
    match
      @github_auth.resolve(
        @github_auth.Environment::new(gh_host=direct.host()),
        stored_token?=stored,
      ) {
      Ok(config) => config
      Err(_) => return local_error("invalid GitHub credentials", code=4)
    }
  } else {
    let result = match directory {
      Some(directory) =>
        resolve_github_auth_file(environment, directory + "/hosts.yml")
      None => resolve_github_auth(environment)
    }
    match result {
      Ok(config) if config.token() is Some(_) => config
      Ok(config) => {
        let stored = match credential_backend {
          Some(backend) => {
            let path = match directory {
              Some(directory) => directory + "/hosts.yml"
              None => config_hosts_path().unwrap_or("")
            }
            if path.is_empty() {
              None
            } else {
              let hosts = local_read_yaml(path)
              match hosts.get(config.host()) {
                Some(Mapping(values)) =>
                  match auth_active_name(values) {
                    Some(user) => {
                      let token = backend.read_async(config.host(), user)
                      if token is Some(_) {
                        token_source_override = Some("keyring")
                      }
                      token
                    }
                    None => None
                  }
                _ => None
              }
            }
          }
          None => None
        }
        match
          @github_auth.resolve(
            @github_auth.Environment::new(gh_host=config.host()),
            stored_token?=stored,
          ) {
          Ok(with_token) => with_token
          Err(_) => config
        }
      }
      Err(output) => return output
    }
  }
  if command == "token" {
    return match config.token() {
      Some(token) => @github_cli.success(stdout=token + "\n")
      None =>
        local_error(
          "no oauth token found for " +
          config.host() +
          (match user {
            Some(user) => " account " + user
            None => ""
          }),
        )
    }
  }
  guard config.token() is Some(token) else {
    return @github_cli.Output::new(
      stdout=if json_output { "{\"hosts\":{}}\n" } else { "" },
      stderr="You are not logged into any GitHub hosts. To log in, run: gh auth login\n",
      exit_code=if json_output { 0 } else { 1 },
    )
  }
  let transport = match transport {
    Some(transport) => transport
    None => auth_native_transport(config)
  }
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(
        base_url=config.rest_base_url(),
        graphql_url=config.graphql_url(),
        token~,
      ),
      transport~,
    ) {
    Ok(client) => client
    Err(_) => return local_error("invalid GitHub client configuration")
  }
  let result = client.request(@github.Request::new(verb="GET", path="/user"))
  let mut login = ""
  let mut scopes : String? = None
  let mut error : String? = None
  match result {
    Ok(response) => {
      scopes = response.header("x-oauth-scopes")
      let value = match response.body_text() {
        Ok(text) => @json.parse(text) catch { _ => Json::null() }
        Err(_) => Json::null()
      }
      match value {
        { "login": String(value), .. } if !value.is_empty() &&
          !value.contains(token) &&
          value.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) =>
          login = value
        _ =>
          error = Some(
            "authentication response did not contain a valid account",
          )
      }
    }
    Err(failure) =>
      error = Some(
        match failure.status() {
          Some(status) => "HTTP " + status.to_string()
          None => "unable to verify authentication"
        },
      )
  }
  let source = token_source_override.unwrap_or(
    auth_source(config.token_source()),
  )
  let visible_token = if show_token {
    token
  } else {
    "************************"
  }
  if json_output {
    let account : Map[String, Json] = {
      "host": Json(config.host()),
      "active": Json(true),
      "login": Json(login),
      "tokenSource": Json(source),
      "token": Json(visible_token),
      "gitProtocol": Json("https"),
      "state": Json(if error is Some(_) { "error" } else { "success" }),
    }
    if error is Some(error) {
      account["error"] = Json(error)
    }
    let hosts : Map[String, Json] = Map([])
    hosts[config.host()] = Json([Json(account)])
    return @github_cli.success(
      stdout=({ "hosts": Json(hosts) } : Json).stringify() + "\n",
    )
  }
  if error is Some(error) {
    return local_error(
      config.host() +
      "\n  X Failed to log in using token (" +
      source +
      ")\n  - Active account: true\n  - " +
      error,
    )
  }
  let output = StringBuilder()
  output.write_string(
    config.host() +
    "\n  ✓ Logged in to " +
    config.host() +
    " account " +
    login +
    " (" +
    source +
    ")\n  - Active account: true\n  - Git operations protocol: https\n  - Token: " +
    visible_token +
    "\n",
  )
  if scopes is Some(scopes) &&
    !scopes.contains(token) &&
    scopes.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) {
    output.write_string("  - Token scopes: '" + scopes + "'\n")
  }
  @github_cli.success(stdout="", stderr=output.to_string())
}

///|
/// Configure Git's credential helper without putting a token in argv.
/// The command is passed directly to git; callers embedding the Native
/// package can exercise the same behavior with `github_auth_setup_git` and an
/// injected runner.
async fn github_auth_setup_git_local(
  args : Array[String],
  environment : @github_auth.Environment,
) -> @github_cli.Output {
  github_auth_setup_git(args, environment)
}

///|
/// Public fixture seam for `auth setup-git`.
pub async fn github_auth_setup_git(
  args : Array[String],
  environment : @github_auth.Environment,
  runner? : async (Array[String]) -> Result[
    NativeProcessResult,
    ProcessAdapterError,
  ],
) -> @github_cli.Output {
  let mut explicit_host : String? = None
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    index += 1
    if arg is ("--hostname" | "-h") {
      guard args.get(index) is Some(value) else {
        return local_error("flag needs an argument: " + arg)
      }
      explicit_host = Some(value)
      index += 1
    } else if arg.has_prefix("--hostname=") {
      explicit_host = Some(arg[11:].to_owned())
    } else {
      return local_error("unknown flag: " + arg)
    }
  }
  let host = auth_host_name(environment, explicit_host) catch {
    _ => return local_error("invalid hostname", code=4)
  }
  let helper = "!gh auth git-credential"
  let args = [
    "config",
    "--global",
    "credential.https://" + host + ".helper",
    helper,
  ]
  let result = match runner {
    Some(run) => run(args)
    None => run_native_process("git", args)
  }
  match result {
    Ok(value) if value.exit_code() == 0 =>
      @github_cli.success(
        stdout="✓ Configured git protocol for " + host + "\n",
      )
    Ok(value) => {
      let text = @utf8.decode(value.stderr()) catch { _ => "" }
      local_error(
        "git config failed" +
        (if !text.trim().is_empty() {
          ": " + text.trim().to_owned()
        } else {
          ""
        }),
      )
    }
    Err(ProcessAdapterError::TimedOut) => local_error("git config timed out")
    Err(_) => local_error("failed to configure git")
  }
}

///|
/// Parse the local, non-network part of `auth login` and `auth refresh`.
/// `--with-token` is deterministic and works without an OAuth host
/// integration. Interactive/device flows are delegated to OAuthAdapter.
async fn github_auth_login_local(
  command : String,
  args : Array[String],
  environment : @github_auth.Environment,
  directory : String,
  credential_backend : CredentialBackend?,
  oauth_adapter : OAuthAdapter?,
) -> @github_cli.Output {
  let mut explicit_host : String? = None
  let mut explicit_user : String? = None
  let mut with_token = false
  let mut scopes = "repo,read:org,gist"
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    index += 1
    if arg is ("--hostname" | "-h" | "--user" | "-u" | "--scopes") {
      guard args.get(index) is Some(value) else {
        return local_error("flag needs an argument: " + arg)
      }
      index += 1
      if arg is ("--hostname" | "-h") {
        explicit_host = Some(value)
      } else if arg is ("--user" | "-u") {
        explicit_user = Some(value)
      } else {
        scopes = value
      }
    } else if arg.has_prefix("--hostname=") {
      explicit_host = Some(arg[11:].to_owned())
    } else if arg.has_prefix("--user=") {
      explicit_user = Some(arg[7:].to_owned())
    } else if arg.has_prefix("--scopes=") {
      scopes = arg[9:].to_owned()
    } else if arg == "--with-token" {
      with_token = true
    } else if arg is ("--web" | "--clipboard" | "--insecure-storage") {
      ()
    } else {
      return local_error("unknown flag: " + arg)
    }
  }
  let environment = match explicit_host {
    Some(host) => environment.with_host(host)
    None => environment
  }
  let host = match @github_auth.resolve(environment) {
    Ok(config) => config.host()
    Err(_) => return local_error("invalid hostname", code=4)
  }
  let path = directory + "/hosts.yml"
  let root = local_read_yaml(path)
  let existing = match root.get(host) {
    Some(Mapping(values)) => values
    _ => Map([])
  }
  let user = match explicit_user {
    Some(value) if !value.is_empty() => value
    None => auth_active_name(existing).unwrap_or("default")
    _ => return local_error("invalid account name")
  }
  if command == "refresh" && auth_account_names(existing).is_empty() {
    return local_error("not logged in to " + host)
  }
  let token = if with_token {
    let text = @stdio.stdin.read_all().text() catch {
        _ => return local_error("failed to read token")
      }
    let value = text.trim().to_owned()
    guard !value.is_empty() else { return local_error("token is required") }
    value
  } else {
    let adapter = match oauth_adapter {
      Some(value) => value
      None => return local_error("OAuth login is unavailable in this host")
    }
    match adapter.authorize_async(host, scopes) {
      Ok(value) => value
      Err(OAuthError::Cancelled) => return @github_cli.Output::new(exit_code=2)
      Err(_) => return local_error("OAuth authorization failed")
    }
  }
  match
    @github_auth.resolve(
      @github_auth.Environment::new(gh_host=host),
      stored_token=token,
    ) {
    Ok(_) => ()
    Err(_) => return local_error("invalid GitHub token", code=4)
  }
  let stored_in_backend = match credential_backend {
    Some(backend) => backend.write_async(host, user, token)
    None => false
  }
  let account : Map[String, LocalYaml] = match existing.get("users") {
    Some(Mapping(users)) =>
      match users.get(user) {
        Some(Mapping(values)) => values
        _ => Map([])
      }
    _ => Map([])
  }
  let users : Map[String, LocalYaml] = match existing.get("users") {
    Some(Mapping(values)) => values
    _ => Map([])
  }
  if !stored_in_backend {
    account["oauth_token"] = Scalar(token)
  } else {
    account.remove("oauth_token")
  }
  users[user] = Mapping(account)
  existing["users"] = Mapping(users)
  existing["user"] = Scalar(user)
  if stored_in_backend {
    existing.remove("oauth_token")
  } else {
    existing["oauth_token"] = Scalar(token)
  }
  root[host] = Mapping(existing)
  local_write_yaml(directory, "hosts.yml", root) catch {
    _ => return local_error("failed to write GitHub credentials")
  }
  @github_cli.success(
    stdout="✓ Logged in to " + host + " account " + user + "\n",
  )
}

///|
/// Verify and render every account in hosts.yml. This is intentionally kept
/// separate from the selected-account status path so `GH_TOKEN` precedence
/// and explicit `--hostname/--user` remain deterministic.
async fn github_auth_status_all(
  directory : String?,
  transport : @github.Transport?,
  credential_backend : CredentialBackend?,
) -> @github_cli.Output {
  let path = match directory {
    Some(directory) => directory + "/hosts.yml"
    None =>
      match config_hosts_path() {
        Some(path) => path
        None => return @github_cli.success(stdout="{\"hosts\":{}}\n")
      }
  }
  let root = local_read_yaml(path) catch {
    _ => return @github_cli.success(stdout="{\"hosts\":{}}\n")
  }
  let hosts : Map[String, Json] = Map([])
  for host, value in root {
    match value {
      Mapping(values) => {
        let active = auth_active_name(values)
        let accounts : Array[Json] = []
        for user in auth_account_names(values) {
          let file_token = auth_account_token(values, user)
          let token = match file_token {
            Some(value) => Some(value)
            None =>
              match credential_backend {
                Some(backend) => backend.read_async(host, user)
                None => None
              }
          }
          let token_source = if file_token is Some(_) {
            "hosts.yml"
          } else if token is Some(_) {
            "keyring"
          } else {
            "hosts.yml"
          }
          let account : Map[String, Json] = {
            "host": Json(host),
            "active": Json::boolean(active == Some(user)),
            "login": Json(user),
            "tokenSource": Json(token_source),
            "gitProtocol": Json("https"),
          }
          match token {
            None => {
              account["state"] = Json("error")
              account["error"] = Json("no oauth token found")
            }
            Some(token) => {
              let maybe_config = match
                @github_auth.resolve(
                  @github_auth.Environment::new(gh_host=host),
                  stored_token=token,
                ) {
                Ok(config) => Some(config)
                Err(_) => {
                  account["state"] = Json("error")
                  account["error"] = Json("invalid credentials")
                  None
                }
              }
              match maybe_config {
                None => ()
                Some(config) => {
                  let selected_transport = match transport {
                    Some(value) => value
                    None => auth_native_transport(config)
                  }
                  let verified : @github.RawResponse? = match
                    @github.Client::new(
                      config=@github.ClientConfig::new(
                        base_url=config.rest_base_url(),
                        graphql_url=config.graphql_url(),
                        token~,
                      ),
                      transport=selected_transport,
                    ) {
                    Ok(client) =>
                      match
                        client.request(
                          @github.Request::new(verb="GET", path="/user"),
                        ) {
                        Ok(response) => Some(response)
                        Err(_) => None
                      }
                    Err(_) => None
                  }
                  match verified {
                    Some(response) => {
                      let login = match response.body_text() {
                        Ok(text) => {
                          let parsed : Json = @json.parse(text) catch {
                            _ => Json::null()
                          }
                          match parsed {
                            { "login": String(login), .. } => login
                            _ => user
                          }
                        }
                        Err(_) => user
                      }
                      account["login"] = Json(login)
                      account["state"] = Json("success")
                    }
                    None => {
                      account["state"] = Json("error")
                      account["error"] = Json("unable to verify authentication")
                    }
                  }
                }
              }
            }
          }
          accounts.push(Json(account))
        }
        if !accounts.is_empty() {
          hosts[host] = Json::array(accounts)
        }
      }
      _ => ()
    }
  }
  @github_cli.success(
    stdout=({ "hosts": Json::object(hosts) } : Json).stringify() + "\n",
  )
}
