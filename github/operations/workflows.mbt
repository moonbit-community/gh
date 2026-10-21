///|
pub struct Workflow {
  id : String
  name : String
  path : String
  state : String
}

///|
fn decode_workflow(value : Json) -> Result[Workflow, @github.GitHubError] {
  guard id(value, "id") is Some(id) &&
    value
    is {
      "name": String(name),
      "path": String(path),
      "state": String(state),
      ..
    } else {
    return Err(@github.GitHubError::decode("invalid workflow metadata"))
  }
  Ok({ id, name, path, state, })
}

///|
/// Numeric/file selectors use the direct endpoint, including disabled
/// workflows. Name lookup follows gh's case-insensitive active-state filter.
pub async fn resolve_workflow(
  client : @github.Client,
  repository : String,
  selector : String,
  include_disabled~ : Bool = false,
  states? : Array[String],
) -> Result[Workflow, @github.GitHubError] {
  guard valid_repository(repository) && !selector.is_empty() else {
    return Err(
      @github.GitHubError::invalid_request(
        "invalid workflow selector or repository",
      ),
    )
  }
  let collection = "/repos/" + repository + "/actions/workflows"
  let lower = selector.to_lower()
  if workflow_selector_is_direct(selector) {
    let value = match
      request_json(
        client,
        collection + "/" + @percent.encode(selector),
        operation_id="workflow",
        operation_name="actions.workflow.get",
      ) {
      Ok((value, _)) => value
      Err(error) => return Err(error)
    }
    return decode_workflow(value)
  }
  let matches : Array[Workflow] = []
  let ids : Map[String, Unit] = Map([])
  for page in 1..<=1000 {
    let value = match
      request_json(
        client,
        collection + "?page=" + page.to_string() + "&per_page=100",
        operation_id="workflow",
        operation_name="actions.workflow.list",
      ) {
      Ok((value, _)) => value
      Err(error) => return Err(error)
    }
    guard value is { "workflows": Array(items), .. } && items.length() <= 100 else {
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
      if workflow.name.to_lower() == lower &&
        states.map_or(include_disabled || workflow.state == "active", values => {
          values.contains(workflow.state)
        }) {
        matches.push(workflow)
      }
    }
    if items.length() < 100 {
      return match matches {
        [] =>
          Err(
            @github.GitHubError::invalid_request(
              "could not find any workflows named " + selector,
            ),
          )
        [workflow] => Ok(workflow)
        _ =>
          Err(
            @github.GitHubError::invalid_request(
              "could not resolve to a unique workflow; found:" +
              matches
              .map(workflow => {
                " " +
                workflow.path
                .rev_split_once("/")
                .map_or(workflow.path, pair => pair.1.to_owned())
              })
              .join(""),
            ),
          )
      }
    }
  }
  Err(@github.GitHubError::decode("workflow pagination limit reached"))
}

///|
pub async fn workflow_default_branch(
  client : @github.Client,
  repository : String,
) -> Result[String, @github.GitHubError] {
  guard valid_repository(repository) &&
    repository.split_once("/") is Some((owner, name)) else {
    return Err(
      @github.GitHubError::invalid_request("invalid workflow repository"),
    )
  }
  let query =
    #|query RepositoryInfo($owner: String!, $name: String!) {
    #|  repository(owner: $owner, name: $name) {
    #|    ...repo parent { ...repo }
    #|    mergeCommitAllowed rebaseMergeAllowed squashMergeAllowed
    #|  }
    #|}
    #|fragment repo on Repository {
    #|  id databaseId name owner { login } sshUrl hasIssuesEnabled
    #|  description hasWikiEnabled viewerPermission defaultBranchRef { name }
    #|}
  let envelope = match
    client.graphql(
      @github.GraphQLRequest::new(query~, variables={
        "owner": owner.to_owned(),
        "name": name.to_owned(),
      }),
      operation_id="workflow-default-branch",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !envelope.errors.is_empty() {
    return Err(@github.GitHubError::graphql(envelope.response, envelope.errors))
  }
  match envelope.data {
    Some(
      {
        "repository": { "defaultBranchRef": { "name": String(branch), .. }, .. },
        ..
      }
    ) => Ok(branch)
    _ =>
      Err(@github.GitHubError::decode("repository default branch unavailable"))
  }
}

///|
pub struct WorkflowDispatch {
  run_id : String?
  html_url : String
}

///|
pub async fn dispatch_workflow(
  client : @github.Client,
  repository : String,
  workflow_id : String,
  ref_name : String,
  inputs : Json,
  return_run_details~ : Bool = true,
) -> Result[WorkflowDispatch, @github.GitHubError] {
  guard valid_repository(repository) &&
    numeric_id(workflow_id) &&
    !ref_name.is_empty() &&
    (
      inputs is Null ||
      (
        inputs is Object(fields) &&
        fields.values().all(value => value is String(_))
      )
    ) else {
    return Err(
      @github.GitHubError::invalid_request(
        "invalid workflow dispatch parameters",
      ),
    )
  }
  let fields : Map[String, Json] = { "ref": ref_name, "inputs": inputs }
  if return_run_details {
    fields["return_run_details"] = Json(true)
  }
  let response = match
    client.request(
      @github.Request::new(
        verb="POST",
        path="/repos/" +
          repository +
          "/actions/workflows/" +
          workflow_id +
          "/dispatches",
        body=@utf8.encode(Json::object(fields).stringify()),
      ),
      operation_id="workflow-dispatch",
      operation_name="actions.workflow.dispatch",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if response.status() == 204 {
    return Ok({ run_id: None, html_url: "", })
  }
  let value = @json.parse(@utf8.decode(response.body())) catch {
    _ =>
      return Err(
        @github.GitHubError::decode("invalid workflow dispatch response"),
      )
  }
  guard value is Object(fields) else {
    return Err(
      @github.GitHubError::decode("invalid workflow dispatch response"),
    )
  }
  let html_url = match fields.get("html_url") {
    None | Some(Null) => ""
    Some(String(value)) => value
    _ => return Err(@github.GitHubError::decode("invalid workflow run URL"))
  }
  let run_id = match fields.get("workflow_run_id") {
    None | Some(Null) | Some(Number(0, ..)) => None
    Some(_) => {
      guard id(value, "workflow_run_id") is Some(id) else {
        return Err(@github.GitHubError::decode("invalid workflow run ID"))
      }
      Some(id)
    }
  }
  Ok({ run_id, html_url, })
}
