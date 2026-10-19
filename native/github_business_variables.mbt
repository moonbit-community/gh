///|
/// Actions variables have different REST methods for creation and update.
/// Match gh's create-first flow: POST the collection and retry with PATCH on
/// the named item only when GitHub reports a conflict (the variable already
/// exists). Keep all other HTTP failures visible to the caller.
async fn execute_variable_set(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  client : @github.Client,
) -> @github_cli.Output {
  let name = match parsed.positionals.get(0) {
    Some(value) => value
    None => return @github_cli.failure(message="name is required")
  }
  let name_segment = match business_segment(name) {
    Ok(value) => value
    Err(error) => return error
  }
  let value = match parsed.values.get("value") {
    Some(value) => value
    None =>
      match parsed.values.get("body") {
        Some(value) => value
        None => return @github_cli.failure(message="variable value is required")
      }
  }
  let create_body : Map[String, Json] = Map([])
  create_body["name"] = Json::string(name)
  create_body["value"] = Json::string(value)
  let visibility = if parsed.values.get("org") is Some(_) {
    let visibility = parsed.values.get("visibility").unwrap_or("private")
    guard visibility is ("private" | "all") else {
      return @github_cli.failure(
        message="visibility must be all or private; selected repository access is not supported yet",
      )
    }
    Some(visibility)
  } else {
    guard parsed.values.get("visibility") is None else {
      return @github_cli.failure(message="--visibility requires --org")
    }
    None
  }
  if visibility is Some(visibility) {
    create_body["visibility"] = Json::string(visibility)
  }
  let create_request = @github.Request::new(
    verb="POST",
    path=request.path,
    headers=request.headers,
    body=@utf8.encode(Json::object(create_body).stringify()),
  )
  let create_response = match
    client.request(
      create_request,
      operation_id="variable-create",
      operation_name="variable.create",
    ) {
    Ok(response) => response
    Err(error) =>
      match error.response() {
        Some(response) => response
        None => return @github_cli.failure(message=error.code())
      }
  }
  if create_response.status() != 409 {
    if create_response.status() >= 200 && create_response.status() < 300 {
      // Like gh's non-interactive set, never echo a successful response body: it
      // may contain the variable value. The command reports only failures.
      return @github_cli.Output::new()
    }
    return @github_cli.render_response(
      create_response.status(),
      create_response.headers(),
      create_response.body(),
      jq?=request.jq,
      template?=request.template,
      include_headers=request.include_headers,
      silent=request.silent,
      verbose=request.verbose,
    )
  }
  let update_body : Map[String, Json] = Map([])
  update_body["value"] = Json::string(value)
  if visibility is Some(visibility) {
    update_body["visibility"] = Json::string(visibility)
  }
  let item_path = request.path + "/" + name_segment
  let write_request = @github.Request::new(
    verb="PATCH",
    path=item_path,
    headers=request.headers,
    body=@utf8.encode(Json::object(update_body).stringify()),
  )
  let response = match
    client.request(
      write_request,
      operation_id="variable-update",
      operation_name="variable.update",
    ) {
    Ok(response) => response
    Err(error) =>
      match error.response() {
        Some(response) => response
        None => return @github_cli.failure(message=error.code())
      }
  }
  if response.status() >= 200 && response.status() < 300 {
    return @github_cli.Output::new()
  }
  @github_cli.render_response(
    response.status(),
    response.headers(),
    response.body(),
    jq?=request.jq,
    template?=request.template,
    include_headers=request.include_headers,
    silent=request.silent,
    verbose=request.verbose,
  )
}
