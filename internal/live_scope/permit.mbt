///|
/// An exact request approval, produced only after ownership validation.
/// Body hashes avoid retaining test secret values in policy files.
pub struct Permit {
  priv verb : String
  priv origin : String
  priv path : String
  priv body_sha256 : String
  priv resource_key : String
  priv creation : Bool
  priv inventory : Json?
}

///|
pub fn Permit::resource_key(self : Permit) -> String {
  self.resource_key
}

///|
fn digest(body : Bytes?) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(body.unwrap_or(b"")))
}

///|
fn write_verb(verb : String) -> Bool {
  verb is ("POST" | "PUT" | "PATCH" | "DELETE")
}

///|
pub fn Ledger::approve_mutation(
  self : Ledger,
  key : String,
  observed_id : String,
  verb : String,
  path : String,
  body? : Bytes,
) -> Permit raise ScopeError {
  guard write_verb(verb) else { raise OutsideScope }
  self.mutation_target(key, observed_id, path)
  self.validate_mutation(key, verb, body)
  {
    verb,
    origin: "https://api.github.com",
    path,
    body_sha256: digest(body),
    resource_key: key,
    creation: false,
    inventory: None,
  }
}

///|
/// A creation approval uses a pending intent and its exact collection path.
/// Generic account/repository-wide operations cannot be approved this way.
pub fn Ledger::approve_creation(
  self : Ledger,
  key : String,
  body : Json,
) -> Permit raise ScopeError {
  let resource = self.resource(key)
  guard resource.state == Intended else { raise InvalidTransition }
  let path = if resource.kind == "repository" {
    guard body is { "name": String(name), "private": True, .. } &&
      resource.locator == "/repos/ZSeanYves/" + name else {
      raise OutsideScope
    }
    guard body is Object(fields) &&
      fields
      .keys()
      .all(key => {
        key is ("name" | "private" | "description" | "auto_init" | "has_wiki")
      }) &&
      fields.get("has_wiki") is (None | Some(False)) else {
      raise OutsideScope
    }
    "/user/repos"
  } else if resource.parent is None {
    self.validate_account_creation(resource, body)
    resource.locator
  } else {
    let parent = match resource.parent {
      Some(parent) => self.owned(parent)
      None => raise OutsideScope
    }
    guard parent.kind is ("repository" | "fixture_repository") else {
      raise OutsideScope
    }
    let suffix = match resource.kind {
      "issue" => "/issues"
      "deploy_key" => "/keys"
      "label" => "/labels"
      "git_ref" => "/git/refs"
      _ => raise OutsideScope
    }
    guard resource.locator == parent.locator + suffix else {
      raise OutsideScope
    }
    guard body is Object(fields) else { raise OutsideScope }
    if resource.kind == "git_ref" {
      guard fields.get("ref") is Some(String(ref_name)) &&
        ref_name.has_prefix("refs/heads/gh-acceptance-" + self.run_id + "-") &&
        ref_name
        .strip_prefix("refs/heads/")
        .map_or(false, value => identifier(value.to_owned())) &&
        fields.get("sha") is Some(String(sha)) &&
        sha.length() == 40 &&
        sha.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f')) else {
        raise OutsideScope
      }
    } else {
      let title_key = if resource.kind == "label" { "name" } else { "title" }
      guard fields.get(title_key) is Some(String(title)) &&
        title.has_prefix("gh-acceptance-" + self.run_id + "-") else {
        raise OutsideScope
      }
    }
    let allowed = match resource.kind {
      "issue" => ["title", "body"]
      "label" => ["name", "color", "description"]
      "deploy_key" => ["title", "key", "read_only"]
      "git_ref" => ["ref", "sha"]
      _ => raise OutsideScope
    }
    guard fields.keys().all(key => allowed.contains(key)) else {
      raise OutsideScope
    }
    resource.locator
  }
  {
    verb: "POST",
    origin: "https://api.github.com",
    path,
    body_sha256: digest(Some(@utf8.encode(body.stringify()))),
    resource_key: key,
    creation: true,
    inventory: None,
  }
}

///|
fn Ledger::validate_account_creation(
  self : Ledger,
  resource : Resource,
  body : Json,
) -> Unit raise ScopeError {
  guard body is Object(fields) else { raise OutsideScope }
  let allowed = match resource.kind {
    "gist" => {
      guard resource.locator == "/gists" &&
        fields.get("public") == Some(Json(false)) &&
        fields.get("description") is Some(String(description)) &&
        description.has_prefix("gh-acceptance-" + self.run_id + "-") &&
        fields.get("files") is Some(files) &&
        valid_gist_files(files, creating=true) else {
        raise OutsideScope
      }
      ["description", "public", "files"]
    }
    "ssh_key" | "ssh_signing_key" => {
      let collection = if resource.kind == "ssh_key" {
        "/user/keys"
      } else {
        "/user/ssh_signing_keys"
      }
      guard resource.locator == collection &&
        fields.get("title") is Some(String(title)) &&
        title.has_prefix("gh-acceptance-" + self.run_id + "-") &&
        fields.get("key") is Some(String(key)) &&
        key.length() <= 65536 &&
        !key.contains("PRIVATE KEY") &&
        (
          key.has_prefix("ssh-ed25519 ") ||
          key.has_prefix("ssh-rsa ") ||
          key.has_prefix("ecdsa-sha2-")
        ) else {
        raise OutsideScope
      }
      ["title", "key"]
    }
    "gpg_key" => {
      guard resource.locator == "/user/gpg_keys" &&
        fields.get("armored_public_key") is Some(String(key)) &&
        key.length() <= 262144 &&
        key.has_prefix("-----BEGIN PGP PUBLIC KEY BLOCK-----") &&
        key.trim().has_suffix("-----END PGP PUBLIC KEY BLOCK-----") &&
        !key.contains("PRIVATE KEY") else {
        raise OutsideScope
      }
      ["armored_public_key"]
    }
    _ => raise OutsideScope
  }
  guard fields.keys().all(key => allowed.contains(key)) else {
    raise OutsideScope
  }
}

///|
fn valid_gist_files(value : Json, creating~ : Bool) -> Bool {
  guard value is Object(files) && !files.is_empty() && files.length() <= 100 else {
    return false
  }
  files
  .iter()
  .all(pair => {
    let (name, file) = pair
    if name.is_empty() ||
      name.length() > 255 ||
      name.contains("/") ||
      name.contains("\\") ||
      name is ("." | "..") ||
      name.iter().any(ch => ch.to_int() < 32) {
      return false
    }
    match file {
      Null => !creating
      Object(fields) =>
        fields.keys().all(key => key == "content") &&
        fields.get("content") is Some(String(content)) &&
        content.length() <= 1048576
      _ => false
    }
  })
}

///|
pub fn Permit::allows(
  self : Permit,
  origin : String,
  verb : String,
  path : String,
  body : Bytes?,
) -> Bool {
  origin == self.origin &&
  verb == self.verb &&
  path == self.path &&
  digest(body) == self.body_sha256
}

///|
pub fn Permit::to_json(self : Permit) -> Json {
  {
    "origin": self.origin,
    "verb": self.verb,
    "path": self.path,
    "body_sha256": self.body_sha256,
    "resource_key": self.resource_key,
    "creation": self.creation,
    "inventory": self.inventory.unwrap_or(Json::null()),
  }
}

///|
/// The on-disk request policy is intentionally exact. It cannot contain a
/// wildcard, an alternate origin, or an approval for the development repository.
fn permit_from_json(value : Json, ledger : Ledger) -> Permit raise ScopeError {
  guard value
    is {
      "origin": String("https://api.github.com"),
      "verb": String(verb),
      "path": String(path),
      "body_sha256": String(hash),
      "resource_key": String(key),
      "creation": creation,
      ..
    } &&
    write_verb(verb) &&
    locator_valid(path) &&
    identifier(key) &&
    hash.length() == 64 &&
    hash.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f')) else {
    raise InvalidLedger
  }
  let creation = match creation {
    True => true
    False => false
    _ => raise InvalidLedger
  }
  let resource = ledger.resource(key)
  let inventory = match value {
    { "inventory": Object(_) as inventory, .. } if !creation &&
      resource.kind == "repository" &&
      verb == "DELETE" => Some(inventory)
    { "inventory": Null, .. } => None
    Object(fields) if !fields.contains("inventory") => None
    _ => raise InvalidLedger
  }
  if creation {
    guard resource.state == Intended &&
      verb == "POST" &&
      path ==
      (if resource.kind == "repository" {
        "/user/repos"
      } else {
        resource.locator
      }) else {
      raise OutsideScope
    }
  } else {
    guard resource.remote_id is Some(id) else { raise UnknownResource }
    if path == "/graphql" {
      guard verb == "POST" && key != "fixture" && resource.node_id is Some(_) else {
        raise OutsideScope
      }
      ignore(ledger.owned(key))
    } else if ledger.operation_path(key, verb, path) {
      // Body semantics are checked again when the request is actually sent.
      ledger.check_owned(key, id, resource.locator)
    } else {
      ledger.mutation_target(key, id, path)
    }
  }
  {
    origin: "https://api.github.com",
    verb,
    path,
    body_sha256: hash,
    resource_key: key,
    creation,
    inventory,
  }
}

///|
/// Each supported mutation has a small field allowlist. In particular an
/// issue update cannot assign an existing milestone or another account, and
/// repository settings cannot change visibility or transfer ownership.
fn Ledger::validate_mutation(
  self : Ledger,
  key : String,
  verb : String,
  body : Bytes?,
) -> Unit raise ScopeError {
  let resource = self.owned(key)
  let fields = match body {
    None => Map([])
    Some(bytes) => {
      let source = @utf8.decode(bytes) catch { _ => raise OutsideScope }
      let value = @json.parse(source) catch { _ => raise OutsideScope }
      guard value is Object(fields) else { raise OutsideScope }
      fields
    }
  }
  let allowed : Array[String] = match (resource.kind, verb) {
    ("issue", "PATCH") => ["title", "body", "state", "state_reason"]
    ("label", "PATCH") => ["new_name", "color", "description"]
    // Repository deletion needs a separately implemented complete inventory
    // audit. A creation receipt alone must not authorize deleting contents
    // that another actor may have added in the meantime.
    (
      "label"
      | "deploy_key"
      | "gist"
      | "ssh_key"
      | "ssh_signing_key"
      | "gpg_key"
      | "git_ref",
      "DELETE",
    ) => []
    ("gist", "PATCH") => {
      if fields.get("files") is Some(files) &&
        !valid_gist_files(files, creating=false) {
        raise OutsideScope
      }
      guard fields.get("description") is (None | Some(String(_))) else {
        raise OutsideScope
      }
      ["description", "files"]
    }
    ("repository", "PATCH") => ["description", "homepage", "archived"]
    ("run" | "artifact" | "cache", "DELETE") => {
      guard action_resource_path(resource, self.temporary_repository(resource)) else {
        raise OutsideScope
      }
      []
    }
    _ => raise OutsideScope
  }
  guard fields.keys().all(key => allowed.contains(key)) else {
    raise OutsideScope
  }
}

///|
fn Permit::validated_for(
  self : Permit,
  ledger : Ledger,
  body : Bytes?,
  now_ms : Int64,
) -> Bool {
  try {
    if self.inventory is Some(inventory) {
      guard self.verb == "DELETE" && body is None else { return false }
      ledger.validate_repository_inventory(self.resource_key, inventory, now_ms)
      true
    } else if self.creation {
      guard body is Some(bytes) else { return false }
      let approved = ledger.approve_creation(
        self.resource_key,
        @json.parse(@utf8.decode(bytes)),
      )
      approved.path == self.path && approved.body_sha256 == self.body_sha256
    } else if self.path == "/graphql" {
      ledger.validate_graphql(self.resource_key, body)
      true
    } else if ledger.operation_path(self.resource_key, self.verb, self.path) {
      ledger.validate_operation(self.resource_key, self.verb, self.path, body)
      true
    } else {
      ledger.validate_mutation(self.resource_key, self.verb, body)
      true
    }
  } catch {
    _ => false
  }
}
