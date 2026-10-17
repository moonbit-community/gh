///|
/// Validated repository identity. Parsing is independent of the environment
/// and git; a branch is attached only when a command requires one.
pub struct RepositoryContext {
  host : String
  owner : String
  name : String
  branch : String?
} derive(Debug, Eq)

///|
pub extend RepositoryContext with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RepositoryContext with Eq::{not_equal, equal}

///|
pub(all) enum RepositoryError {
  InvalidRepository
  InvalidRemote
  MissingBranch
} derive(Debug, Eq)

///|
pub extend RepositoryError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend RepositoryError with Eq::{not_equal, equal}

///|
pub fn RepositoryContext::host(self : RepositoryContext) -> String {
  self.host
}

///|
pub fn RepositoryContext::owner(self : RepositoryContext) -> String {
  self.owner
}

///|
pub fn RepositoryContext::name(self : RepositoryContext) -> String {
  self.name
}

///|
pub fn RepositoryContext::branch(self : RepositoryContext) -> String? {
  self.branch
}

///|
pub fn RepositoryContext::full_name(self : RepositoryContext) -> String {
  self.owner + "/" + self.name
}

///|
/// Accept OWNER/REPO, HOST/OWNER/REPO, or an HTTP(S) repository URL.
/// Hostnames are case-insensitive; repository and owner spelling is retained.
pub fn RepositoryContext::parse(
  value : String,
  default_host~ : String = "github.com",
) -> Result[RepositoryContext, RepositoryError] {
  if value.has_prefix("https://") || value.has_prefix("http://") {
    return RepositoryContext::from_remote(value).map_err(_ => InvalidRepository)
  }
  let pieces = value.split("/").map(x => x.to_owned()).collect()
  match pieces[:] {
    [owner, name] => repository_identity(default_host, owner, name)
    [host, owner, name] => repository_identity(host, owner, name)
    _ => Err(InvalidRepository)
  }
}

///|
/// Parse HTTP(S), ssh://, git:// and scp-style git remotes without invoking
/// git or accepting local filesystem paths. SSH transport ports do not become
/// API ports. Percent-escaped path segments are deliberately rejected.
pub fn RepositoryContext::from_remote(
  value : String,
) -> Result[RepositoryContext, RepositoryError] {
  guard !value.is_empty() &&
    value.length() <= 8192 &&
    value.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) &&
    !value.contains_char('?') &&
    !value.contains_char('#') &&
    !value.contains_char('\\') else {
    return Err(InvalidRemote)
  }
  let (host, path) = if value.split_once("://") is Some((scheme, rest)) {
    guard scheme == "https" ||
      scheme == "http" ||
      scheme == "ssh" ||
      scheme == "git" else {
      return Err(InvalidRemote)
    }
    guard rest.split_once("/") is Some((authority, path)) else {
      return Err(InvalidRemote)
    }
    let authority = if authority.split_once("@") is Some((user, authority)) {
      // HTTP credentials are never part of a repository identity. Reject
      // them rather than carrying a possibly secret URL into diagnostics.
      guard scheme == "ssh" && repository_user(user.to_owned()) else {
        return Err(InvalidRemote)
      }
      authority.to_owned()
    } else {
      authority.to_owned()
    }
    guard repository_host(authority) is Some(authority) else {
      return Err(InvalidRemote)
    }
    let host = if scheme == "ssh" {
      authority.split_once(":").map_or(authority, pair => pair.0.to_owned())
    } else {
      authority
    }
    (host, path.to_owned())
  } else {
    guard value.split_once(":") is Some((authority, path)) else {
      return Err(InvalidRemote)
    }
    let host = if authority.split_once("@") is Some((user, host)) {
      guard repository_user(user.to_owned()) else { return Err(InvalidRemote) }
      host.to_owned()
    } else {
      authority.to_owned()
    }
    guard !host.contains_char('/') && !path.has_prefix("/") else {
      return Err(InvalidRemote)
    }
    (host, path.to_owned())
  }
  let path = path.strip_suffix("/").map_or(path, x => x.to_owned())
  let pieces = path.split("/").map(x => x.to_owned()).collect()
  match pieces[:] {
    [owner, name] =>
      repository_identity(host, owner, name).map_err(_ => InvalidRemote)
    _ => Err(InvalidRemote)
  }
}

///|
pub fn RepositoryContext::with_branch(
  self : RepositoryContext,
  branch : String,
) -> Result[RepositoryContext, RepositoryError] {
  guard !branch.is_empty() &&
    branch.length() <= 4096 &&
    branch.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) else {
    return Err(MissingBranch)
  }
  Ok({ ..self, branch: Some(branch), })
}

///|
/// Substitute exactly the gh API placeholders. Values remain raw so the
/// caller can choose field serialization or path encoding after substitution.
pub fn RepositoryContext::substitute(
  self : RepositoryContext,
  source : String,
) -> Result[String, RepositoryError] {
  let source = source
    .replace_all(old="{owner}", new=self.owner)
    .replace_all(old="{repo}", new=self.name)
  if source.contains("{branch}") {
    match self.branch {
      Some(branch) => Ok(source.replace_all(old="{branch}", new=branch))
      None => Err(MissingBranch)
    }
  } else {
    Ok(source)
  }
}

///|
fn repository_identity(
  host : String,
  owner : String,
  name : String,
) -> Result[RepositoryContext, RepositoryError] {
  guard repository_host(host) is Some(host) else {
    return Err(InvalidRepository)
  }
  let name = name.strip_suffix(".git").map_or(name, x => x.to_owned())
  guard repository_component(owner) && repository_component(name) else {
    return Err(InvalidRepository)
  }
  Ok({ host, owner, name, branch: None, })
}

///|
fn repository_component(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 255 &&
  value != "." &&
  value != ".." &&
  value
  .iter()
  .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.'))
}

///|
fn repository_user(value : String) -> Bool {
  !value.is_empty() &&
  value
  .iter()
  .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.'))
}

///|
fn repository_host(value : String) -> String? {
  guard !value.is_empty() && value.length() <= 300 else { return None }
  let (host, port) = match value.split_once(":") {
    Some((host, port)) => (host.to_owned(), Some(port.to_owned()))
    None => (value, None)
  }
  guard !host.is_empty() && host.length() <= 253 else { return None }
  for label in host.split(".") {
    guard !label.is_empty() &&
      label.length() <= 63 &&
      !label.has_prefix("-") &&
      !label.has_suffix("-") &&
      label.iter().all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-')) else {
      return None
    }
  }
  if port is Some(port) {
    guard !port.is_empty() &&
      port.length() <= 5 &&
      port.iter().all(ch => ch is ('0'..<='9')) else {
      return None
    }
    let mut number = 0
    for ch in port {
      number = number * 10 + ch.to_int() - 48
    }
    guard number > 0 && number <= 65535 else { return None }
  }
  Some(value.to_lower())
}
