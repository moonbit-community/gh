///|
fn account_gist_id(value : String) -> Result[String, @github_cli.Output] {
  let candidate = if value.has_prefix("https://gist.github.com/") {
    value.split("/").last().unwrap_or("").to_owned()
  } else {
    value
  }
  guard !candidate.is_empty() &&
    candidate.iter().all(ch => ch is ('0'..<='9' | 'a'..<='f' | 'A'..<='F')) else {
    return Err(@github_cli.failure(message="invalid gist ID or URL"))
  }
  Ok(candidate)
}

///|
async fn execute_account_gist(
  parsed : ParsedBusiness,
  client : @github.Client,
) -> @github_cli.Output {
  let sub = parsed.subcommand
  for option in ["desc", "description", "filename", "add", "remove"] {
    if parsed_flag(parsed, option) {
      return @github_cli.failure(message="--" + option + " requires a value")
    }
  }
  if parsed_flag(parsed, "web") {
    return @github_cli.failure(
      message="gist browser interaction is not available",
    )
  }
  let mut path = "/gists"
  if !(sub is ("create" | "new" | "list" | "ls")) {
    guard parsed.positionals.get(0) is Some(value) else {
      return @github_cli.failure(message="gist ID is required")
    }
    let id = match account_gist_id(value) {
      Ok(value) => value
      Err(error) => return error
    }
    path += "/" + id
  }
  let body : Map[String, Json] = Map([])
  let description = match parsed.values.get("desc") {
    Some(value) => Some(value)
    None => parsed.values.get("description")
  }
  if description is Some(value) {
    body["description"] = Json::string(value)
  }
  let files : Map[String, Json] = Map([])
  let mut verb = "GET"
  match sub {
    "create" | "new" => {
      verb = "POST"
      body["public"] = Json::boolean(
        parsed_flag(parsed, "public") ||
        parsed.values.get("public") is Some("true"),
      )
      let sources = if parsed.positionals.is_empty() {
        ["-"]
      } else {
        parsed.positionals
      }
      for source in sources {
        let name = if source == "-" {
          parsed.values.get("filename").unwrap_or("gistfile1.txt")
        } else {
          local_file_basename(source)
        }
        guard business_asset_filename(name) && !files.contains(name) else {
          return @github_cli.failure(
            message="invalid or duplicate gist filename",
          )
        }
        let content = match account_input(source) {
          Ok(value) => value
          Err(error) => return error
        }
        files[name] = { "content": Json::string(content) }
      }
      body["files"] = Json::object(files)
    }
    "edit" => {
      verb = "PATCH"
      guard parsed.positionals.length() <= 2 else {
        return @github_cli.failure(
          message="only one replacement file is allowed",
        )
      }
      let source = parsed.positionals.get(1)
      let added = parsed.values.get("add")
      let removed = parsed.values.get("remove")
      let count = (if source is Some(_) { 1 } else { 0 }) +
        (if added is Some(_) { 1 } else { 0 }) +
        (if removed is Some(_) { 1 } else { 0 })
      guard count <= 1 else {
        return @github_cli.failure(
          message="choose one gist file replacement, addition, or removal",
        )
      }
      let selected_source = match source {
        Some(_) => source
        None => added
      }
      if selected_source is Some(source) {
        let name = if added is Some(_) {
          local_file_basename(source)
        } else {
          parsed.values.get("filename").unwrap_or(local_file_basename(source))
        }
        guard business_asset_filename(name) else {
          return @github_cli.failure(message="invalid gist filename")
        }
        let content = match account_input(source) {
          Ok(value) => value
          Err(error) => return error
        }
        files[name] = { "content": Json::string(content) }
      } else if removed is Some(name) {
        guard business_asset_filename(name) else {
          return @github_cli.failure(message="invalid gist filename")
        }
        files[name] = Json::null()
      }
      guard !files.is_empty() || description is Some(_) else {
        return @github_cli.failure(
          message="provide a replacement file, --add, --remove, or --desc; interactive editor is not available",
        )
      }
      if !files.is_empty() {
        body["files"] = Json::object(files)
      }
    }
    "rename" => {
      verb = "PATCH"
      guard parsed.positionals.length() == 3 else {
        return @github_cli.failure(
          message="gist ID, old filename, and new filename are required",
        )
      }
      let old = parsed.positionals[1]
      let renamed = parsed.positionals[2]
      guard business_asset_filename(old) && business_asset_filename(renamed) else {
        return @github_cli.failure(message="invalid gist filename")
      }
      files[old] = { "filename": Json::string(renamed) }
      body["files"] = Json::object(files)
    }
    "delete" => {
      guard parsed_flag(parsed, "yes") else {
        return @github_cli.failure(
          message="pass --yes to confirm gist deletion",
        )
      }
      verb = "DELETE"
    }
    "view" | "list" | "ls" => ()
    _ => return @github_cli.failure(message="unsupported gist command: " + sub)
  }
  let response = match
    account_request(
      client,
      verb,
      path,
      body?=if body.is_empty() { None } else { Some(Json::object(body)) },
      query=if sub is ("list" | "ls") {
        business_query(parsed, ["limit", "page"])
      } else {
        []
      },
    ) {
    Ok(value) => value
    Err(error) => return error
  }
  if sub is ("create" | "new") {
    guard account_string(response, "html_url") is Some(url) else {
      return @github_cli.failure(message="gist response has no URL")
    }
    return @github_cli.success(stdout=url + "\n")
  }
  if sub is ("edit" | "rename" | "delete") {
    return @github_cli.success(stdout="")
  }
  if parsed.jq is Some(_) ||
    parsed.template is Some(_) ||
    parsed.json_fields is Some(_) {
    return account_render(parsed, response)
  }
  if sub == "view" {
    if graphql_object_field(response, "truncated") == Some(Json::boolean(true)) {
      return @github_cli.failure(
        message="gist file list is truncated; clone the gist for full contents",
      )
    }
    guard graphql_object_field(response, "files") is Some(Object(files)) else {
      return @github_cli.failure(message="gist response has no files")
    }
    let selected = parsed.values.get("filename")
    let contents : Array[String] = []
    for name, file in files {
      if selected is None || selected == Some(name) {
        if graphql_object_field(file, "truncated") == Some(Json::boolean(true)) {
          return @github_cli.failure(
            message="gist file content is truncated; clone the gist for full contents",
          )
        }
        guard graphql_object_field(file, "content") is Some(String(content)) else {
          return @github_cli.failure(message="gist file content is unavailable")
        }
        contents.push(content)
      }
    }
    guard !contents.is_empty() else {
      return @github_cli.failure(message="gist file not found")
    }
    return @github_cli.success(stdout=contents.join("\n") + "\n")
  }
  guard response is Array(items) else {
    return @github_cli.failure(message="gist response is not an array")
  }
  let lines : Array[String] = []
  for item in items {
    lines.push(
      account_string(item, "id").unwrap_or("") +
      "\t" +
      account_string(item, "description").unwrap_or(""),
    )
  }
  @github_cli.success(
    stdout=if lines.is_empty() { "" } else { lines.join("\n") + "\n" },
  )
}
