///|
pub struct WorkflowAnnotation {
  job_name : String
  message : String
  path : String
  level : String
  start_line : Int64
}

///|
/// None means the token cannot read annotations; a missing check run is an
/// empty collection, matching the fixed gh API policy.
pub async fn workflow_annotations(
  client : @github.Client,
  repository : String,
  job : WorkflowJob,
) -> Result[Array[WorkflowAnnotation]?, @github.GitHubError] {
  guard valid_repository(repository) && numeric_id(job.id) else {
    return Err(
      @github.GitHubError::invalid_request("invalid annotations identity"),
    )
  }
  let (value, _) = match
    request_json(
      client,
      "/repos/" + repository + "/check-runs/" + job.id + "/annotations",
    ) {
    Ok(value) => value
    Err(error) => {
      if error.response() is Some(response) {
        if response.status() == 404 {
          return Ok(Some([]))
        }
        if response.status() == 403 {
          return Ok(None)
        }
      }
      return Err(error)
    }
  }
  guard value is Array(items) else {
    return Err(@github.GitHubError::decode("invalid annotations collection"))
  }
  Ok(
    Some(
      items.map(item => {
        job_name: job.name,
        message: text(item, "message"),
        path: text(item, "path"),
        level: text(item, "annotation_level"),
        start_line: match field(item, "start_line") {
          Number(value, ..) => value.to_int64()
          _ => 0L
        },
      }),
    ),
  )
}

///|
pub async fn workflow_run_pull_request(
  client : @github.Client,
  repository : String,
  run : WorkflowRun,
) -> Result[String?, @github.GitHubError] {
  guard valid_repository(repository) &&
    repository.split_once("/") is Some((owner, repo)) else {
    return Err(@github.GitHubError::invalid_request("invalid run repository"))
  }
  // Preserve the pinned query along with variables in differential captures.
  let query = "\n\t\tquery PullRequestForRun($owner: String!, $repo: String!, $headRefName: String!) {\n\t\t\trepository(owner: $owner, name: $repo) {\n\t\t\t\tpullRequests(headRefName: $headRefName, first: 1, orderBy: { field: CREATED_AT, direction: DESC }) {\n\t\t\t\t\tnodes {\n\t\t\t\t\t\tnumber\n\t\t\t\t\t\theadRepository {\n\t\t\t\t\t\t\towner {\n\t\t\t\t\t\t\t\tlogin\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\tname\n\t\t\t\t\t\t}\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}"
  let envelope = match
    client.graphql(
      @github.GraphQLRequest::new(query~, variables={
        "owner": owner.to_owned(),
        "repo": repo.to_owned(),
        "headRefName": run.head_branch,
      }),
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !envelope.errors.is_empty() {
    return Err(@github.GitHubError::graphql(envelope.response, envelope.errors))
  }
  if envelope.data
    is Some(
      {
        "repository": { "pullRequests": { "nodes": Array(nodes), .. }, .. },
        ..
      }
    ) {
    let mut number = None
    for node in nodes {
      let head = field(node, "headRepository")
      if text(field(head, "owner"), "login") + "/" + text(head, "name") ==
        run.head_repository {
        number = id(node, "number")
      }
    }
    return Ok(number)
  }
  Ok(None)
}
