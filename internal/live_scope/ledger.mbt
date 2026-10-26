///|
pub suberror ScopeError {
  InvalidLedger
  OutsideScope
  UnknownResource
  InvalidTransition
}

///|
pub(all) enum State {
  Intended
  Created
  Uncertain
  Removed
  NotCreated
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
struct Resource {
  key : String
  parent : String?
  mut locator : String
  kind : String
  mut remote_id : String?
  mut node_id : String?
  mut state : State
  mut content_sha256 : String?
}

///|
/// Test-only ownership ledger. Names are never proof of ownership: an intent
/// must precede a successful creation receipt before an object is writable.
pub struct Ledger {
  priv run_id : String
  priv resources : Map[String, Resource]
  priv owner : String
  priv owner_id : String?
  priv credential_sha256 : String?
}

///|
fn acceptance_account(value : String) -> Bool {
  value is ("ZSeanYves" | "ZSeanYvesMIN")
}

///|
fn numeric_id(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 20 &&
  value != "0" &&
  value.iter().all(ch => ch is ('0'..<='9'))
}

///|
/// A fresh account run grants no access to any existing fixture repository.
/// The runner verifies /user before binding this account and token digest.
pub fn Ledger::for_account(
  run_id : String,
  owner : String,
  owner_id : String,
  credential_sha256 : String,
) -> Ledger raise ScopeError {
  guard identifier(run_id) &&
    acceptance_account(owner) &&
    numeric_id(owner_id) &&
    content_digest(credential_sha256) else {
    raise InvalidLedger
  }
  {
    run_id,
    resources: Map([]),
    owner,
    owner_id: Some(owner_id),
    credential_sha256: Some(credential_sha256),
  }
}

///|
fn identifier(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 200 &&
  value
  .iter()
  .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_'))
}

///|
fn locator_valid(value : String) -> Bool {
  value.has_prefix("/") &&
  !value.has_prefix("//") &&
  !value.contains("\\") &&
  !value.contains("?") &&
  !value.contains("#") &&
  value.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) &&
  value.split("/").all(locator_segment_valid) &&
  !value.contains("//")
}

///|
fn locator_hex(ch : Char) -> Int32 {
  match ch {
    '0'..<='9' => ch.to_int() - 48
    'a'..<='f' => ch.to_int() - 87
    'A'..<='F' => ch.to_int() - 55
    _ => -1
  }
}

///|
/// Percent-encoded spaces/UTF-8 are needed for ordinary label names. Decode
/// once for validation; encoded separators, controls, traversal, and double
/// encoding never enter an approval. Exact wire spelling remains bound by the
/// permit, so validation does not introduce alternate mutation paths.
fn locator_segment_valid(segment : StringView) -> Bool {
  let chars = segment.iter().collect()
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < chars.length() {
    let value = if chars[index] == '%' {
      if index + 2 >= chars.length() {
        return false
      }
      let high = locator_hex(chars[index + 1])
      let low = locator_hex(chars[index + 2])
      if high < 0 || low < 0 {
        return false
      }
      index += 3
      high * 16 + low
    } else {
      let value = chars[index].to_int()
      index += 1
      value
    }
    if value < 32 || value == 127 || value is (37 | 47 | 92 | 63 | 35) {
      return false
    }
    bytes.push(value.to_byte())
  }
  let decoded = @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => return false
  }
  decoded != "." && decoded != ".."
}

///|
pub fn Ledger::new(
  run_id : String,
  fixture_repository_id : String,
) -> Ledger raise ScopeError {
  guard identifier(run_id) && identifier(fixture_repository_id) else {
    raise InvalidLedger
  }
  let fixture : Resource = {
    key: "fixture",
    parent: None,
    locator: "/repos/ZSeanYves/gh_test",
    kind: "fixture_repository",
    remote_id: Some(fixture_repository_id),
    node_id: None,
    state: Created,
    content_sha256: None,
  }
  {
    run_id,
    resources: { "fixture": fixture },
    owner: "ZSeanYves",
    owner_id: None,
    credential_sha256: None,
  }
}

///|
/// Record the exact expected creation target before making a network request.
/// Only this run's disposable repositories can enter the repository allowlist.
pub fn Ledger::intend_repository(
  self : Ledger,
  key : String,
  name : String,
) -> Unit raise ScopeError {
  guard identifier(name) &&
    name.has_prefix("gh-acceptance-" + self.run_id + "-") else {
    raise OutsideScope
  }
  self.add_intent(key, None, "/repos/" + self.owner + "/" + name, "repository")
}

///|
/// Account resources have independent ownership and never authorize repository
/// mutations. Existing keys, projects and gists cannot be registered as created.
pub fn Ledger::intend_account_resource(
  self : Ledger,
  key : String,
  kind : String,
  locator : String,
) -> Unit raise ScopeError {
  let collection = match kind {
    "gist" => "/gists"
    "ssh_key" => "/user/keys"
    "ssh_signing_key" => "/user/ssh_signing_keys"
    "gpg_key" => "/user/gpg_keys"
    "project" => "/graphql/nodes"
    _ => raise OutsideScope
  }
  guard locator == collection else { raise OutsideScope }
  self.add_intent(key, None, locator, kind)
}

///|
pub fn Ledger::intend_resource(
  self : Ledger,
  key : String,
  parent : String,
  relative_locator : String,
  kind : String,
) -> Unit raise ScopeError {
  let owner = self.owned(parent)
  guard locator_valid(relative_locator) && identifier(kind) else {
    raise OutsideScope
  }
  self.add_intent(key, Some(parent), owner.locator + relative_locator, kind)
}

///|
fn Ledger::add_intent(
  self : Ledger,
  key : String,
  parent : String?,
  locator : String,
  kind : String,
) -> Unit raise ScopeError {
  guard identifier(key) &&
    !self.resources.contains(key) &&
    locator_valid(locator) else {
    raise InvalidLedger
  }
  guard !self.resources
    .values()
    .any(resource => resource.locator == locator && resource.state == Created) else {
    raise InvalidLedger
  }
  self.resources[key] = {
    key,
    parent,
    locator,
    kind,
    remote_id: None,
    node_id: None,
    state: Intended,
    content_sha256: None,
  }
}

///|
fn Ledger::resource(self : Ledger, key : String) -> Resource raise ScopeError {
  match self.resources.get(key) {
    Some(resource) => resource
    None => raise UnknownResource
  }
}

///|
fn Ledger::owned(self : Ledger, key : String) -> Resource raise ScopeError {
  let resource = self.resource(key)
  guard resource.state == Created && resource.remote_id is Some(_) else {
    raise InvalidTransition
  }
  if resource.parent is Some(parent) {
    ignore(self.owned(parent))
  }
  resource
}

///|
/// Restore a persisted ledger without turning a matching name into ownership.
/// Created resources require a receipt ID and an already-created parent.
pub fn Ledger::from_json(value : Json) -> Ledger raise ScopeError {
  guard value
    is {
      "schema": Number(schema, ..),
      "run_id": String(run_id),
      "resources": Array(entries),
      ..
    } &&
    (schema == 1 || schema == 2) &&
    identifier(run_id) &&
    entries.length() <= 2048 else {
    raise InvalidLedger
  }
  let (owner, owner_id, credential_sha256) = if schema == 2 {
    guard value
      is {
        "owner": String(owner),
        "owner_id": String(owner_id),
        "credential_sha256": String(hash),
        ..
      } &&
      acceptance_account(owner) &&
      numeric_id(owner_id) &&
      content_digest(hash) else {
      raise InvalidLedger
    }
    (owner, Some(owner_id), Some(hash))
  } else {
    guard value is Object(fields) &&
      !fields.contains("owner") &&
      !fields.contains("owner_id") &&
      !fields.contains("credential_sha256") else {
      raise InvalidLedger
    }
    ("ZSeanYves", None, None)
  }
  let resources : Map[String, Resource] = Map([])
  for entry in entries {
    guard entry
      is {
        "key": String(key),
        "kind": String(kind),
        "locator": String(locator),
        "parent": parent_json,
        "remote_id": id_json,
        "state": String(state),
        ..
      } &&
      identifier(key) &&
      identifier(kind) &&
      locator_valid(locator) &&
      !resources.contains(key) else {
      raise InvalidLedger
    }
    let parent = match parent_json {
      Null => None
      String(value) if identifier(value) => Some(value)
      _ => raise InvalidLedger
    }
    let remote_id = match id_json {
      Null => None
      String(value) if identifier(value) => Some(value)
      _ => raise InvalidLedger
    }
    let state = match state {
      "intended" if remote_id is None => Intended
      "uncertain" => Uncertain
      "created" if remote_id is Some(_) => Created
      "removed" if remote_id is Some(_) => Removed
      "not-created" if remote_id is None => NotCreated
      _ => raise InvalidLedger
    }
    let node_id = match entry {
      { "node_id": String(value), .. } if node_identifier(value) => Some(value)
      { "node_id": Null, .. } => None
      Object(fields) if !fields.contains("node_id") => None
      _ => raise InvalidLedger
    }
    guard !resources
      .values()
      .any(resource => {
        (node_id is Some(_) && node_id == resource.node_id) ||
        (
          remote_id is Some(_) &&
          remote_id == resource.remote_id &&
          parent == resource.parent &&
          kind == resource.kind
        )
      }) else {
      raise InvalidLedger
    }
    let content_sha256 = match entry {
      { "content_sha256": String(hash), .. } if content_digest(hash) =>
        Some(hash)
      { "content_sha256": Null, .. } => None
      Object(fields) if !fields.contains("content_sha256") => None
      _ => raise InvalidLedger
    }
    if state == NotCreated {
      guard kind is ("git_ref" | "workflow" | "run") &&
        parent is Some(_) &&
        node_id is None &&
        content_sha256 is Some(_) else {
        raise InvalidLedger
      }
    }
    resources[key] = {
      key,
      kind,
      locator,
      parent,
      remote_id,
      node_id,
      state,
      content_sha256,
    }
  }
  if schema == 1 {
    guard resources.get("fixture")
      is Some(
        {
          parent: None,
          locator: "/repos/ZSeanYves/gh_test",
          kind: "fixture_repository",
          state: Created,
          remote_id: Some(_),
          ..
        }
      ) else {
      raise InvalidLedger
    }
  } else {
    guard !resources.contains("fixture") &&
      resources.values().all(item => item.kind != "fixture_repository") else {
      raise InvalidLedger
    }
  }
  let ledger : Ledger = {
    run_id,
    resources,
    owner,
    owner_id,
    credential_sha256,
  }
  for resource in resources.values() {
    ledger.validate_resource(resource, [])
  }
  ledger
}

///|
fn Ledger::validate_resource(
  self : Ledger,
  resource : Resource,
  ancestors : Array[String],
) -> Unit raise ScopeError {
  guard !ancestors.contains(resource.key) && ancestors.length() < 8 else {
    raise InvalidLedger
  }
  match resource.parent {
    Some(key) => {
      let parent = self.resource(key)
      self.validate_resource(parent, [..ancestors, resource.key])
      guard resource.locator.has_prefix(parent.locator + "/") else {
        raise OutsideScope
      }
      guard resource.kind != "repository" &&
        resource.kind != "fixture_repository" else {
        raise OutsideScope
      }
      if resource.state == NotCreated {
        guard parent.kind == "repository" &&
          parent.remote_id is Some(_) &&
          resource.locator ==
          parent.locator +
          (if resource.kind == "git_ref" {
            "/git/refs"
          } else if resource.kind == "run" {
            "/actions/runs"
          } else {
            "/actions/workflows"
          }) else {
          raise InvalidLedger
        }
      }
      if resource.state == Created {
        // A pending mutation of a parent does not erase its children's
        // receipts. Loading is allowed; owned() still blocks new child writes
        // until the parent has been reconciled by immutable ID.
        guard parent.state is (Created | Uncertain) &&
          parent.remote_id is Some(_) else {
          raise InvalidLedger
        }
      }
    }
    None => {
      let allowed = match resource.kind {
        "fixture_repository" => resource.key == "fixture"
        "repository" =>
          resource.locator.has_prefix(
            "/repos/" + self.owner + "/gh-acceptance-" + self.run_id + "-",
          ) &&
          resource.locator.split("/").count() == 4
        "gist" => account_locator(resource, "/gists")
        "ssh_key" => account_locator(resource, "/user/keys")
        "ssh_signing_key" => account_locator(resource, "/user/ssh_signing_keys")
        "gpg_key" => account_locator(resource, "/user/gpg_keys")
        "project" => account_locator(resource, "/graphql/nodes")
        _ => false
      }
      guard allowed else { raise OutsideScope }
    }
  }
}

///|
pub fn Ledger::confirm_created(
  self : Ledger,
  key : String,
  remote_id : String,
  locator? : String,
) -> Unit raise ScopeError {
  let resource = self.resource(key)
  guard resource.state is (Intended | Uncertain) && identifier(remote_id) else {
    raise InvalidTransition
  }
  guard resource.remote_id.map_or(true, value => value == remote_id) &&
    !self.resources
    .values()
    .any(item => {
      item.key != key &&
      item.parent == resource.parent &&
      item.kind == resource.kind &&
      item.remote_id == Some(remote_id)
    }) else {
    raise InvalidLedger
  }
  if resource.parent is Some(parent) {
    ignore(self.owned(parent))
  }
  if locator is Some(locator) {
    guard resource.remote_id is None &&
      resource.kind != "repository" &&
      locator_valid(locator) &&
      locator.has_prefix(resource.locator + "/") else {
      raise OutsideScope
    }
    resource.locator = locator
  }
  resource.remote_id = Some(remote_id)
  resource.state = Created
}

///|
pub fn Ledger::mark_uncertain(
  self : Ledger,
  key : String,
) -> Unit raise ScopeError {
  let resource = self.resource(key)
  guard resource.state is (Intended | Created) && key != "fixture" else {
    raise InvalidTransition
  }
  resource.state = Uncertain
}

///|
/// A failed initial workflow write or dispatch may create no remote object.
/// The trusted reconciler must first save complete collection absence evidence.
/// This terminal state never authorizes a resource mutation or hides an object
/// in the repository's mandatory inventory.
pub fn Ledger::confirm_not_created(
  self : Ledger,
  key : String,
  parent_id : String,
  proof_sha256 : String,
) -> Unit raise ScopeError {
  let resource = self.resource(key)
  guard resource.state is (Intended | Uncertain) &&
    resource.remote_id is None &&
    resource.node_id is None &&
    resource.kind is ("git_ref" | "workflow" | "run") &&
    resource.parent is Some(parent_key) &&
    content_digest(proof_sha256) else {
    raise InvalidTransition
  }
  let parent = self.owned(parent_key)
  guard parent.kind == "repository" &&
    parent.remote_id == Some(parent_id) &&
    resource.locator ==
    parent.locator +
    (if resource.kind == "git_ref" {
      "/git/refs"
    } else if resource.kind == "run" {
      "/actions/runs"
    } else {
      "/actions/workflows"
    }) else {
    raise OutsideScope
  }
  resource.content_sha256 = Some(proof_sha256)
  resource.state = NotCreated
}

///|
/// Read-back must match the immutable receipt ID, not just the current name.
pub fn Ledger::check_owned(
  self : Ledger,
  key : String,
  observed_id : String,
  locator : String,
) -> Unit raise ScopeError {
  let resource = self.owned(key)
  guard resource.remote_id == Some(observed_id) && resource.locator == locator else {
    raise OutsideScope
  }
}

///|
pub fn Ledger::confirm_removed(
  self : Ledger,
  key : String,
  observed_id : String,
) -> Unit raise ScopeError {
  let resource = self.resource(key)
  guard key != "fixture" && resource.remote_id == Some(observed_id) else {
    raise OutsideScope
  }
  guard resource.state is (Created | Uncertain) else { raise InvalidTransition }
  guard !self.resources
    .values()
    .any(child => {
      child.parent == Some(key) && !(child.state is (Removed | NotCreated))
    }) else {
    raise InvalidTransition
  }
  resource.state = Removed
}

///|
/// Only exact paths are approved; broad prefix-based mutation grants are absent.
/// The fixed fixture repository itself is never a mutation/deletion target.
pub fn Ledger::mutation_target(
  self : Ledger,
  key : String,
  observed_id : String,
  locator : String,
) -> Unit raise ScopeError {
  guard key != "fixture" else { raise OutsideScope }
  self.check_owned(key, observed_id, locator)
}

///|
pub fn Ledger::to_json(self : Ledger) -> Json {
  let resources : Array[Json] = []
  for resource in self.resources.values() {
    resources.push({
      "key": resource.key,
      "parent": match resource.parent {
        Some(value) => Json(value)
        None => Json::null()
      },
      "locator": resource.locator,
      "kind": resource.kind,
      "content_sha256": resource.content_sha256.map_or(Json::null(), value => {
        Json(value)
      }),
      "remote_id": match resource.remote_id {
        Some(value) => Json(value)
        None => Json::null()
      },
      "node_id": match resource.node_id {
        Some(value) => Json(value)
        None => Json::null()
      },
      "state": match resource.state {
        Intended => "intended"
        Created => "created"
        Uncertain => "uncertain"
        Removed => "removed"
        NotCreated => "not-created"
      },
    })
  }
  if self.credential_sha256 is Some(hash) {
    {
      "schema": 2,
      "run_id": self.run_id,
      "resources": resources,
      "owner": self.owner,
      "owner_id": self.owner_id.unwrap(),
      "credential_sha256": hash,
    }
  } else {
    { "schema": 1, "run_id": self.run_id, "resources": resources }
  }
}

///|
fn content_digest(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f'))
}

///|
/// Bind the expected content after this run's creation/write receipt has
/// been independently read back. The digest, never private API contents, is
/// retained for later foreign-change detection.
pub fn Ledger::record_content_receipt(
  self : Ledger,
  key : String,
  observed_id : String,
  sha256 : String,
) -> Unit raise ScopeError {
  let resource = self.owned(key)
  guard key != "fixture" &&
    resource.remote_id == Some(observed_id) &&
    content_digest(sha256) else {
    raise OutsideScope
  }
  resource.content_sha256 = Some(sha256)
}

///|
fn account_locator(resource : Resource, collection : String) -> Bool {
  if resource.state is (Intended | Uncertain) && resource.remote_id is None {
    resource.locator == collection
  } else {
    resource.locator.has_prefix(collection + "/") &&
    resource.locator
    .strip_prefix(collection + "/")
    .map_or(false, value => !value.is_empty() && !value.contains("/"))
  }
}

///|
fn node_identifier(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 256 &&
  value
  .iter()
  .all(ch => {
    ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '_' | '-' | '+' | '/' | '=')
  })
}

///|
/// Bind a GraphQL ID only after a read-back confirms the immutable REST receipt.
pub fn Ledger::bind_node(
  self : Ledger,
  key : String,
  observed_id : String,
  node_id : String,
) -> Unit raise ScopeError {
  let resource = self.owned(key)
  guard resource.remote_id == Some(observed_id) &&
    node_identifier(node_id) &&
    resource.node_id.map_or(true, previous => previous == node_id) &&
    !self.resources
    .values()
    .any(other => other.key != key && other.node_id == Some(node_id)) else {
    raise OutsideScope
  }
  resource.node_id = Some(node_id)
}
