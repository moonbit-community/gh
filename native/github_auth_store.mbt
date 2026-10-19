///|
/// A credential store supplied by a native embedding.
///
/// The GitHub package deliberately does not know how credentials are stored.
/// A desktop application may provide callbacks backed by the OS keyring,
/// while tests can provide an in-memory callback.  Callback arguments contain
/// only the host and account name; the returned value is consumed at the
/// authentication boundary and is never formatted by this package.
pub struct CredentialBackend {
  priv read_credential : (String, String) -> String?
  priv write_credential : (String, String, String) -> Bool
  priv delete_credential : (String, String) -> Bool
  // Async callbacks are optional so existing embedders that use an in-memory
  // synchronous backend keep source compatibility. Native keyring providers
  // (secret-tool, Git credential helpers, or host FFI) need async process I/O and use
  // these fields instead.
  priv read_async_credential : (async (String, String) -> String?)?
  priv write_async_credential : (async (String, String, String) -> Bool)?
  priv delete_async_credential : (async (String, String) -> Bool)?
}

///|
/// Construct a credential backend.  `write` and `delete` return whether the
/// operation was accepted by the backend.  Implementations should return
/// `false` for an unavailable keyring instead of raising or exposing an OS
/// error containing credential material.
pub fn CredentialBackend::new(
  read~ : (String, String) -> String?,
  write~ : (String, String, String) -> Bool,
  delete~ : (String, String) -> Bool,
) -> CredentialBackend {
  {
    read_credential: read,
    write_credential: write,
    delete_credential: delete,
    read_async_credential: None,
    write_async_credential: None,
    delete_async_credential: None,
  }
}

///|
/// Construct a backend whose operations may perform asynchronous native I/O.
/// This is the seam used by OS keyring integrations. The synchronous methods
/// remain available for callers that only need a fixture or in-memory store;
/// auth command paths use the async methods below.
pub fn CredentialBackend::new_async(
  read~ : async (String, String) -> String?,
  write~ : async (String, String, String) -> Bool,
  delete~ : async (String, String) -> Bool,
) -> CredentialBackend {
  {
    // Async-only backends cannot be used through the legacy synchronous API.
    // Keep these callbacks inert rather than blocking the runtime.
    read_credential: (_, _) => None,
    write_credential: (_, _, _) => false,
    delete_credential: (_, _) => false,
    read_async_credential: Some(read),
    write_async_credential: Some(write),
    delete_async_credential: Some(delete),
  }
}

///|
pub fn CredentialBackend::read(
  self : CredentialBackend,
  host : String,
  user : String,
) -> String? {
  (self.read_credential)(host, user)
}

///|
pub fn CredentialBackend::write(
  self : CredentialBackend,
  host : String,
  user : String,
  token : String,
) -> Bool {
  (self.write_credential)(host, user, token)
}

///|
pub fn CredentialBackend::delete(
  self : CredentialBackend,
  host : String,
  user : String,
) -> Bool {
  (self.delete_credential)(host, user)
}

///|
/// Read a credential through the async provider when one was supplied. Legacy
/// synchronous providers are lifted into the async boundary without changing
/// their behavior.
pub async fn CredentialBackend::read_async(
  self : CredentialBackend,
  host : String,
  user : String,
) -> String? {
  match self.read_async_credential {
    Some(read) => read(host, user)
    None => (self.read_credential)(host, user)
  }
}

///|
/// Store a credential through the async provider when one was supplied.
pub async fn CredentialBackend::write_async(
  self : CredentialBackend,
  host : String,
  user : String,
  token : String,
) -> Bool {
  match self.write_async_credential {
    Some(write) => write(host, user, token)
    None => (self.write_credential)(host, user, token)
  }
}

///|
/// Delete a credential through the async provider when one was supplied.
pub async fn CredentialBackend::delete_async(
  self : CredentialBackend,
  host : String,
  user : String,
) -> Bool {
  match self.delete_async_credential {
    Some(delete) => delete(host, user)
    None => (self.delete_credential)(host, user)
  }
}

///|
/// OAuth is intentionally an adapter boundary.  Browser/device-code flows
/// belong to the host application, which can enforce its own process, browser
/// and clipboard policy.  The adapter returns a token only on success; errors
/// carry no provider response or token text.
pub(all) enum OAuthError {
  Unavailable
  InvalidConfiguration
  Cancelled
  Denied
  Expired
  ExpiringTokenUnsupported
  Failed
} derive(Debug, Eq)

///|
pub extend OAuthError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend OAuthError with Eq::{not_equal, equal}

///|
pub struct OAuthAdapter {
  priv authorize_flow : (String, String) -> Result[String, OAuthError]
  // Native browser/device implementations may need to suspend while waiting
  // for a callback. Keep this optional so existing synchronous embedders do
  // not need to change their callback shape.
  priv authorize_async_flow : (async (String, String) -> Result[
    String,
    OAuthError,
  ])?
}

///|
/// Construct an OAuth adapter. `host` and a comma-separated scope string are
/// passed to the embedding; the adapter owns all browser/device interaction.
pub fn OAuthAdapter::new(
  authorize~ : (String, String) -> Result[String, OAuthError],
) -> OAuthAdapter {
  { authorize_flow: authorize, authorize_async_flow: None, }
}

///|
/// Construct an OAuth adapter whose browser/device flow is asynchronous.
/// The callback receives only the normalized host and requested scopes; token
/// material is returned through the result and never enters process argv,
/// traces, or diagnostics.
pub fn OAuthAdapter::new_async(
  authorize~ : async (String, String) -> Result[String, OAuthError],
) -> OAuthAdapter {
  {
    // Async-only adapters are not callable through the legacy synchronous
    // method. Keep that method deterministic and unavailable rather than
    // blocking the host runtime.
    authorize_flow: (_, _) => Err(OAuthError::Unavailable),
    authorize_async_flow: Some(authorize),
  }
}

///|
pub fn OAuthAdapter::authorize(
  self : OAuthAdapter,
  host : String,
  scopes : String,
) -> Result[String, OAuthError] {
  (self.authorize_flow)(host, scopes)
}

///|
/// Run the OAuth flow through the asynchronous callback when supplied, while
/// lifting legacy synchronous adapters into the same boundary.
pub async fn OAuthAdapter::authorize_async(
  self : OAuthAdapter,
  host : String,
  scopes : String,
) -> Result[String, OAuthError] {
  match self.authorize_async_flow {
    Some(authorize) => authorize(host, scopes)
    None => (self.authorize_flow)(host, scopes)
  }
}
