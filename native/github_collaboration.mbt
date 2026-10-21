///|
/// Command-specific GraphQL operations share the existing byte transport and
/// error/redaction boundary; none of these routes exist as REST mutations.
async fn collaboration_graphql(
  client : @github.Client,
  operation : String,
  query : String,
  variables : Map[String, Json],
) -> Result[Json, @github_cli.Output] {
  account_request(
    client,
    "POST",
    "/graphql",
    body=Json::object({
      "query": Json::string(query),
      "variables": Json::object(variables),
    }),
    operation~,
  )
}

///|
fn collaboration_variables(
  repo : @github_cli.RepositoryContext,
) -> Map[String, Json] {
  { "owner": Json::string(repo.owner()), "name": Json::string(repo.name()) }
}

///|
async fn collaboration_subject(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
  selection : String,
) -> Result[Json, @github_cli.Output] {
  let selector = match parsed.positionals.get(0) {
    Some(value) => value
    None if parsed.command == "pr" =>
      match resolve_current_branch() {
        Ok(branch) => branch
        Err(error) => return Err(error)
      }
    None => return Err(@github_cli.failure(message="issue number is required"))
  }
  let number_text = if selector.has_prefix("https://") {
    let prefix = "https://" + repo.host() + "/" + repo.full_name() + "/"
    let path = if parsed.command == "pr" { "pull/" } else { "issues/" }
    guard selector.has_prefix(prefix + path) else {
      return Err(
        @github_cli.failure(message="resource URL does not match repository"),
      )
    }
    selector[(prefix + path).length():].to_owned()
  } else if selector.has_prefix("#") {
    selector[1:].to_owned()
  } else {
    selector
  }
  let variables = collaboration_variables(repo)
  let number = @string.parse_int(number_text) catch { _ => 0 }
  let (query, result_path) = if number > 0 {
    variables["number"] = Json::number(number.to_double())
    let resource = if parsed.command == "pr" { "pullRequest" } else { "issue" }
    (
      "query CollaborationSubject($owner:String!,$name:String!,$number:Int!) { repository(owner:$owner,name:$name) { " +
      resource +
      "(number:$number) { " +
      selection +
      " } } }",
      ["repository", resource],
    )
  } else if parsed.command == "pr" && !selector.has_prefix("https://") {
    variables["branch"] = Json::string(selector)
    (
      "query CollaborationBranch($owner:String!,$name:String!,$branch:String!) { repository(owner:$owner,name:$name) { pullRequests(headRefName:$branch,states:OPEN,first:1,orderBy:{field:CREATED_AT,direction:DESC}) { nodes { " +
      selection +
      " } } } }",
      ["repository", "pullRequests", "nodes"],
    )
  } else {
    return Err(@github_cli.failure(message="invalid issue number"))
  }
  let data = match
    collaboration_graphql(
      client,
      parsed.command + "." + parsed.subcommand,
      query,
      variables,
    ) {
    Ok(data) => data
    Err(error) => return Err(error)
  }
  match graphql_object_path(data, result_path) {
    Some(Object(_) as subject) => Ok(subject)
    Some(Array([Object(_) as subject, ..])) => Ok(subject)
    _ =>
      Err(
        @github_cli.failure(
          message="could not resolve " + parsed.command + " " + selector,
        ),
      )
  }
}

///|
async fn execute_collaboration_business(
  parsed : ParsedBusiness,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  base_url : String,
) -> @github_cli.Output? {
  guard (parsed.command, parsed.subcommand)
    is (("issue", "pin" | "unpin" | "develop" | "status")
    | ("pr", "checks" | "status" | "revert" | "update-branch")
    | ("repo", "deploy-key")) else {
    return None
  }
  if parsed.command == "repo" && parsed.positionals.get(0) != Some("add") {
    return None
  }
  let repo = match repository {
    Some(repo) => repo
    None =>
      match parsed.repository {
        Some(value) =>
          match @github_cli.RepositoryContext::parse(value) {
            Ok(repo) => repo
            Err(_) =>
              return Some(@github_cli.failure(message="invalid repository"))
          }
        None =>
          return Some(@github_cli.failure(message="a repository is required"))
      }
  }
  Some(
    match (parsed.command, parsed.subcommand) {
      ("issue", "pin" | "unpin") => execute_issue_pin(parsed, repo, client)
      ("issue", "develop") => execute_issue_develop(parsed, repo, client)
      ("issue" | "pr", "status") =>
        execute_collaboration_status(parsed, repo, client)
      ("pr", "checks") => execute_pr_checks(parsed, repo, client)
      ("pr", "revert" | "update-branch") =>
        execute_pr_graphql_mutation(parsed, repo, client)
      _ => execute_deploy_key_add(parsed, repo, client, base_url)
    },
  )
}

///|
async fn execute_issue_pin(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
) -> @github_cli.Output {
  let issue = match
    collaboration_subject(parsed, repo, client, "id number title isPinned") {
    Ok(issue) => issue
    Err(error) => return error
  }
  guard issue
    is {
      "id": String(id),
      "number": Number(number, ..),
      "title": String(title),
      "isPinned": pinned,
      ..
    } &&
    pinned is (True | False) else {
    return @github_cli.failure(message="invalid issue response")
  }
  let pin = parsed.subcommand == "pin"
  let label = repo.full_name() +
    "#" +
    number.to_int().to_string() +
    " (" +
    title +
    ")"
  if pinned == Json::boolean(pin) {
    return @github_cli.success(
      stdout="",
      stderr="! Issue " +
        label +
        (if pin { " is already pinned\n" } else { " is not pinned\n" }),
    )
  }
  let (operation, field, input_type) = if pin {
    ("IssuePin", "pinIssue", "PinIssueInput")
  } else {
    ("IssueUnpin", "unpinIssue", "UnpinIssueInput")
  }
  let data = match
    collaboration_graphql(
      client,
      "issue." + parsed.subcommand,
      "mutation " +
      operation +
      "($input:" +
      input_type +
      "!) { " +
      field +
      "(input:$input) { issue { id } } }",
      { "input": Json::object({ "issueId": Json::string(id) }) },
    ) {
    Ok(data) => data
    Err(error) => return error
  }
  guard graphql_object_path(data, [field, "issue", "id"]) ==
    Some(Json::string(id)) else {
    return @github_cli.failure(message="issue mutation was not confirmed")
  }
  @github_cli.success(
    stdout="",
    stderr="✓ " +
      (if pin { "Pinned" } else { "Unpinned" }) +
      " issue " +
      label +
      "\n",
  )
}

///|
async fn execute_deploy_key_add(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
  base_url : String,
) -> @github_cli.Output {
  guard parsed.positionals is ["add", path] else {
    return @github_cli.failure(
      message="accepts 1 arg(s), received " +
        (parsed.positionals.length() - 1).to_string(),
    )
  }
  let key = match account_input(path) {
    Ok(key) => key
    Err(error) => return error
  }
  let body : Json = Json::object({
    "key": Json::string(key),
    "title": Json::string(parsed.values.get("title").unwrap_or("")),
    "read_only": Json::boolean(!parsed_flag(parsed, "allow_write")),
  })
  match
    account_request(
      client,
      "POST",
      "/repos/" + repo.full_name() + "/keys",
      body~,
      operation="repo.deploy-key.add",
      http_error_url=base_url
        .strip_suffix("/")
        .unwrap_or(base_url[:])
        .to_owned() +
        "/repos/" +
        repo.full_name() +
        "/keys",
    ) {
    Ok(_) => @github_cli.success(stdout="")
    Err(error) => error
  }
}

///|
async fn execute_pr_graphql_mutation(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
) -> @github_cli.Output {
  if parsed.values.get("body") is Some(_) &&
    parsed.values.get("body_file") is Some(_) {
    return @github_cli.failure(
      message="specify only one of `--body` or `--body-file`",
    )
  }
  let pr = match
    collaboration_subject(
      parsed, repo, client, "id number title state headRefName headRefOid mergeable headRepositoryOwner { login }",
    ) {
    Ok(pr) => pr
    Err(error) => return error
  }
  guard pr
    is {
      "id": String(id),
      "number": Number(number, ..),
      "title": String(title),
      "state": String(state),
      ..
    } else {
    return @github_cli.failure(message="invalid pull request response")
  }
  let input : Map[String, Json] = { "pullRequestId": Json::string(id) }
  if parsed.subcommand == "revert" {
    guard state == "MERGED" else {
      return @github_cli.Output::new(
        stderr="X Pull request " +
          repo.full_name() +
          "#" +
          number.to_int().to_string() +
          " (" +
          title +
          ") can't be reverted because it has not been merged\n",
        exit_code=1,
      )
    }
    input["draft"] = Json::boolean(parsed_flag(parsed, "draft"))
    if parsed.values.get("title") is Some(title) && !title.is_empty() {
      input["title"] = Json::string(title)
    }
    if parsed.values.get("body_file") is Some(path) {
      match account_input(path) {
        Ok(body) => input["body"] = Json::string(body)
        Err(error) => return error
      }
    } else if parsed.values.get("body") is Some(body) {
      input["body"] = Json::string(body)
    }
    let data = match
      collaboration_graphql(
        client,
        "pr.revert",
        "mutation PullRequestRevert($input:RevertPullRequestInput!) { revertPullRequest(input:$input) { revertPullRequest { id number url } } }",
        { "input": Json::object(input) },
      ) {
      Ok(data) => data
      Err(error) => return error
    }
    match
      graphql_object_path(data, [
        "revertPullRequest", "revertPullRequest", "url",
      ]) {
      Some(String(url)) if !url.is_empty() =>
        @github_cli.success(stdout=url + "\n")
      _ => @github_cli.failure(message="revert pull request was not confirmed")
    }
  } else {
    if graphql_object_field(pr, "mergeable") ==
      Some(Json::string("CONFLICTING")) {
      return @github_cli.failure(
        message="X Cannot update PR branch due to conflicts",
      )
    }
    guard pr
      is {
        "headRefOid": String(sha),
        "headRefName": String(branch),
        "headRepositoryOwner": { "login": String(owner), .. },
        ..
      } else {
      return @github_cli.failure(
        message="pull request response has no head commit",
      )
    }
    let head = if owner == repo.owner() { branch } else { owner + ":" + branch }
    let variables = collaboration_variables(repo)
    variables["number"] = Json::number(number)
    variables["head"] = Json::string(head)
    let comparison = match
      collaboration_graphql(
        client, "pr.update-branch", "query ComparePullRequestBaseBranchWith($owner:String!,$name:String!,$number:Int!,$head:String!) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { baseRef { compare(headRef:$head) { behindBy } } } } }",
        variables,
      ) {
      Ok(data) => data
      Err(error) => return error
    }
    guard graphql_object_path(comparison, [
        "repository", "pullRequest", "baseRef", "compare", "behindBy",
      ])
      is Some(Number(behind, ..)) else {
      return @github_cli.failure(message="invalid branch comparison response")
    }
    if behind == 0 {
      return @github_cli.success(stdout="✓ PR branch already up-to-date\n")
    }
    input["expectedHeadOid"] = Json::string(sha)
    input["updateMethod"] = Json::string(
      if parsed_flag(parsed, "rebase") {
        "REBASE"
      } else {
        "MERGE"
      },
    )
    let data = match
      collaboration_graphql(
        client,
        "pr.update-branch",
        "mutation PullRequestUpdateBranch($input:UpdatePullRequestBranchInput!) { updatePullRequestBranch(input:$input) { pullRequest { id } } }",
        { "input": Json::object(input) },
      ) {
      Ok(data) => data
      Err(error) => return error
    }
    guard graphql_object_path(data, [
        "updatePullRequestBranch", "pullRequest", "id",
      ]) ==
      Some(Json::string(id)) else {
      return @github_cli.failure(message="branch update was not confirmed")
    }
    @github_cli.success(stdout="✓ PR branch updated\n")
  }
}
