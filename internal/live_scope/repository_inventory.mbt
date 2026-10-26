///|
/// Each category needs a complete, bounded page chain. Unknown categories are
/// rejected, and a collector must fail closed when GitHub denies enumeration.
/// Per-PR reviews are required separately because GitHub has no repository-wide
/// review-list endpoint. Nested environments/releases must be cleaned first.
let repository_inventory_kinds : Array[String] = [
  "git_ref", "issue", "pull_request", "issue_comment", "review_comment", "discussion",
  "label", "milestone", "deploy_key", "webhook", "environment", "release", "secret",
  "variable", "workflow", "run", "artifact", "cache", "deployment", "ruleset", "invitation",
  "collaborator", "fork", "project", "pages", "security_advisory",
]

///|
fn Ledger::validate_repository_inventory(
  self : Ledger,
  key : String,
  inventory : Json,
  now_ms : Int64,
) -> Unit raise ScopeError {
  let repository = self.owned(key)
  guard repository.kind == "repository" &&
    repository.content_sha256 is Some(expected_hash) &&
    inventory
    is {
      "repository_id": String(id),
      "locator": String(locator),
      "owner": String(owner),
      "owner_id": String(owner_id),
      "private": True,
      "content_sha256": String(hash),
      "archived": True,
      "has_wiki": False,
      "has_pages": False,
      "observed_at_ms": Number(observed, ..),
      "collections": Object(collections),
      ..
    } &&
    owner == self.owner &&
    self.owner_id.map_or(true, expected => expected == owner_id) &&
    repository.remote_id == Some(id) &&
    repository.locator == locator &&
    hash == expected_hash &&
    identifier(owner_id) &&
    observed > 0 &&
    observed < 9007199254740992.0 &&
    observed == observed.to_int64().to_double() &&
    now_ms >= observed.to_int64() &&
    now_ms - observed.to_int64() <= 30000L else {
    raise OutsideScope
  }
  let required = repository_inventory_kinds.copy()
  // Live nested containers would require additional child inventories. Require
  // their precise cleanup first rather than silently omitting nested content.
  for child in self.resources.values() {
    if child.parent == Some(key) && !(child.state is (Removed | NotCreated)) {
      guard child.state == Created else { raise InvalidTransition }
      if child.kind is ("environment" | "release" | "discussion" | "project") {
        raise OutsideScope
      }
      if child.kind == "pull_request" {
        guard child.remote_id is Some(id) else { raise UnknownResource }
        required.push("pull_review:" + id)
      }
    }
  }
  guard collections.length() == required.length() &&
    required.all(kind => collections.contains(kind)) else {
    raise OutsideScope
  }
  let seen : Map[String, Unit] = Map([])
  let mut owner_seen = false
  for category, pages_json in collections {
    guard pages_json is Array(pages) &&
      !pages.is_empty() &&
      pages.length() <= 1000 else {
      raise OutsideScope
    }
    let cursors : Map[String, Unit] = Map([])
    let mut expected_cursor = ""
    for index in 0..<pages.length() {
      guard pages[index]
        is {
          "cursor": String(cursor),
          "next_cursor": next,
          "items": Array(items),
          ..
        } &&
        cursor == expected_cursor &&
        !cursors.contains(cursor) &&
        cursor.length() <= 4096 &&
        items.length() <= 100 else {
        raise OutsideScope
      }
      cursors[cursor] = ()
      for item in items {
        guard item
          is {
            "id": String(item_id),
            "locator": String(item_locator),
            "content_sha256": String(item_hash),
            ..
          } &&
          identifier(item_id) &&
          locator_valid(item_locator) &&
          content_digest(item_hash) else {
          raise OutsideScope
        }
        if category == "collaborator" &&
          item_id == owner_id &&
          item_locator == locator + "/collaborators/" + self.owner {
          guard !owner_seen else { raise OutsideScope }
          owner_seen = true
          continue
        }
        // No nested objects may disappear behind deletion of their container.
        guard !(category
          is ("environment" | "release" | "discussion" | "project")) else {
          raise OutsideScope
        }
        let resource = self.resources
          .values()
          .find_first(resource => {
            resource.remote_id == Some(item_id) &&
            resource.locator == item_locator
          })
          .unwrap_or_else(() => raise UnknownResource)
        guard !seen.contains(resource.key) &&
          resource.state == Created &&
          resource.content_sha256 == Some(item_hash) else {
          raise OutsideScope
        }
        let parent = resource.parent.unwrap_or("")
        if category.has_prefix("pull_review:") {
          guard resource.kind == "pull_review" &&
            self.resources.get(parent) is Some(pull) &&
            pull.parent == Some(key) &&
            pull.kind == "pull_request" &&
            category == "pull_review:" + pull.remote_id.unwrap_or("") else {
            raise OutsideScope
          }
        } else if category == "fork" {
          guard resource.kind == "repository" && resource.parent is None else {
            raise OutsideScope
          }
        } else {
          guard resource.kind == category && parent == key else {
            raise OutsideScope
          }
        }
        seen[resource.key] = ()
      }
      match next {
        Null => {
          guard index == pages.length() - 1 else { raise OutsideScope }
        }
        String(value) if !value.is_empty() && index < pages.length() - 1 =>
          expected_cursor = value
        _ => raise OutsideScope
      }
    }
  }
  // Missing known objects are also ambiguous: a stale or incomplete snapshot
  // must not authorize deleting a repository.
  for resource in self.resources.values() {
    if self.descends_from(resource, key) &&
      !(resource.state is (Removed | NotCreated)) {
      guard resource.state == Created && seen.contains(resource.key) else {
        raise OutsideScope
      }
    }
  }
}

///|
fn Ledger::descends_from(
  self : Ledger,
  resource : Resource,
  key : String,
) -> Bool {
  let mut parent = resource.parent
  for _ in 0..<8 {
    match parent {
      Some(value) if value == key => return true
      Some(value) =>
        parent = self.resources.get(value).bind(resource => resource.parent)
      None => return false
    }
  }
  false
}

///|
pub fn Ledger::approve_repository_deletion(
  self : Ledger,
  key : String,
  observed_id : String,
  inventory : Json,
  now_ms~ : Int64,
) -> Permit raise ScopeError {
  let repository = self.owned(key)
  self.mutation_target(key, observed_id, repository.locator)
  self.validate_repository_inventory(key, inventory, now_ms)
  {
    verb: "DELETE",
    origin: "https://api.github.com",
    path: repository.locator,
    body_sha256: digest(None),
    resource_key: key,
    creation: false,
    inventory: Some(inventory),
  }
}

///|
/// Call only after exact-ID deletion and a read-back confirming the repository
/// no longer exists. Its already-registered contents disappeared with it;
/// standalone forks/account resources retain their independent cleanup state.
pub fn Ledger::confirm_repository_removed(
  self : Ledger,
  key : String,
  observed_id : String,
) -> Unit raise ScopeError {
  let repository = self.resource(key)
  guard repository.kind == "repository" &&
    repository.remote_id == Some(observed_id) &&
    repository.state is (Created | Uncertain) else {
    raise OutsideScope
  }
  let children = self.resources
    .values()
    .filter(resource => self.descends_from(resource, key))
    .collect()
  guard children.all(resource => {
    (resource.state is (Created | Removed) && resource.remote_id is Some(_)) ||
    (
      resource.state == NotCreated &&
      resource.remote_id is None &&
      resource.content_sha256 is Some(_)
    )
  }) else {
    raise InvalidTransition
  }
  for child in children {
    if child.state != NotCreated {
      child.state = Removed
    }
  }
  repository.state = Removed
}
