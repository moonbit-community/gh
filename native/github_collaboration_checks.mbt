///|
async fn collaboration_checks(
  client : @github.Client,
  id : String,
) -> Result[Array[Json], @github_cli.Output] {
  let checks : Array[Json] = []
  let seen : Map[String, Bool] = Map([])
  let variables : Map[String, Json] = {
    "id": Json::string(id),
    "after": Json::null(),
  }
  let query =
    #|query PullRequestStatusChecks($id:ID!,$after:String) {
    #|  node(id:$id) { ... on PullRequest { commits(last:1) { nodes {
    #|    commit { statusCheckRollup { contexts(first:100,after:$after) {
    #|      nodes {
    #|        __typename
    #|        ... on StatusContext { context state targetUrl description createdAt isRequired(pullRequestId:$id) }
    #|        ... on CheckRun { name status conclusion startedAt completedAt detailsUrl isRequired(pullRequestId:$id) checkSuite { workflowRun { event workflow { name } } } }
    #|      }
    #|      pageInfo { hasNextPage endCursor }
    #|    } } }
    #|  } } } }
    #|}
  for page = 0; page < 1000; page = page + 1 {
    let data = match
      collaboration_graphql(client, "pr.checks", query, variables) {
      Ok(data) => data
      Err(error) => return Err(error)
    }
    guard graphql_object_path(data, ["node", "commits", "nodes"])
      is Some(Array(commits)) &&
      commits.get(0) is Some(commit) else {
      return Err(
        @github_cli.failure(message="no commit found on the pull request"),
      )
    }
    if graphql_object_path(commit, ["commit", "statusCheckRollup"]) ==
      Some(Json::null()) {
      return Ok(checks)
    }
    guard graphql_object_path(commit, [
        "commit", "statusCheckRollup", "contexts",
      ])
      is Some(contexts) &&
      contexts
      is { "nodes": Array(nodes), "pageInfo": { "hasNextPage": more, .. }, .. } &&
      more is (True | False) else {
      return Err(@github_cli.failure(message="invalid check contexts response"))
    }
    checks.append(nodes)
    if more == Json::boolean(false) {
      return Ok(checks)
    }
    guard graphql_object_path(contexts, ["pageInfo", "endCursor"])
      is Some(String(cursor)) &&
      !cursor.is_empty() &&
      !seen.contains(cursor) else {
      return Err(
        @github_cli.failure(message="repeated or missing check cursor"),
      )
    }
    seen[cursor] = true
    variables["after"] = Json::string(cursor)
  }
  Err(@github_cli.failure(message="check pagination limit exceeded"))
}

///|
fn collaboration_check_items(
  contexts : Array[Json],
  required : Bool,
) -> Array[Json] {
  let contexts = contexts.copy()
  contexts.sort_by((a, b) => {
    account_string(b, "startedAt")
    .unwrap_or("")
    .compare(account_string(a, "startedAt").unwrap_or(""))
  })
  let seen : Map[String, Bool] = Map([])
  let result : Array[Json] = []
  for item in contexts {
    let legacy = account_string(item, "context")
    let name = legacy.unwrap_or(account_string(item, "name").unwrap_or(""))
    let workflow = match
      graphql_object_path(item, [
        "checkSuite", "workflowRun", "workflow", "name",
      ]) {
      Some(String(name)) => name
      _ => ""
    }
    let event = match
      graphql_object_path(item, ["checkSuite", "workflowRun", "event"]) {
      Some(String(event)) => event
      _ => ""
    }
    let key = if legacy is Some(_) {
      "status:" + name
    } else {
      "check:" + name + "/" + workflow + "/" + event
    }
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    if required &&
      graphql_object_field(item, "isRequired") != Some(Json::boolean(true)) {
      continue
    }
    let state = match account_string(item, "state") {
      Some(state) => state
      None =>
        if account_string(item, "status") == Some("COMPLETED") {
          account_string(item, "conclusion").unwrap_or("")
        } else {
          account_string(item, "status").unwrap_or("")
        }
    }
    let bucket = match state {
      "SUCCESS" => "pass"
      "SKIPPED" | "NEUTRAL" => "skipping"
      "ERROR" | "FAILURE" | "TIMED_OUT" | "ACTION_REQUIRED" => "fail"
      "CANCELLED" => "cancel"
      _ => "pending"
    }
    result.push(
      Json::object({
        "name": Json::string(name),
        "state": Json::string(state),
        "bucket": Json::string(bucket),
        "link": Json::string(
          account_string(item, "detailsUrl").unwrap_or(
            account_string(item, "targetUrl").unwrap_or(""),
          ),
        ),
        "startedAt": Json::string(
          account_string(item, "startedAt").unwrap_or("0001-01-01T00:00:00Z"),
        ),
        "completedAt": Json::string(
          account_string(item, "completedAt").unwrap_or("0001-01-01T00:00:00Z"),
        ),
        "workflow": Json::string(workflow),
        "event": Json::string(event),
        "description": Json::string(
          account_string(item, "description").unwrap_or(""),
        ),
      }),
    )
  }
  result
}

///|
fn collaboration_check_elapsed(item : Json) -> String {
  try {
    let start = account_string(item, "startedAt").unwrap_or("")
    let end = account_string(item, "completedAt").unwrap_or("")
    if start.has_prefix("0001-") || end.has_prefix("0001-") {
      return "0"
    }
    guard start.strip_suffix("Z") is Some(start) &&
      end.strip_suffix("Z") is Some(end) else {
      return "0"
    }
    let start : @time.PlainDateTime = @string.from_str(start)
    let end : @time.PlainDateTime = @string.from_str(end)
    let seconds = end.to_unix_second() - start.to_unix_second()
    if seconds <= 0 {
      return "0"
    }
    @time.Duration::of(seconds~).to_string()
  } catch {
    _ => "0"
  }
}

///|
async fn execute_pr_checks(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
) -> @github_cli.Output {
  if parsed_flag(parsed, "watch") && parsed.json_fields is Some(_) {
    return @github_cli.failure(message="cannot use `--watch` with `--json`")
  }
  if parsed.json_fields is Some(fields) {
    for field in fields.split(",") {
      if ![
          "bucket", "completedAt", "description", "event", "link", "name", "startedAt",
          "state", "workflow",
        ].contains(field.to_owned()) {
        return @github_cli.failure(
          message="unknown JSON field: " + field.to_owned(),
        )
      }
    }
  }
  let pr = match
    collaboration_subject(parsed, repo, client, "id number headRefName") {
    Ok(pr) => pr
    Err(error) => return error
  }
  guard pr
    is {
      "id": String(id),
      "headRefName": String(branch),
      "number": Number(number, ..),
      ..
    } else {
    return @github_cli.failure(message="invalid pull request response")
  }
  if parsed_flag(parsed, "web") {
    let browser = configured_browser(Some(repo.host()))
    return match
      open_browser(
        browser,
        "https://" +
        repo.host() +
        "/" +
        repo.full_name() +
        "/pull/" +
        number.to_int().to_string() +
        "/checks",
      ) {
      Ok(result) if result.exit_code() == 0 => @github_cli.success(stdout="")
      _ => @github_cli.failure(message="browser command failed")
    }
  }
  let interval = @string.parse_int(
    parsed.values.get("interval").unwrap_or("10"),
  ) catch {
    _ => 0
  }
  guard interval > 0 && interval <= 3600 else {
    return @github_cli.failure(message="invalid check interval")
  }
  let required = parsed_flag(parsed, "required")
  let output = StringBuilder()
  while true {
    let contexts = match collaboration_checks(client, id) {
      Ok(contexts) => contexts
      Err(error) => return error
    }
    let items = collaboration_check_items(contexts, required)
    if items.is_empty() {
      return @github_cli.Output::new(
        stderr="no " +
          (if required { "required " } else { "" }) +
          "checks reported on the '" +
          branch +
          "' branch\n",
        exit_code=1,
      )
    }
    if parsed.json_fields is Some(_) {
      return account_render(parsed, Json::array(items))
    }
    let failed = items.any(item => {
      account_string(item, "bucket") == Some("fail")
    })
    let pending = items.any(item => {
      account_string(item, "bucket") == Some("pending")
    })
    items.sort_by((a, b) => {
      let rank = fn(item) {
        match account_string(item, "bucket") {
          Some("fail") => 0
          Some("pending") => 1
          _ => 2
        }
      }
      let order = rank(a).compare(rank(b))
      if order != 0 {
        order
      } else {
        account_string(a, "name")
        .unwrap_or("")
        .compare(account_string(b, "name").unwrap_or(""))
      }
    })
    for item in items {
      let bucket = account_string(item, "bucket").unwrap_or("")
      output.write_string(
        account_string(item, "name").unwrap_or("") +
        "\t" +
        (if bucket == "cancel" { "fail" } else { bucket }) +
        "\t" +
        collaboration_check_elapsed(item) +
        "\t" +
        account_string(item, "link").unwrap_or("") +
        "\t" +
        account_string(item, "description").unwrap_or("") +
        "\n",
      )
    }
    if !parsed_flag(parsed, "watch") ||
      !pending ||
      (failed && parsed_flag(parsed, "fail_fast")) {
      return @github_cli.Output::new(
        stdout=output.to_string(),
        exit_code=if failed { 1 } else if pending { 8 } else { 0 },
      )
    }
    @async.sleep(interval * 1000)
  }
  @github_cli.failure(message="check polling stopped")
}
