///|
async fn account_graphql(
  client : @github.Client,
  query : String,
  variables : Map[String, Json],
) -> Result[Json, @github_cli.Output] {
  account_request(client, "POST", "/graphql", body={
    "query": Json::string(query),
    "variables": Json::object(variables),
  })
}

///|
async fn execute_account_project(
  parsed : ParsedBusiness,
  client : @github.Client,
) -> @github_cli.Output {
  let sub = parsed.subcommand
  for
    option in [
      "title", "description", "readme", "visibility", "owner", "format",
    ] {
    if parsed_flag(parsed, option) {
      return @github_cli.failure(message="--" + option + " requires a value")
    }
  }
  if parsed_flag(parsed, "web") {
    return @github_cli.failure(
      message="project browser interaction is not available",
    )
  }
  guard sub is ("list" | "view" | "create" | "edit" | "close" | "delete") else {
    return @github_cli.failure(message="unsupported project command: " + sub)
  }
  if parsed.values.get("format") is Some(format) && format != "json" {
    return @github_cli.failure(message="project output format must be json")
  }
  let mut number = 0
  if !(sub is ("list" | "create")) {
    guard parsed.positionals.length() == 1 else {
      return @github_cli.failure(message="project number is required")
    }
    number = @string.parse_int(parsed.positionals[0]) catch {
      _ => return @github_cli.failure(message="invalid project number")
    }
    guard number > 0 else {
      return @github_cli.failure(message="invalid project number")
    }
  } else if !parsed.positionals.is_empty() {
    return @github_cli.failure(message="unexpected project argument")
  }
  let input : Map[String, Json] = Map([])
  if sub == "create" {
    guard parsed.values.get("title") is Some(title) && !title.is_empty() else {
      return @github_cli.failure(message="project title is required")
    }
    input["title"] = Json::string(title)
  }
  if sub == "edit" {
    for
      (option, field) in [
        ("title", "title"),
        ("description", "shortDescription"),
        ("readme", "readme"),
      ] {
      if parsed.values.get(option) is Some(value) {
        input[field] = Json::string(value)
      }
    }
    if parsed.values.get("visibility") is Some(value) {
      guard value is ("PUBLIC" | "PRIVATE") else {
        return @github_cli.failure(
          message="project visibility must be PUBLIC or PRIVATE",
        )
      }
      input["public"] = Json::boolean(value == "PUBLIC")
    }
    guard !input.is_empty() else {
      return @github_cli.failure(message="provide a project field to edit")
    }
  }
  let limit = if sub == "list" {
    let value = @string.parse_int(parsed.values.get("limit").unwrap_or("30")) catch {
      _ => return @github_cli.failure(message="invalid project limit")
    }
    guard value > 0 && value <= 10000 else {
      return @github_cli.failure(
        message="project limit must be between 1 and 10000",
      )
    }
    value
  } else {
    1
  }
  let owner = parsed.values.get("owner").unwrap_or("@me")
  let owner_path = if owner is ("@me" | "user") {
    "/user"
  } else {
    let owner = match business_segment(owner) {
      Ok(value) => value
      Err(error) => return error
    }
    "/users/" + owner
  }
  let owner_info = match account_request(client, "GET", owner_path) {
    Ok(value) => value
    Err(error) => return error
  }
  let owner_id = match account_string(owner_info, "node_id") {
    Some(value) => value
    None =>
      return @github_cli.failure(
        message="project owner response has no node ID",
      )
  }
  let owner_type = account_string(owner_info, "type").unwrap_or("User")
  guard owner_type is ("User" | "Organization") else {
    return @github_cli.failure(message="unsupported project owner type")
  }
  let selection = "id number title shortDescription readme url closed public"
  let variables : Map[String, Json] = Map([])
  variables["owner"] = Json::string(owner_id)
  let mut value : Json = Json::null()
  if sub == "list" {
    let projects : Array[Json] = []
    let seen : Map[String, Bool] = Map([])
    let mut cursor : Json = Json::null()
    while projects.length() < limit {
      let remaining = limit - projects.length()
      variables["first"] = Json::number(
        (if remaining > 100 { 100 } else { remaining }).to_double(),
      )
      variables["after"] = cursor
      let query = "query AccountProjects($owner: ID!, $first: Int!, $after: String) { node(id: $owner) { ... on " +
        owner_type +
        " { projectsV2(first: $first, after: $after) { nodes { " +
        selection +
        " } pageInfo { hasNextPage endCursor } } } } }"
      let data = match account_graphql(client, query, variables) {
        Ok(value) => value
        Err(error) => return error
      }
      guard graphql_object_path(data, ["node", "projectsV2"])
        is Some(connection) &&
        graphql_object_field(connection, "nodes") is Some(Array(nodes)) else {
        return @github_cli.failure(message="project list response is invalid")
      }
      for project in nodes {
        if projects.length() < limit {
          projects.push(project)
        }
      }
      if graphql_object_path(connection, ["pageInfo", "hasNextPage"]) !=
        Some(Json::boolean(true)) {
        break
      }
      guard graphql_object_path(connection, ["pageInfo", "endCursor"])
        is Some(String(next)) &&
        !next.is_empty() &&
        !seen.contains(next) else {
        return @github_cli.failure(
          message="project pagination cursor is invalid",
        )
      }
      seen[next] = true
      cursor = Json::string(next)
    }
    value = {
      "projects": Json::array(projects),
      "totalCount": Json::number(projects.length().to_double()),
    }
  } else if sub == "create" {
    input["ownerId"] = Json::string(owner_id)
    let data = match
      account_graphql(
        client,
        "mutation AccountProjectCreate($input: CreateProjectV2Input!) { createProjectV2(input: $input) { projectV2 { " +
        selection +
        " } } }",
        { "input": Json::object(input) },
      ) {
      Ok(value) => value
      Err(error) => return error
    }
    value = match graphql_object_path(data, ["createProjectV2", "projectV2"]) {
      Some(Object(_) as project) => project
      _ =>
        return @github_cli.failure(
          message="project creation response is invalid",
        )
    }
  } else {
    variables["number"] = Json::number(number.to_double())
    let query = "query AccountProject($owner: ID!, $number: Int!) { node(id: $owner) { ... on " +
      owner_type +
      " { projectV2(number: $number) { " +
      selection +
      " } } } }"
    let data = match account_graphql(client, query, variables) {
      Ok(value) => value
      Err(error) => return error
    }
    let project = match graphql_object_path(data, ["node", "projectV2"]) {
      Some(Object(_) as project) => project
      _ => return @github_cli.failure(message="project not found")
    }
    let id = match account_string(project, "id") {
      Some(id) => id
      None => return @github_cli.failure(message="project response has no ID")
    }
    if sub == "view" {
      value = project
    } else {
      input["projectId"] = Json::string(id)
      let (query, result_path) = if sub == "delete" {
        (
          "mutation AccountProjectDelete($input: DeleteProjectV2Input!) { deleteProjectV2(input: $input) { deletedProjectV2Id } }",
          ["deleteProjectV2", "deletedProjectV2Id"],
        )
      } else {
        if sub == "close" {
          input["closed"] = Json::boolean(!parsed_flag(parsed, "undo"))
        }
        (
          "mutation AccountProjectUpdate($input: UpdateProjectV2Input!) { updateProjectV2(input: $input) { projectV2 { " +
          selection +
          " } } }",
          ["updateProjectV2", "projectV2"],
        )
      }
      let data = match
        account_graphql(client, query, { "input": Json::object(input) }) {
        Ok(value) => value
        Err(error) => return error
      }
      let result = match graphql_object_path(data, result_path) {
        Some(value) if value != Json::null() => value
        _ =>
          return @github_cli.failure(
            message="project mutation response is invalid",
          )
      }
      if sub == "delete" {
        guard result == Json::string(id) else {
          return @github_cli.failure(
            message="deleted project ID does not match",
          )
        }
        value = project
      } else {
        guard result is Object(_) && account_string(result, "id") == Some(id) else {
          return @github_cli.failure(
            message="updated project response is invalid",
          )
        }
        value = result
      }
    }
  }
  if parsed.json_fields is Some(_) && sub == "list" {
    return account_render(
      parsed,
      graphql_object_field(value, "projects").unwrap_or(Json::array([])),
    )
  }
  if parsed.values.get("format") == Some("json") ||
    parsed.jq is Some(_) ||
    parsed.template is Some(_) ||
    parsed.json_fields is Some(_) {
    return account_render(parsed, value)
  }
  if sub == "list" {
    guard graphql_object_field(value, "projects") is Some(Array(projects)) else {
      return @github_cli.failure(message="invalid project result")
    }
    let lines : Array[String] = []
    for project in projects {
      lines.push(
        graphql_object_field(project, "number")
        .unwrap_or(Json::null())
        .stringify() +
        "\t" +
        account_string(project, "title").unwrap_or("") +
        "\t" +
        account_string(project, "url").unwrap_or(""),
      )
    }
    return @github_cli.success(
      stdout=if lines.is_empty() { "" } else { lines.join("\n") + "\n" },
    )
  }
  if sub is ("create" | "view") {
    return @github_cli.success(
      stdout=account_string(value, "url").unwrap_or("") + "\n",
    )
  }
  @github_cli.success(stdout="")
}
