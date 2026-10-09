///|
/// A repository address in MoonHub's namespace model.
pub struct RepositoryRef {
  owner : String
  name : String
}

///|
pub fn RepositoryRef::new(owner~ : String, name~ : String) -> RepositoryRef {
  { owner, name, }
}

///|
/// MoonHub resources exposed through the first machine API.
pub enum ResourceKind {
  Repository
  Issue
  MergeRequest
  Pipeline
}

///|
pub fn resource_kinds() -> Array[ResourceKind] {
  [Repository, Issue, MergeRequest, Pipeline]
}

///|
/// Configuration shared by a MoonHub client and its API requests.
pub struct ClientConfig {
  base_url : String
  api_prefix : String
}

///|
pub fn default_api_prefix() -> String {
  "/api/v1"
}

///|
/// The initial contract requires a normalized base URL without a trailing slash.
pub fn ClientConfig::new(base_url~ : String) -> ClientConfig {
  { base_url, api_prefix: default_api_prefix(), }
}

///|
/// Join a provider path to the configured MoonHub API prefix.
pub fn ClientConfig::endpoint(self : ClientConfig, path~ : String) -> String {
  self.base_url + self.api_prefix + path
}
