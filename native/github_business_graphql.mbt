///|
/// Projects V2 and Discussions are GraphQL-only GitHub APIs.  Keep the
/// command layer's request shape small and explicit: the existing business
/// renderer still consumes a JSON value, while this adapter owns the
/// GraphQL envelope and the provider-specific node paths.
fn business_graphql_envelope(
  operation_name : String,
  query : String,
  variables : Map[String, Json],
) -> Bytes {
  let fields : Map[String, Json] = Map([])
  fields["query"] = Json::string(query)
  fields["operationName"] = Json::string(operation_name)
  fields["variables"] = Json::object(variables)
  @utf8.encode(Json::object(fields).stringify())
}

///|
fn business_graphql_request(
  parsed : ParsedBusiness,
  repository : @github_cli.RepositoryContext?,
) -> Result[BusinessRequest, @github_cli.Output] {
  let command = parsed.command
  let sub = parsed.subcommand
  let fields : Map[String, Json] = Map([])
  let mut operation_name = ""
  let mut query = ""
  if command == "project" {
    let owner = parsed.values.get("owner").unwrap_or("user")
    let first = match parsed.values.get("limit") {
      Some(value) => {
        let number = @string.parse_int(value) catch { _ => 30 }
        if number > 100 {
          "100"
        } else {
          value
        }
      }
      None => "30"
    }
    fields["login"] = Json::string(owner)
    fields["first"] = @github_cli.typed_field(first)
    if sub == "list" {
      fields["after"] = Json::null()
      operation_name = "ProjectList"
      query = (
        #|query ProjectList($login: String!, $first: Int!, $after: String) {
        #|  viewer {
        #|    projectsV2(first: $first, after: $after) {
        #|      nodes { id number title shortDescription url closed public }
        #|      pageInfo { hasNextPage endCursor }
        #|    }
        #|  }
        #|  user(login: $login) {
        #|    projectsV2(first: $first, after: $after) {
        #|      nodes { id number title shortDescription url closed public }
        #|      pageInfo { hasNextPage endCursor }
        #|    }
        #|  }
        #|  organization(login: $login) {
        #|    projectsV2(first: $first, after: $after) {
        #|      nodes { id number title shortDescription url closed public }
        #|      pageInfo { hasNextPage endCursor }
        #|    }
        #|  }
        #|}
      )
    } else if sub == "view" {
      guard parsed.positionals.get(0) is Some(number) else {
        return Err(@github_cli.failure(message="project number is required"))
      }
      fields["number"] = @github_cli.typed_field(number)
      fields.remove("first")
      operation_name = "ProjectView"
      query = (
        #|query ProjectView($login: String!, $number: Int!) {
        #|  viewer {
        #|    projectV2(number: $number) {
        #|      id number title shortDescription url closed public
        #|    }
        #|  }
        #|  user(login: $login) {
        #|    projectV2(number: $number) {
        #|      id number title shortDescription url closed public
        #|    }
        #|  }
        #|  organization(login: $login) {
        #|    projectV2(number: $number) {
        #|      id number title shortDescription url closed public
        #|    }
        #|  }
        #|}
      )
    } else {
      return Err(
        @github_cli.failure(message="unsupported project command: " + sub),
      )
    }
  } else {
    guard command == "discussion" else {
      return Err(
        @github_cli.failure(message="unsupported GraphQL business command"),
      )
    }
    guard repository is Some(repo) else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    fields["owner"] = Json::string(repo.owner())
    fields["name"] = Json::string(repo.name())
    let first = match parsed.values.get("limit") {
      Some(value) => {
        let number = @string.parse_int(value) catch { _ => 30 }
        if number > 100 {
          "100"
        } else {
          value
        }
      }
      None => "30"
    }
    fields["first"] = @github_cli.typed_field(first)
    if sub == "list" {
      fields["after"] = Json::null()
      operation_name = "DiscussionList"
      query = (
        #|query DiscussionList($owner: String!, $name: String!, $first: Int!, $after: String) {
        #|  repository(owner: $owner, name: $name) {
        #|    discussions(first: $first, after: $after) {
        #|      nodes {
        #|        id number title body url createdAt updatedAt
        #|        author { login }
        #|        category { name }
        #|        isAnswered locked
        #|      }
        #|      pageInfo { hasNextPage endCursor }
        #|    }
        #|  }
        #|}
      )
    } else if sub == "view" {
      guard parsed.positionals.get(0) is Some(number) else {
        return Err(@github_cli.failure(message="discussion number is required"))
      }
      fields["number"] = @github_cli.typed_field(number)
      fields.remove("first")
      operation_name = "DiscussionView"
      query = (
        #|query DiscussionView($owner: String!, $name: String!, $number: Int!) {
        #|  repository(owner: $owner, name: $name) {
        #|    discussion(number: $number) {
        #|      id number title body url createdAt updatedAt
        #|      author { login }
        #|      category { name }
        #|      isAnswered locked
        #|    }
        #|  }
        #|}
      )
    } else {
      return Err(
        @github_cli.failure(message="unsupported discussion command: " + sub),
      )
    }
  }
  Ok({
    verb: "POST",
    path: "/graphql",
    query: [],
    headers: [("Content-Type", "application/json")],
    body: Some(business_graphql_envelope(operation_name, query, fields)),
    jq: parsed.jq,
    template: parsed.template,
    json_fields: parsed.json_fields,
    include_headers: parsed_flag(parsed, "include"),
    silent: parsed_flag(parsed, "silent"),
    verbose: parsed_flag(parsed, "verbose"),
  })
}

///|
fn graphql_object_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn graphql_object_path(value : Json, names : Array[String]) -> Json? {
  let mut current : Json? = Some(value)
  for name in names {
    current = match current {
      Some(item) => graphql_object_field(item, name)
      None => None
    }
  }
  current
}

///|
fn business_graphql_data(
  parsed : ParsedBusiness,
  body : Bytes,
) -> Result[Bytes, @github_cli.Output] {
  let envelope : Json = @json.parse(@utf8.decode(body)) catch {
    _ =>
      return Err(
        @github_cli.failure(message="GraphQL response is not valid JSON"),
      )
  }
  let data = match envelope {
    Object(fields) => {
      match fields.get("errors") {
        Some(Array(errors)) if errors.length() > 0 => {
          // GitHub returns a useful, provider-authored message for GraphQL
          // validation and permission failures. Preserve the first message
          // so the CLI's stderr remains actionable while keeping the raw
          // response out of the user-facing error path.
          let message = match errors.get(0) {
            Some(Object(error)) =>
              match error.get("message") {
                Some(String(value)) if !value.is_empty() => value
                _ => "GraphQL error"
              }
            _ => "GraphQL error"
          }
          return Err(@github_cli.failure(message~))
        }
        _ => ()
      }
      match fields.get("data") {
        Some(value) => value
        None =>
          return Err(
            @github_cli.failure(message="GraphQL response has no data envelope"),
          )
      }
    }
    _ =>
      return Err(
        @github_cli.failure(message="GraphQL response has no data envelope"),
      )
  }
  let normalized = match (parsed.command, parsed.subcommand) {
    ("project", "list") => {
      let owner_is_viewer = parsed.values.get("owner") is None ||
        parsed.values.get("owner") is Some("user")
      let viewer_nodes = if owner_is_viewer {
        graphql_object_path(data, ["viewer", "projectsV2", "nodes"])
      } else {
        None
      }
      let user_nodes = graphql_object_path(data, ["user", "projectsV2", "nodes"])
      let organization_nodes = graphql_object_path(data, [
        "organization", "projectsV2", "nodes",
      ])
      let nodes = match viewer_nodes {
        Some(value) => Some(value)
        None =>
          match user_nodes {
            Some(value) => Some(value)
            None => organization_nodes
          }
      }
      match nodes {
        Some(Array(nodes)) => Json::array(nodes)
        _ => Json::array([])
      }
    }
    ("project", "view") => {
      let owner_is_viewer = parsed.values.get("owner") is None ||
        parsed.values.get("owner") is Some("user")
      let viewer_project = if owner_is_viewer {
        graphql_object_path(data, ["viewer", "projectV2"])
      } else {
        None
      }
      let project = match viewer_project {
        Some(value) => Some(value)
        None =>
          match graphql_object_path(data, ["user", "projectV2"]) {
            Some(value) => Some(value)
            None => graphql_object_path(data, ["organization", "projectV2"])
          }
      }
      match project {
        Some(value) => value
        None => Json::null()
      }
    }
    ("discussion", "list") =>
      match graphql_object_path(data, ["repository", "discussions", "nodes"]) {
        Some(Array(nodes)) => Json::array(nodes)
        _ => Json::array([])
      }
    ("discussion", "view") =>
      graphql_object_path(data, ["repository", "discussion"]).unwrap_or(
        Json::null(),
      )
    _ => data
  }
  Ok(@utf8.encode(normalized.stringify()))
}

///|
/// `gh issue delete` is a GraphQL mutation.  GitHub does not expose a REST
/// delete endpoint, so resolve the issue node id first and then send the
/// provider mutation.  Both requests stay behind the same injected client
/// and retain the normal trace/error boundary.
async fn execute_issue_delete(
  parsed : ParsedBusiness,
  repository : @github_cli.RepositoryContext?,
  client : @github.Client,
) -> @github_cli.Output {
  guard parsed_flag(parsed, "yes") else {
    return @github_cli.failure(message="issue deletion requires --yes")
  }
  let repo = match parsed.repository {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(value) => value
        Err(_) =>
          return @github_cli.failure(
            message="expected the [HOST/]OWNER/REPO format",
          )
      }
    None =>
      match repository {
        Some(value) => value
        None => return @github_cli.failure(message="a repository is required")
      }
  }
  guard parsed.positionals.get(0) is Some(number_text) else {
    return @github_cli.failure(message="issue number is required")
  }
  let number = @string.parse_int(number_text) catch {
    _ => return @github_cli.failure(message="issue number must be an integer")
  }
  let lookup_variables : Map[String, Json] = Map([])
  lookup_variables["owner"] = Json::string(repo.owner())
  lookup_variables["name"] = Json::string(repo.name())
  lookup_variables["number"] = @github_cli.typed_field(number.to_string())
  let lookup_query =
    #|query IssueDeleteLookup($owner: String!, $name: String!, $number: Int!) {
    #|  repository(owner: $owner, name: $name) {
    #|    issue(number: $number) { id }
    #|  }
    #|}
  let lookup_request = @github.Request::new(
    verb="POST",
    path="/graphql",
    headers=[("Content-Type", "application/json")],
    body=business_graphql_envelope(
      "IssueDeleteLookup", lookup_query, lookup_variables,
    ),
  )
  let lookup = match
    client.graphql_raw(
      lookup_request,
      operation_id="business",
      operation_name="issue-delete-lookup",
    ) {
    Ok(value) => value
    Err(error) => return @github_cli.failure(message=error.code())
  }
  guard lookup.status() >= 200 && lookup.status() < 300 else {
    return @github_cli.failure(message="issue delete lookup failed")
  }
  let lookup_json : Json = @json.parse(@utf8.decode(lookup.body())) catch {
    _ =>
      return @github_cli.failure(message="GraphQL response is not valid JSON")
  }
  match lookup_json {
    Object(fields) =>
      match fields.get("errors") {
        Some(Array(errors)) if errors.length() > 0 => {
          let message = match errors.get(0) {
            Some(Object(error)) =>
              match error.get("message") {
                Some(String(value)) if !value.is_empty() => value
                _ => "GraphQL error"
              }
            _ => "GraphQL error"
          }
          return @github_cli.failure(message~)
        }
        _ => ()
      }
    _ =>
      return @github_cli.failure(
        message="GraphQL response has no data envelope",
      )
  }
  let issue_id = match
    graphql_object_path(lookup_json, ["data", "repository", "issue", "id"]) {
    Some(String(value)) if !value.is_empty() => value
    _ => return @github_cli.failure(message="issue was not found")
  }
  let mutation_variables : Map[String, Json] = Map([])
  mutation_variables["issueId"] = Json::string(issue_id)
  let mutation_query =
    #|mutation IssueDelete($issueId: ID!) {
    #|  deleteIssue(input: { issueId: $issueId }) {
    #|    clientMutationId
    #|  }
    #|}
  let mutation_request = @github.Request::new(
    verb="POST",
    path="/graphql",
    headers=[("Content-Type", "application/json")],
    body=business_graphql_envelope(
      "IssueDelete", mutation_query, mutation_variables,
    ),
  )
  let mutation = match
    client.graphql_raw(
      mutation_request,
      operation_id="business",
      operation_name="issue-delete",
    ) {
    Ok(value) => value
    Err(error) => return @github_cli.failure(message=error.code())
  }
  guard mutation.status() >= 200 && mutation.status() < 300 else {
    return @github_cli.failure(message="issue delete failed")
  }
  let mutation_json : Json = @json.parse(@utf8.decode(mutation.body())) catch {
    _ =>
      return @github_cli.failure(message="GraphQL response is not valid JSON")
  }
  match mutation_json {
    Object(fields) =>
      match fields.get("errors") {
        Some(Array(errors)) if errors.length() > 0 => {
          let message = match errors.get(0) {
            Some(Object(error)) =>
              match error.get("message") {
                Some(String(value)) if !value.is_empty() => value
                _ => "GraphQL error"
              }
            _ => "GraphQL error"
          }
          @github_cli.failure(message~)
        }
        _ => @github_cli.Output::new()
      }
    _ => @github_cli.failure(message="GraphQL response has no data envelope")
  }
}

///|
/// Build the next request for a business GraphQL connection.  The initial
/// request carries `after: null`; subsequent requests replace that variable
/// while preserving the operation, query, and all other variables.
fn business_graphql_cursor_request(
  request : BusinessRequest,
  cursor : String,
) -> Result[@github.Request, @github_cli.Output] {
  let body = match request.body {
    Some(value) => value
    None =>
      return Err(
        @github_cli.failure(message="GraphQL pagination requires a JSON body"),
      )
  }
  let payload : Json = @json.parse(@utf8.decode(body)) catch {
    _ =>
      return Err(
        @github_cli.failure(message="GraphQL pagination requires a JSON body"),
      )
  }
  guard payload is Object(top) else {
    return Err(@github_cli.failure(message="GraphQL payload must be an object"))
  }
  let variables = match top.get("variables") {
    Some(Object(values)) => values
    None | Some(Null) => Map([])
    _ => return Err(@github_cli.failure(message="invalid GraphQL variables"))
  }
  variables["after"] = Json::string(cursor)
  top["variables"] = Json::object(variables)
  Ok(
    @github.Request::new(
      verb=request.verb,
      path=request.path,
      query=request.query,
      headers=request.headers,
      body=@utf8.encode(Json::object(top).stringify()),
    ),
  )
}

///|
/// Return the pageInfo belonging to the connection selected by the business
/// normalizer.  ProjectList asks for three owner fallbacks in one document,
/// so the generic API cursor scanner would see three pageInfo objects and
/// could not know which cursor to advance.
fn business_graphql_cursor(
  parsed : ParsedBusiness,
  envelope : Json,
) -> Result[String?, @github_cli.Output] {
  let data = match graphql_object_path(envelope, ["data"]) {
    Some(value) => value
    None => return Ok(None)
  }
  let owner_is_viewer = parsed.values.get("owner") is None ||
    parsed.values.get("owner") is Some("user")
  let connection : Json? = match parsed.command {
    "project" => {
      let candidates = if owner_is_viewer {
        [
          ["viewer", "projectsV2"],
          ["user", "projectsV2"],
          ["organization", "projectsV2"],
        ]
      } else {
        [["user", "projectsV2"], ["organization", "projectsV2"]]
      }
      let mut selected : Json? = None
      for path in candidates {
        match graphql_object_path(data, path) {
          Some(Object(_)) => {
            selected = graphql_object_path(data, path)
            break
          }
          _ => ()
        }
      }
      selected
    }
    "discussion" => graphql_object_path(data, ["repository", "discussions"])
    _ => None
  }
  let page_info = match connection {
    Some(value) => graphql_object_field(value, "pageInfo")
    None => None
  }
  match page_info {
    None => Ok(None)
    Some(value) =>
      @github.graphql_next_cursor(value).map_err(_ => {
        @github_cli.failure(message="invalid GraphQL pageInfo")
      })
  }
}

///|
/// Follow the cursor-backed connection used by project/discussion list.  The
/// first response is retained for status/header output; the normalized node
/// array is returned separately so the regular JSON field projection remains
/// unchanged.  A cursor is recorded before each request so a server that
/// repeats an end cursor cannot cause an unbounded loop.
async fn execute_business_graphql_collection(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  client : @github.Client,
  target : Int32,
) -> Result[(@github.RawResponse, Bytes?), @github_cli.Output] {
  let first_request = @github.Request::new(
    verb=request.verb,
    path=request.path,
    query=request.query,
    headers=request.headers,
    body?=request.body,
  )
  let first = match
    client.graphql_raw(
      first_request,
      operation_id="business",
      operation_name=parsed.command,
    ) {
    Ok(value) => value
    Err(error) =>
      match error.response() {
        Some(value) => value
        None => return Err(@github_cli.failure(message=error.code()))
      }
  }
  if first.status() < 200 || first.status() >= 300 {
    return Ok((first, None))
  }
  let first_envelope : Json = @json.parse(@utf8.decode(first.body())) catch {
    _ =>
      return Err(
        @github_cli.failure(message="GraphQL response is not valid JSON"),
      )
  }
  let first_body = match business_graphql_data(parsed, first.body()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let merged = match @json.parse(@utf8.decode(first_body)) {
    Array(items) => items.copy()
    _ =>
      return Err(
        @github_cli.failure(
          message="GraphQL collection response is not an array",
        ),
      )
  }
  let mut cursor = match business_graphql_cursor(parsed, first_envelope) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let seen : Map[String, Bool] = Map([])
  let mut pages = 1
  while merged.length() < target && cursor is Some(_) {
    guard pages < 10000 else {
      return Err(@github_cli.failure(message="pagination exceeded page limit"))
    }
    let next_cursor = cursor.unwrap()
    guard !seen.contains(next_cursor) else {
      return Err(
        @github_cli.failure(message="GraphQL pagination cursor repeated"),
      )
    }
    seen[next_cursor] = true
    let next_request = match
      business_graphql_cursor_request(request, next_cursor) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let response = match
      client.graphql_raw(
        next_request,
        operation_id="business-pagination",
        operation_name=parsed.command,
      ) {
      Ok(value) => value
      Err(error) =>
        match error.response() {
          Some(value) => value
          None => return Err(@github_cli.failure(message=error.code()))
        }
    }
    if response.status() < 200 || response.status() >= 300 {
      return Ok((response, None))
    }
    let envelope : Json = @json.parse(@utf8.decode(response.body())) catch {
      _ =>
        return Err(
          @github_cli.failure(message="GraphQL response is not valid JSON"),
        )
    }
    let page_body = match business_graphql_data(parsed, response.body()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match @json.parse(@utf8.decode(page_body)) {
      Array(items) =>
        for item in items {
          if merged.length() >= target {
            break
          }
          merged.push(item)
        }
      _ =>
        return Err(
          @github_cli.failure(
            message="GraphQL collection response is not an array",
          ),
        )
    }
    cursor = match business_graphql_cursor(parsed, envelope) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    pages += 1
  }
  Ok((first, Some(@utf8.encode(Json::array(merged).stringify()))))
}
