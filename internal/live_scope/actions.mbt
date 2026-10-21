///|
fn Ledger::temporary_repository(
  self : Ledger,
  resource : Resource,
) -> Resource raise ScopeError {
  let repository = if resource.kind == "repository" {
    resource
  } else if resource.kind == "job" {
    let run = self.owned(
      resource.parent.unwrap_or_else(() => raise OutsideScope),
    )
    guard run.kind == "run" &&
      resource.remote_id is Some(id) &&
      !id.is_empty() &&
      id.iter().all(ch => ch is ('0'..<='9')) &&
      resource.content_sha256 is Some(_) &&
      resource.locator == run.locator + "/jobs/" + id else {
      raise OutsideScope
    }
    let repository = self.owned(
      run.parent.unwrap_or_else(() => raise OutsideScope),
    )
    guard action_resource_path(run, repository) else { raise OutsideScope }
    repository
  } else {
    self.owned(resource.parent.unwrap_or_else(() => raise OutsideScope))
  }
  guard repository.kind == "repository" &&
    repository.parent is None &&
    repository.locator.has_prefix(
      "/repos/ZSeanYves/gh-acceptance-" + self.run_id + "-",
    ) else {
    raise OutsideScope
  }
  repository
}

///|
fn action_resource_path(resource : Resource, repository : Resource) -> Bool {
  let collection = match resource.kind {
    "workflow" => "/actions/workflows/"
    "run" => "/actions/runs/"
    "artifact" => "/actions/artifacts/"
    "cache" => "/actions/caches/"
    _ => return false
  }
  resource.remote_id is Some(id) &&
  !id.is_empty() &&
  id.iter().all(ch => ch is ('0'..<='9')) &&
  resource.locator == repository.locator + collection + id
}

///|
/// Additional endpoints are exact operations on a known resource, never a
/// prefix grant. Workflow files can only be newly created in this run's
/// disposable repository; passing an existing blob SHA is forbidden.
fn Ledger::operation_path(
  self : Ledger,
  key : String,
  verb : String,
  path : String,
) -> Bool {
  try {
    let resource = self.owned(key)
    let repository = self.temporary_repository(resource)
    guard resource.kind is ("repository" | "job") ||
      action_resource_path(resource, repository) else {
      return false
    }
    match resource.kind {
      "repository" =>
        verb == "PUT" &&
        path ==
        resource.locator +
        "/contents/.github/workflows/gh-acceptance-" +
        self.run_id +
        ".yml"
      "workflow" =>
        (
          verb == "PUT" &&
          (
            path == resource.locator + "/enable" ||
            path == resource.locator + "/disable"
          )
        ) ||
        (verb == "POST" && path == resource.locator + "/dispatches")
      "run" =>
        verb == "POST" &&
        ["/cancel", "/rerun", "/rerun-failed-jobs"].any(suffix => {
          path == resource.locator + suffix
        })
      "job" =>
        verb == "POST" &&
        path ==
        repository.locator +
        "/actions/jobs/" +
        resource.remote_id.unwrap_or("") +
        "/rerun"
      _ => false
    }
  } catch {
    _ => false
  }
}

///|
fn Ledger::validate_operation(
  self : Ledger,
  key : String,
  verb : String,
  path : String,
  body : Bytes?,
) -> Unit raise ScopeError {
  guard self.operation_path(key, verb, path) else { raise OutsideScope }
  let resource = self.owned(key)
  let repository = self.temporary_repository(resource)
  let fields = match body {
    None => Map([])
    Some(bytes) => {
      let value = @json.parse(
        @utf8.decode(bytes) catch {
          _ => raise OutsideScope
        },
      ) catch {
        _ => raise OutsideScope
      }
      guard value is Object(fields) else { raise OutsideScope }
      fields
    }
  }
  if resource.kind == "repository" {
    guard fields.length() == 2 &&
      fields.get("message") ==
      Some(Json("gh-acceptance-" + self.run_id + "-workflow")) &&
      fields.get("content") is Some(String(content)) &&
      !content.is_empty() &&
      content.length() <= 65536 &&
      content
      .iter()
      .all(ch => ch is ('A'..<='Z' | 'a'..<='z' | '0'..<='9' | '+' | '/' | '=')) else {
      raise OutsideScope
    }
  } else if resource.kind == "workflow" && path.has_suffix("/dispatches") {
    guard fields
      .keys()
      .all(key => key is ("ref" | "inputs" | "return_run_details")) &&
      fields.get("return_run_details") is (None | Some(True)) &&
      fields.get("ref") is Some(String(branch)) &&
      identifier(branch) &&
      fields.get("inputs") is Some(Object(inputs)) &&
      inputs.length() == 2 &&
      inputs.get("mode") is Some(String("success" | "failure" | "wait")) &&
      inputs.get("nonce") is Some(String(nonce)) &&
      identifier(nonce) &&
      nonce.has_prefix("gh-acceptance-" + self.run_id + "-") &&
      self.resources
      .values()
      .any(child => {
        child.kind == "git_ref" &&
        child.parent == Some(repository.key) &&
        child.state == Created &&
        child.remote_id is Some(_) &&
        child.content_sha256 is Some(_) &&
        child.locator == repository.locator + "/git/refs/heads/" + branch
      }) else {
      raise OutsideScope
    }
  } else if resource.kind is ("run" | "job") &&
    (path.has_suffix("/rerun") || path.has_suffix("/rerun-failed-jobs")) {
    guard fields.keys().all(key => key == "enable_debug_logging") &&
      fields.get("enable_debug_logging") is (None | Some(True | False)) else {
      raise OutsideScope
    }
  } else {
    guard fields.is_empty() else { raise OutsideScope }
  }
}

///|
pub fn Ledger::approve_operation(
  self : Ledger,
  key : String,
  observed_id : String,
  verb : String,
  path : String,
  body? : Bytes,
) -> Permit raise ScopeError {
  let resource = self.owned(key)
  self.check_owned(key, observed_id, resource.locator)
  self.validate_operation(key, verb, path, body)
  {
    origin: "https://api.github.com",
    verb,
    path,
    body_sha256: digest(body),
    resource_key: key,
    creation: false,
    inventory: None,
  }
}
