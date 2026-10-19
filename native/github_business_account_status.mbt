///|
fn account_status_allowed(
  org : String,
  excluded : Array[String],
  repo : String,
) -> Bool {
  !excluded.contains(repo) && (org.is_empty() || repo.has_prefix(org + "/"))
}

///|
async fn account_status_collection(
  client : @github.Client,
  path : String,
  query : Array[(String, String)],
  max_pages : Int32,
) -> Result[Array[Json], @github_cli.Output] {
  let all : Array[Json] = []
  for page in 1..<=max_pages {
    let params = query.copy()
    params.append([("per_page", "100"), ("page", page.to_string())])
    let items = match account_request(client, "GET", path, query=params) {
      Ok(Array(items)) => items
      Ok(_) =>
        return Err(
          @github_cli.failure(message="status collection is not an array"),
        )
      Err(error) => return Err(error)
    }
    all.append(items)
    if items.length() < 100 {
      break
    }
  }
  Ok(all)
}

///|
async fn execute_account_status(
  parsed : ParsedBusiness,
  client : @github.Client,
  base_url : String,
) -> @github_cli.Output {
  let excluded : Array[String] = []
  let mut qualifier = ""
  let org = if parsed.values.get("org") is Some(org) {
    guard !org.is_empty() &&
      org.iter().all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-')) else {
      return @github_cli.failure(message="invalid organization")
    }
    qualifier += " org:" + org
    org
  } else {
    ""
  }
  for
    entry in parsed.values
    .get("exclude")
    .unwrap_or("")
    .split(",")
    .map(x => x.to_owned())
    .collect() {
    if !entry.is_empty() {
      guard @github_cli.RepositoryContext::parse(entry)
        is Ok(context) &&
        context.host() == "github.com" else {
        return @github_cli.failure(
          message="excluded repository must use OWNER/REPO",
        )
      }
      excluded.push(context.owner() + "/" + context.name())
      qualifier += " -repo:" + context.owner() + "/" + context.name()
    }
  }
  let query =
    #|query AccountStatus($assigns: String!, $reviews: String!) {
    #| assignments: search(first: 25, type: ISSUE, query: $assigns) { nodes {
    #|  ... on Issue { __typename title number updatedAt repository { nameWithOwner } }
    #|  ... on PullRequest { __typename title number updatedAt repository { nameWithOwner } }
    #| } }
    #| reviewRequested: search(first: 25, type: ISSUE, query: $reviews) { nodes {
    #|  ... on PullRequest { __typename title number updatedAt repository { nameWithOwner } }
    #| } }
    #|}
  let data = match
    account_graphql(client, query, {
      "assigns": Json::string(
        "assignee:@me state:open archived:false" + qualifier,
      ),
      "reviews": Json::string(
        "review-requested:@me state:open archived:false" + qualifier,
      ),
    }) {
    Ok(value) => value
    Err(error) => return error
  }
  guard graphql_object_path(data, ["assignments", "nodes"])
    is Some(Array(assignments)) &&
    graphql_object_path(data, ["reviewRequested", "nodes"])
    is Some(Array(reviews)) else {
    return @github_cli.failure(message="status assignment response is invalid")
  }
  let issues : Array[Json] = []
  let pulls : Array[Json] = []
  for item in assignments {
    match account_string(item, "__typename") {
      Some("Issue") => issues.push(item)
      Some("PullRequest") => pulls.push(item)
      _ if item == Json::null() => ()
      _ => return @github_cli.failure(message="unknown status assignment type")
    }
  }
  let viewer = match account_request(client, "GET", "/user") {
    Ok(value) => value
    Err(error) => return error
  }
  let login = match account_string(viewer, "login") {
    Some(value) => value
    None =>
      return @github_cli.failure(message="current user response has no login")
  }
  let notifications = match
    account_status_collection(
      client,
      "/notifications",
      [("participating", "true"), ("all", "true")],
      3,
    ) {
    Ok(value) => value
    Err(error) => return error
  }
  let mentions : Array[Json] = []
  let origin = base_url.strip_suffix("/").unwrap_or(base_url).to_owned()
  for item in notifications {
    if account_string(item, "reason") != Some("mention") {
      continue
    }
    let repo = match graphql_object_path(item, ["repository", "full_name"]) {
      Some(String(value)) => value
      _ => ""
    }
    if !account_status_allowed(org, excluded, repo) {
      continue
    }
    let url = match
      graphql_object_path(item, ["subject", "latest_comment_url"]) {
      Some(String(value)) => value
      _ => continue
    }
    guard url.has_prefix(origin + "/repos/") else {
      return @github_cli.failure(
        message="notification comment URL is outside the API origin",
      )
    }
    let comment = match
      account_request(client, "GET", url[origin.length():].to_owned()) {
      Ok(value) => value
      Err(error) => return error
    }
    if account_string(comment, "body") is Some(body) &&
      body.contains("@" + login) {
      mentions.push({
        "title": Json::string(body),
        "repository": Json::string(repo),
        "url": Json::string(url),
      })
    }
  }
  let login_segment = match business_segment(login) {
    Ok(value) => value
    Err(error) => return error
  }
  let events = match
    account_status_collection(
      client,
      "/users/" + login_segment + "/received_events",
      [],
      2,
    ) {
    Ok(value) => value
    Err(error) => return error
  }
  let activity : Array[Json] = []
  for item in events {
    let repo = match graphql_object_path(item, ["repo", "name"]) {
      Some(String(value)) => value
      _ => continue
    }
    if !account_status_allowed(org, excluded, repo) {
      continue
    }
    let opened = graphql_object_path(item, ["payload", "action"]) ==
      Some(Json::string("opened"))
    let (content, reason) = match account_string(item, "type") {
      Some("IssuesEvent") if opened =>
        (graphql_object_path(item, ["payload", "issue", "title"]), "new issue")
      Some("PullRequestEvent") if opened =>
        (
          graphql_object_path(item, ["payload", "pull_request", "title"]),
          "new PR",
        )
      Some("IssueCommentEvent" | "PullRequestReviewCommentEvent") =>
        (graphql_object_path(item, ["payload", "comment", "body"]), "comment")
      _ => continue
    }
    if content is Some(String(title)) {
      activity.push({
        "title": Json::string(title),
        "repository": Json::string(repo),
        "reason": Json::string(reason),
      })
    }
  }
  let sections : Map[String, Json] = {
    "assignedIssues": Json::array(issues),
    "assignedPullRequests": Json::array(pulls),
    "reviewRequests": Json::array(reviews),
    "mentions": Json::array(mentions),
    "repositoryActivity": Json::array(activity),
  }
  if parsed.jq is Some(_) ||
    parsed.template is Some(_) ||
    parsed.json_fields is Some(_) {
    return account_render(parsed, Json::object(sections))
  }
  let output = StringBuilder()
  for
    (field, title) in [
      ("assignedIssues", "Assigned Issues"),
      ("assignedPullRequests", "Assigned Pull Requests"),
      ("reviewRequests", "Review Requests"),
      ("mentions", "Mentions"),
      ("repositoryActivity", "Repository Activity"),
    ] {
    output.write_string(title + "\n")
    guard sections.get(field) is Some(Array(items)) else { continue }
    if items.is_empty() {
      output.write_string("  Nothing here ^_^\n")
    }
    for item in items {
      let text = account_string(item, "title")
        .unwrap_or("")
        .replace_all(old="\r", new="")
        .replace_all(old="\n", new=" ")
      output.write_string("  " + text + "\n")
    }
  }
  @github_cli.success(stdout=output.to_string())
}
