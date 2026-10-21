///|
/// Field names are selected from a closed table before they enter GraphQL.
fn collaboration_selection(
  parsed : ParsedBusiness,
) -> Result[String, @github_cli.Output] {
  let common = [
    "id", "number", "title", "body", "state", "url", "createdAt", "updatedAt", "closedAt",
    "closed", "locked",
  ]
  let pr_fields = [
    "headRefName", "headRefOid", "baseRefName", "baseRefOid", "isDraft", "mergedAt",
    "mergeable", "mergeStateStatus", "reviewDecision", "isCrossRepository", "additions",
    "deletions", "changedFiles", "maintainerCanModify",
  ]
  let selection = StringBuilder()
  selection.write_string("number title state")
  if parsed.command == "pr" {
    selection.write_string(
      " headRefName isCrossRepository headRepositoryOwner { id login ... on User { name } }",
    )
  } else if parsed.json_fields is None {
    selection.write_string(" updatedAt labels(first:100) { nodes { name } }")
  }
  let fields = parsed.json_fields.unwrap_or("number,title,state")
  for field in fields.split(",") {
    let field = field.trim().to_owned()
    let fragment = if common.contains(field) ||
      (parsed.command == "pr" && pr_fields.contains(field)) {
      field
    } else {
      match field {
        "author" => "author { login ... on User { id name } }"
        "labels" => "labels(first:100) { nodes { id name description color } }"
        "assignees" =>
          "assignees(first:100) { nodes { id login name databaseId } }"
        "milestone" => "milestone { number title description dueOn }"
        "headRepositoryOwner" if parsed.command == "pr" =>
          "headRepositoryOwner { id login ... on User { name } }"
        "headRepository" if parsed.command == "pr" =>
          "headRepository { id name nameWithOwner }"
        _ =>
          return Err(
            @github_cli.failure(message="unknown JSON field: " + field),
          )
      }
    }
    selection.write_string(" " + fragment)
  }
  Ok(selection.to_string())
}

///|
fn collaboration_export_item(value : Json, names : Array[String]) -> Json {
  let output : Map[String, Json] = Map([])
  for name in names {
    let value = business_json_lookup(value, [name])
    output[name] = if name == "author" {
      let login = account_string(value, "login").unwrap_or("")
      match account_string(value, "id") {
        Some(id) if !id.is_empty() =>
          Json::object({
            "id": Json::string(id),
            "login": Json::string(login),
            "name": Json::string(account_string(value, "name").unwrap_or("")),
            "is_bot": Json::boolean(false),
          })
        _ =>
          Json::object({
            "login": Json::string("app/" + login),
            "is_bot": Json::boolean(true),
          })
      }
    } else if name == "headRepositoryOwner" {
      let owner : Map[String, Json] = {
        "login": Json::string(account_string(value, "login").unwrap_or("")),
      }
      for key in ["id", "name"] {
        if account_string(value, key) is Some(text) && !text.is_empty() {
          owner[key] = Json::string(text)
        }
      }
      Json::object(owner)
    } else {
      match value {
        { "nodes": Array(items), .. } => Json::array(items)
        _ => value
      }
    }
  }
  Json::object(output)
}

///|
async fn execute_collaboration_status(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
) -> @github_cli.Output {
  guard parsed.positionals.is_empty() else {
    return @github_cli.failure(
      message="accepts 0 arg(s), received " +
        parsed.positionals.length().to_string(),
    )
  }
  let selection = match collaboration_selection(parsed) {
    Ok(selection) => selection
    Err(error) => return error
  }
  let variables = collaboration_variables(repo)
  let mut current : Json = Json::null()
  let groups : Array[(String, String, String, Array[Json])] = []
  if parsed.command == "issue" {
    let viewer = match
      collaboration_graphql(
        client,
        "issue.status",
        "query StatusViewer { viewer { login } }",
        {},
      ) {
      Ok(data) => data
      Err(error) => return error
    }
    guard graphql_object_path(viewer, ["viewer", "login"])
      is Some(String(login)) else {
      return @github_cli.failure(message="viewer identity was not returned")
    }
    variables["viewer"] = Json::string(login)
    let query = "query IssueStatus($owner:String!,$name:String!,$viewer:String!) { repository(owner:$owner,name:$name) { hasIssuesEnabled " +
      "assigned: issues(filterBy:{assignee:$viewer,states:OPEN},first:10,orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { " +
      selection +
      " } } " +
      "mentioned: issues(filterBy:{mentioned:$viewer,states:OPEN},first:10,orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { " +
      selection +
      " } } " +
      "authored: issues(filterBy:{createdBy:$viewer,states:OPEN},first:10,orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { " +
      selection +
      " } } } }"
    let data = match
      collaboration_graphql(client, "issue.status", query, variables) {
      Ok(data) => data
      Err(error) => return error
    }
    if graphql_object_path(data, ["repository", "hasIssuesEnabled"]) ==
      Some(Json::boolean(false)) {
      return @github_cli.failure(
        message="the '" + repo.full_name() + "' repository has disabled issues",
      )
    }
    for
      (field, key, title, empty) in [
        (
          "assigned", "assigned", "Issues assigned to you", "There are no issues assigned to you",
        ),
        (
          "mentioned", "mentioned", "Issues mentioning you", "There are no issues mentioning you",
        ),
        (
          "authored", "createdBy", "Issues opened by you", "There are no issues opened by you",
        ),
      ] {
      guard graphql_object_path(data, ["repository", field, "nodes"])
        is Some(Array(items)) else {
        return @github_cli.failure(message="invalid issue status collection")
      }
      groups.push((key, title, empty, items))
    }
  } else {
    let branch = repo.branch().unwrap_or("")
    variables["head"] = Json::string(branch)
    variables["created"] = Json::string(
      "repo:" + repo.full_name() + " state:open is:pr author:@me",
    )
    variables["review"] = Json::string(
      "repo:" + repo.full_name() + " state:open review-requested:@me",
    )
    let query = "query PullRequestStatus($owner:String!,$name:String!,$head:String!,$created:String!,$review:String!) { " +
      "repository(owner:$owner,name:$name) { pullRequests(headRefName:$head,first:10,orderBy:{field:CREATED_AT,direction:DESC}) { nodes { headRefName " +
      selection +
      " } } } " +
      "created: search(query:$created,type:ISSUE,first:10) { nodes { ... on PullRequest { " +
      selection +
      " } } } " +
      "review: search(query:$review,type:ISSUE,first:10) { nodes { ... on PullRequest { " +
      selection +
      " } } } }"
    let data = match
      collaboration_graphql(client, "pr.status", query, variables) {
      Ok(data) => data
      Err(error) => return error
    }
    if !branch.is_empty() &&
      graphql_object_path(data, ["repository", "pullRequests", "nodes"])
      is Some(Array(items)) {
      for item in items {
        if graphql_object_field(item, "headRefName") ==
          Some(Json::string(branch)) {
          current = item
          break
        }
      }
    }
    for
      (field, key, title, empty) in [
        (
          "created", "createdBy", "Created by you", "You have no open pull requests",
        ),
        (
          "review", "needsReview", "Requesting a code review from you", "You have no pull requests to review",
        ),
      ] {
      guard graphql_object_path(data, [field, "nodes"]) is Some(Array(items)) else {
        return @github_cli.failure(
          message="invalid pull request status collection",
        )
      }
      groups.push((key, title, empty, items))
    }
  }
  if parsed.json_fields is Some(fields) {
    let names = fields
      .split(",")
      .map(value => value.trim().to_owned())
      .collect()
    let result : Map[String, Json] = Map([])
    if parsed.command == "pr" && current != Json::null() {
      result["currentBranch"] = collaboration_export_item(current, names)
    }
    for (key, _, _, items) in groups {
      result[key] = Json::array(
        items.map(item => collaboration_export_item(item, names)),
      )
    }
    return render_github_response(
      200,
      [],
      @utf8.encode(Json::object(result).stringify()),
      jq?=parsed.jq,
      template?=parsed.template,
    )
  }
  let output = StringBuilder()
  output.write_string(
    "\nRelevant " +
    (if parsed.command == "pr" { "pull requests" } else { "issues" }) +
    " in " +
    repo.full_name() +
    "\n\n",
  )
  if parsed.command == "pr" && parsed.repository is None {
    output.write_string("Current branch\n")
    if current == Json::null() {
      output.write_string(
        "  There is no pull request associated with [" +
        repo.branch().unwrap_or("") +
        "]\n",
      )
    } else {
      collaboration_status_row(output, current, true)
    }
    output.write_string("\n")
  }
  for (_, title, empty, items) in groups {
    output.write_string(title + "\n")
    if items.is_empty() {
      output.write_string("  " + empty + "\n")
    }
    for item in items {
      collaboration_status_row(output, item, parsed.command == "pr")
    }
    output.write_string("\n")
  }
  @github_cli.success(stdout=output.to_string())
}

///|
fn collaboration_status_row(
  output : StringBuilder,
  item : Json,
  pr : Bool,
) -> Unit {
  let number = business_json_lookup(item, ["number"]).stringify()
  let title = account_string(item, "title").unwrap_or("")
  if pr {
    let owner = if graphql_object_field(item, "isCrossRepository") ==
      Some(Json::boolean(true)) {
      match graphql_object_path(item, ["headRepositoryOwner", "login"]) {
        Some(String(owner)) => owner + ":"
        _ => ""
      }
    } else {
      ""
    }
    output.write_string(
      "  #" +
      number +
      "  " +
      title +
      " [" +
      owner +
      account_string(item, "headRefName").unwrap_or("") +
      "]",
    )
  } else {
    let labels = match graphql_object_path(item, ["labels", "nodes"]) {
      Some(Array(labels)) =>
        labels
        .map(label => account_string(label, "name").unwrap_or(""))
        .join(", ")
      _ => ""
    }
    output.write_string(
      "  " +
      number +
      "\t" +
      account_string(item, "state").unwrap_or("") +
      "\t" +
      title +
      "\t" +
      labels +
      "\t" +
      account_string(item, "updatedAt").unwrap_or("0001-01-01T00:00:00Z"),
    )
  }
  output.write_string("\n")
}
