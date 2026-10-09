///|
/// Proposed MoonHub v1 discovery response. This is a client contract, not a
/// claim that the current MoonHub server exposes these endpoints.
pub struct Meta {
  api_version : Int
  server_version : String
  capabilities : Array[String]
}

///|
pub struct User {
  id : String
  name_key : String
  display_name : String
  is_site_admin : Bool
}

///|
pub struct Repository {
  owner : String
  name : String
  visibility : String
  default_branch : String?
  ssh_url : String?
}

///|
pub struct Issue {
  number : Int
  title : String
  description : String
  status : String
  author : String?
  assignee : String?
  edit_version : String?
  updated_at : String?
}

///|
pub struct MergeRequest {
  number : Int
  title : String
  description : String
  source : String
  target : String
  draft : Bool
  status : String
  version : String?
  edit_version : String?
  merged_sha : String?
  job_status : String?
}

///|
pub extend Meta with @json.FromJson::{from_json}

///|
pub extend User with @json.FromJson::{from_json}

///|
pub extend Repository with @json.FromJson::{from_json}

///|
pub extend Issue with @json.FromJson::{from_json}

///|
pub extend MergeRequest with @json.FromJson::{from_json}

///|
// These are MoonHub domain rules, not a replacement URL parser. They mirror
// domain/valid_name_key and parse_transport_repo used by repository creation.
fn valid_owner(value : String) -> Bool {
  guard !value.is_empty() && value.length() <= 63 && value != "assets" else {
    return false
  }
  for index, character in value {
    if !(character is ('a'..='z' | '0'..='9')) &&
      !(index > 0 && character is ('_' | '-')) {
      return false
    }
  }
  true
}

///|
fn valid_repository_name(value : String) -> Bool {
  guard !value.is_empty() && value.length() <= 100 else { return false }
  for index, character in value {
    if !(character is ('a'..='z' | 'A'..='Z' | '0'..='9')) &&
      !(index > 0 && character is ('_' | '-' | '.')) {
      return false
    }
  }
  true
}

///|
/// Parse an exact owner/name reference. URLs, traversal, percent escapes and
/// leading/trailing whitespace are rejected before any network operation.
/// A .git suffix is part of the name here, not a transport URL suffix.
pub fn RepositoryRef::parse(
  value : String,
) -> Result[RepositoryRef, @gh.ApiError] {
  let segments = value.split("/").collect()
  guard segments is [owner, name] else {
    return Err(@gh.InvalidRequest(message="repository must be owner/name"))
  }
  let repo = RepositoryRef::new(owner=owner.to_owned(), name=name.to_owned())
  match repo.api_path() {
    Ok(_) => Ok(repo)
    Err(error) => Err(error)
  }
}

///|
/// Validate even references made with the unchecked convenience constructor.
pub fn RepositoryRef::api_path(
  self : RepositoryRef,
) -> Result[String, @gh.ApiError] {
  if valid_owner(self.owner) && valid_repository_name(self.name) {
    Ok("/repos/\{self.owner}/\{self.name}")
  } else {
    Err(@gh.InvalidRequest(message="invalid MoonHub repository reference"))
  }
}

///|
fn[T] resource_invalid(path : @json.JsonPath) -> T raise @json.JsonDecodeError {
  raise @json.JsonDecodeError((path, "invalid MoonHub resource"))
}

///|
fn resource_object(
  value : Json,
  path : @json.JsonPath,
) -> Map[String, Json] raise @json.JsonDecodeError {
  guard value is Object(fields) else { resource_invalid(path) }
  fields
}

///|
fn[T : @json.FromJson] required_field(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T raise @json.JsonDecodeError {
  let path = path.add_key(key)
  guard fields.get(key) is Some(value) else { resource_invalid(path) }
  @json.from_json(value, path~)
}

///|
fn optional_string(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  match fields.get(key) {
    None | Some(Null) => None
    Some(value) => Some(@json.from_json(value, path=path.add_key(key)))
  }
}

///|
fn decimal_string(value : String, allow_zero~ : Bool) -> Bool {
  if value == "0" {
    return allow_zero
  }
  guard value.iter().next() is Some('1'..='9') else { return false }
  value.iter().all(character => character is ('0'..='9'))
}

///|
fn optional_version(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> String? raise @json.JsonDecodeError {
  let value = optional_string(fields, key, path)
  if value is Some(value) && !decimal_string(value, allow_zero=true) {
    resource_invalid(path.add_key(key))
  }
  value
}

///|
fn positive_number(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Int raise @json.JsonDecodeError {
  guard fields.get(key) is Some(value) &&
    @wire_json.integer(value, minimum=1, maximum=2147483647) is Some(integer) else {
    resource_invalid(path.add_key(key))
  }
  integer.to_int()
}

///|
pub impl @json.FromJson for Meta with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let api_version = positive_number(fields, "api_version", path)
  guard api_version == 1 else { resource_invalid(path.add_key("api_version")) }
  {
    api_version,
    server_version: required_field(fields, "server_version", path),
    capabilities: required_field(fields, "capabilities", path),
  }
}

///|
pub impl @json.FromJson for User with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let id : String = required_field(fields, "id", path)
  guard decimal_string(id, allow_zero=false) else {
    resource_invalid(path.add_key("id"))
  }
  let name_key : String = required_field(fields, "name_key", path)
  guard valid_owner(name_key) else {
    resource_invalid(path.add_key("name_key"))
  }
  {
    id,
    name_key,
    display_name: required_field(fields, "display_name", path),
    is_site_admin: required_field(fields, "is_site_admin", path),
  }
}

///|
pub impl @json.FromJson for Repository with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let owner : String = required_field(fields, "owner", path)
  let name : String = required_field(fields, "name", path)
  guard valid_owner(owner) && valid_repository_name(name) else {
    resource_invalid(path)
  }
  let visibility : String = required_field(fields, "visibility", path)
  guard visibility is ("public" | "private") else {
    resource_invalid(path.add_key("visibility"))
  }
  {
    owner,
    name,
    visibility,
    default_branch: optional_string(fields, "default_branch", path),
    ssh_url: optional_string(fields, "ssh_url", path),
  }
}

///|
pub impl @json.FromJson for Issue with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let status : String = required_field(fields, "status", path)
  guard status is ("open" | "closed") else {
    resource_invalid(path.add_key("status"))
  }
  {
    number: positive_number(fields, "number", path),
    title: required_field(fields, "title", path),
    description: required_field(fields, "description", path),
    status,
    author: optional_string(fields, "author", path),
    assignee: optional_string(fields, "assignee", path),
    edit_version: optional_version(fields, "edit_version", path),
    updated_at: optional_string(fields, "updated_at", path),
  }
}

///|
pub impl @json.FromJson for MergeRequest with fn from_json(value, path) {
  let fields = resource_object(value, path)
  let status : String = required_field(fields, "status", path)
  guard status is ("open" | "closed" | "merged") else {
    resource_invalid(path.add_key("status"))
  }
  let job_status = optional_string(fields, "job_status", path)
  if job_status is Some(value) &&
    !(value is ("pending" | "running" | "succeeded" | "failed")) {
    resource_invalid(path.add_key("job_status"))
  }
  {
    number: positive_number(fields, "number", path),
    title: required_field(fields, "title", path),
    description: required_field(fields, "description", path),
    source: required_field(fields, "source", path),
    target: required_field(fields, "target", path),
    draft: required_field(fields, "draft", path),
    status,
    version: optional_version(fields, "version", path),
    edit_version: optional_version(fields, "edit_version", path),
    merged_sha: optional_string(fields, "merged_sha", path),
    job_status,
  }
}

///|
fn nullable_string(value : String?) -> Json {
  match value {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
pub fn Meta::to_json(self : Meta) -> Json {
  {
    "api_version": self.api_version.to_json(),
    "server_version": self.server_version.to_json(),
    "capabilities": self.capabilities.to_json(),
  }
}

///|
pub fn User::to_json(self : User) -> Json {
  {
    "id": self.id.to_json(),
    "name_key": self.name_key.to_json(),
    "display_name": self.display_name.to_json(),
    "is_site_admin": self.is_site_admin.to_json(),
  }
}

///|
pub fn Repository::to_json(self : Repository) -> Json {
  {
    "owner": self.owner.to_json(),
    "name": self.name.to_json(),
    "visibility": self.visibility.to_json(),
    "default_branch": nullable_string(self.default_branch),
    "ssh_url": nullable_string(self.ssh_url),
  }
}

///|
pub fn Issue::to_json(self : Issue) -> Json {
  {
    "number": self.number.to_json(),
    "title": self.title.to_json(),
    "description": self.description.to_json(),
    "status": self.status.to_json(),
    "author": nullable_string(self.author),
    "assignee": nullable_string(self.assignee),
    "edit_version": nullable_string(self.edit_version),
    "updated_at": nullable_string(self.updated_at),
  }
}

///|
pub fn MergeRequest::to_json(self : MergeRequest) -> Json {
  {
    "number": self.number.to_json(),
    "title": self.title.to_json(),
    "description": self.description.to_json(),
    "source": self.source.to_json(),
    "target": self.target.to_json(),
    "draft": self.draft.to_json(),
    "status": self.status.to_json(),
    "version": nullable_string(self.version),
    "edit_version": nullable_string(self.edit_version),
    "merged_sha": nullable_string(self.merged_sha),
    "job_status": nullable_string(self.job_status),
  }
}
