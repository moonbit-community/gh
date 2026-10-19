///|
/// Return the account names represented by one hosts.yml host mapping.  gh
/// stores newer accounts under `users`; the older single-account layout is
/// still accepted for migration and fixture compatibility.
fn auth_account_names(values : Map[String, LocalYaml]) -> Array[String] {
  let names : Array[String] = []
  match values.get("users") {
    Some(Mapping(accounts)) =>
      for name, _ in accounts {
        names.push(name)
      }
    _ =>
      match local_get(values, "user") {
        Some(user) if !user.is_empty() => names.push(user)
        _ => ()
      }
  }
  names.sort()
  names
}

///|
fn auth_active_name(values : Map[String, LocalYaml]) -> String? {
  match local_get(values, "user") {
    Some(user) if !user.is_empty() => Some(user)
    _ => {
      let names = auth_account_names(values)
      names.get(0)
    }
  }
}

///|
fn auth_account_token(
  values : Map[String, LocalYaml],
  user : String,
) -> String? {
  match values.get("users") {
    Some(Mapping(accounts)) =>
      match accounts.get(user) {
        Some(Mapping(account)) => local_get(account, "oauth_token")
        _ => None
      }
    _ =>
      if local_get(values, "user") == Some(user) {
        local_get(values, "oauth_token")
      } else {
        None
      }
  }
}

///|
fn auth_account_cleanup_pending(
  values : Map[String, LocalYaml],
  user : String,
) -> Bool {
  match values.get("users") {
    Some(Mapping(accounts)) =>
      match accounts.get(user) {
        Some(Mapping(account)) =>
          local_get(account, "keyring_cleanup_pending") == Some("true")
        _ => false
      }
    _ =>
      local_get(values, "user") == Some(user) &&
      local_get(values, "keyring_cleanup_pending") == Some("true")
  }
}

///|
/// Keep the legacy top-level token synchronized with the selected account.
/// gh writes this compatibility field even when the canonical account lives
/// under `users`, so `auth token` and older clients see the same credential.
fn auth_select_account(values : Map[String, LocalYaml], user : String) -> Bool {
  guard auth_account_names(values).contains(user) else { return false }
  values["user"] = Scalar(user)
  match auth_account_token(values, user) {
    Some(token) => values["oauth_token"] = Scalar(token)
    None => values.remove("oauth_token")
  }
  true
}

///|
fn auth_parse_host_user(
  args : Array[String],
) -> (String?, String?) raise LocalConfigError {
  let mut host : String? = None
  let mut user : String? = None
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    index += 1
    if arg is ("--hostname" | "-h" | "--user" | "-u") {
      guard args.get(index) is Some(value) else { raise LocalConfigError }
      index += 1
      if arg is ("--hostname" | "-h") {
        host = Some(value)
      } else {
        user = Some(value)
      }
    } else if arg.has_prefix("--hostname=") {
      host = Some(arg[11:].to_owned())
    } else if arg.has_prefix("--user=") {
      user = Some(arg[7:].to_owned())
    } else {
      raise LocalConfigError
    }
  }
  (host, user)
}

///|
fn auth_host_name(
  environment : @github_auth.Environment,
  explicit : String?,
) -> String raise LocalConfigError {
  let host = match explicit {
    Some(value) => value
    None =>
      // Environment::with_host is intentionally opaque, so resolve once to
      // obtain the normalized default host without exposing its fields.
      match @github_auth.resolve(environment) {
        Ok(config) => config.host()
        Err(_) => raise LocalConfigError
      }
  }
  match @github_auth.resolve(@github_auth.Environment::new(gh_host=host)) {
    Ok(config) => config.host()
    Err(_) => raise LocalConfigError
  }
}

///|
/// Switch active account in hosts.yml. This pure local operation never calls
/// GitHub and is therefore safe to use with fixture credentials.
async fn github_auth_switch_local(
  args : Array[String],
  environment : @github_auth.Environment,
  directory : String,
) -> @github_cli.Output {
  let (explicit_host, explicit_user) = auth_parse_host_user(args) catch {
    _ => return local_error("unknown or incomplete auth switch flag")
  }
  let host = auth_host_name(environment, explicit_host) catch {
    _ => return local_error("invalid hostname")
  }
  let path = directory + "/hosts.yml"
  let root = local_read_yaml(path)
  let values = match root.get(host) {
    Some(Mapping(values)) => values
    _ => return local_error("not logged in to " + host)
  }
  let names = auth_account_names(values)
  guard !names.is_empty() else {
    return local_error("not logged in to " + host)
  }
  let user = match explicit_user {
    Some(user) => user
    None =>
      if names.length() == 1 {
        names[0]
      } else {
        let active = auth_active_name(values)
        let candidates = names.filter(name => Some(name) != active)
        if candidates.length() == 1 {
          candidates[0]
        } else {
          return local_error(
            "unable to determine which account to switch to, please specify `--hostname` and `--user`",
          )
        }
      }
  }
  guard names.contains(user) else {
    return local_error("not logged in to " + host + " account " + user)
  }
  ignore(auth_select_account(values, user))
  root[host] = Mapping(values)
  local_write_yaml(directory, "hosts.yml", root)
  @github_cli.success(
    stdout="✓ Switched active account for " + host + " to " + user + "\n",
  )
}

///|
/// Remove one account from hosts.yml. No revocation request is made; this is
/// deliberately equivalent to gh's local-only `auth logout` behavior.
async fn github_auth_logout_local(
  args : Array[String],
  environment : @github_auth.Environment,
  directory : String,
  credential_backend : CredentialBackend?,
) -> @github_cli.Output {
  let (explicit_host, explicit_user) = auth_parse_host_user(args) catch {
    _ => return local_error("unknown or incomplete auth logout flag")
  }
  let host = auth_host_name(environment, explicit_host) catch {
    _ => return local_error("invalid hostname")
  }
  let path = directory + "/hosts.yml"
  let root = local_read_yaml(path)
  let values = match root.get(host) {
    Some(Mapping(values)) => values
    _ =>
      return local_error(
        if explicit_user is Some(user) {
          "not logged in to " + host + " account " + user
        } else {
          "not logged in to " + host
        },
      )
  }
  let names = auth_account_names(values)
  guard !names.is_empty() else {
    return local_error("no accounts matched that criteria")
  }
  let active = auth_active_name(values)
  let user = match explicit_user {
    Some(user) => user
    None =>
      match active {
        Some(user) => user
        None => return local_error("no accounts matched that criteria")
      }
  }
  guard names.contains(user) else {
    return local_error("not logged in to " + host + " account " + user)
  }
  // Keep a keyring-backed account reference until deletion is confirmed.
  // Otherwise a failed helper would orphan a still-valid OS credential.
  // Plaintext accounts do not require an available OS keyring to log out.
  if auth_account_token(values, user) is None ||
    auth_account_cleanup_pending(values, user) {
    let deleted = match credential_backend {
      Some(backend) => backend.delete_async(host, user)
      None => false
    }
    guard deleted else {
      return local_error(
        "unable to remove credential from the system credential store; account configuration was kept",
      )
    }
  } else if credential_backend is Some(backend) {
    ignore(backend.delete_async(host, user))
  }
  match values.get("users") {
    Some(Mapping(accounts)) => {
      accounts.remove(user)
      if accounts.is_empty() {
        root.remove(host)
      } else {
        values["users"] = Mapping(accounts)
        let remaining = accounts.keys().collect()
        remaining.sort()
        let next = if active == Some(user) {
          remaining[0]
        } else {
          active.unwrap_or(remaining[0])
        }
        ignore(auth_select_account(values, next))
        root[host] = Mapping(values)
      }
    }
    _ => root.remove(host)
  }
  local_write_yaml(directory, "hosts.yml", root)
  @github_cli.success(
    stdout="✓ Logged out of " + host + " account " + user + "\n",
  )
}
