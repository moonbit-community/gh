///|
/// gh accepts signed decimal int64 workflow selectors and file names. Keep the
/// original selector in the GET URL; the returned ID owns subsequent mutations.
pub fn workflow_selector_is_direct(selector : String) -> Bool {
  let lower = selector.to_lower()
  if lower.has_suffix(".yml") || lower.has_suffix(".yaml") {
    return true
  }
  let digits = if selector.has_prefix("+") || selector.has_prefix("-") {
    selector[1:]
  } else {
    selector[:]
  }
  guard !digits.is_empty() && digits.iter().all(ch => ch is ('0'..<='9')) else {
    return false
  }
  try {
    ignore(@string.parse_int64(selector))
    true
  } catch {
    _ => false
  }
}

///|
/// The limit applies before CLI state filtering. Stop on short pages, not on
/// total_count or a Link URL controlled by the remote response.
pub async fn list_workflows(
  client : @github.Client,
  repository : String,
  limit~ : Int32 = 50,
) -> Result[Array[Workflow], @github.GitHubError] {
  guard valid_repository(repository) && limit >= 0 else {
    return Err(
      @github.GitHubError::invalid_request(
        "invalid workflow repository or limit",
      ),
    )
  }
  let per_page = if limit == 0 { 100 } else { limit.min(100) }
  let workflows : Array[Workflow] = []
  let ids : Map[String, Unit] = Map([])
  for page in 1..<=1000 {
    let value = match
      request_json(
        client,
        "/repos/" +
        repository +
        "/actions/workflows?page=" +
        page.to_string() +
        "&per_page=" +
        per_page.to_string(),
        operation_id="workflows",
        operation_name="actions.workflow.list",
      ) {
      Ok((value, _)) => value
      Err(error) => return Err(error)
    }
    guard value is { "workflows": Array(items), .. } else {
      return Err(@github.GitHubError::decode("invalid workflow collection"))
    }
    for item in items {
      let workflow = match decode_workflow(item) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      guard !ids.contains(workflow.id) else {
        return Err(
          @github.GitHubError::decode("repeated workflow ID across pages"),
        )
      }
      ids[workflow.id] = ()
      workflows.push(workflow)
      if limit > 0 && workflows.length() == limit {
        return Ok(workflows)
      }
    }
    if items.length() < per_page {
      return Ok(workflows)
    }
  }
  Err(@github.GitHubError::decode("workflow pagination limit reached"))
}

///|
pub async fn set_workflow_enabled(
  client : @github.Client,
  repository : String,
  workflow_id : String,
  enabled : Bool,
) -> Result[Unit, @github.GitHubError] {
  guard valid_repository(repository) && numeric_id(workflow_id) else {
    return Err(
      @github.GitHubError::invalid_request("invalid workflow ID or repository"),
    )
  }
  match
    client.request(
      @github.Request::new(
        verb="PUT",
        path="/repos/" +
          repository +
          "/actions/workflows/" +
          workflow_id +
          (if enabled { "/enable" } else { "/disable" }),
      ),
      operation_id="workflow-state",
      operation_name="actions.workflow.state",
    ) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}
