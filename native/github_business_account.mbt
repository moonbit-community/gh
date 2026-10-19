///|
fn business_account_command(command : String) -> Bool {
  command is ("gist" | "ssh-key" | "gpg-key" | "project" | "status")
}

///|
fn business_account_short_option(
  command : String,
  sub : String,
  arg : String,
) -> (String, Bool)? {
  match (command, sub, arg) {
    ("gist", _, "-d") => Some(("desc", true))
    ("gist", _, "-f") => Some(("filename", true))
    ("gist", "edit", "-a") => Some(("add", true))
    ("gist", "edit", "-r") => Some(("remove", true))
    ("gist", "create" | "new", "-p") => Some(("public", false))
    ("ssh-key" | "gpg-key", "add", "-t") => Some(("title", true))
    ("ssh-key" | "gpg-key" | "gist", "delete", "-y") => Some(("yes", false))
    ("project", "edit", "-d") => Some(("description", true))
    ("status", _, "-e") => Some(("exclude", true))
    ("status", _, "-o") => Some(("org", true))
    _ => None
  }
}

///|
fn business_account_option(
  values : Map[String, String],
  key : String,
  value : String,
) -> Unit {
  if key == "exclude" && values.get(key) is Some(previous) {
    values[key] = previous + "," + value
  } else {
    values[key] = value
  }
}

///|
async fn execute_account_business(
  parsed : ParsedBusiness,
  client : @github.Client,
  base_url : String,
) -> @github_cli.Output? {
  match parsed.command {
    "ssh-key" | "gpg-key" => Some(execute_account_key(parsed, client))
    "gist" => Some(execute_account_gist(parsed, client))
    "project" => Some(execute_account_project(parsed, client))
    "status" => Some(execute_account_status(parsed, client, base_url))
    _ => None
  }
}

///|
async fn account_request(
  client : @github.Client,
  verb : String,
  path : String,
  body? : Json,
  query~ : Array[(String, String)] = [],
) -> Result[Json, @github_cli.Output] {
  let request = @github.Request::new(
    verb~,
    path~,
    query~,
    body?=body.map(value => @utf8.encode(value.stringify())),
  )
  let result = if path == "/graphql" {
    client.graphql_raw(
      request,
      operation_id="account",
      operation_name="account.graphql",
    )
  } else {
    client.request(
      request,
      operation_id="account",
      operation_name="account.request",
    )
  }
  let response = match result {
    Ok(response) => response
    Err(error) =>
      match error.response() {
        Some(response) => response
        None => return Err(@github_cli.failure(message=error.code()))
      }
  }
  if response.status() < 200 || response.status() >= 300 {
    return Err(
      @github_cli.render_response(
        response.status(),
        response.headers(),
        response.body(),
      ),
    )
  }
  if response.body().is_empty() {
    return Ok(Json::null())
  }
  let value = @json.parse(@utf8.decode(response.body())) catch {
    _ =>
      return Err(
        @github_cli.failure(message="account response is not valid JSON"),
      )
  }
  if path == "/graphql" {
    if graphql_object_field(value, "errors") is Some(Array(errors)) &&
      !errors.is_empty() {
      let message = match graphql_object_field(errors[0], "message") {
        Some(String(message)) => message
        _ => "GraphQL request failed"
      }
      return Err(@github_cli.failure(message~))
    }
    guard graphql_object_field(value, "data") is Some(data) && data is Object(_) else {
      return Err(
        @github_cli.failure(message="GraphQL response has no data object"),
      )
    }
    return Ok(data)
  }
  Ok(value)
}

///|
fn account_render(parsed : ParsedBusiness, value : Json) -> @github_cli.Output {
  let bytes = @utf8.encode(value.stringify())
  let bytes = match parsed.json_fields {
    Some(fields) =>
      match business_project_response(bytes, fields, repository_view=false) {
        Ok(value) => value
        Err(_) =>
          return @github_cli.failure(message="invalid account JSON output")
      }
    None => bytes
  }
  @github_cli.render_response(
    200,
    [],
    bytes,
    jq?=parsed.jq,
    template?=parsed.template,
    silent=parsed_flag(parsed, "silent"),
  )
}

///|
fn account_string(value : Json, field : String) -> String? {
  match graphql_object_field(value, field) {
    Some(String(value)) if !value.is_empty() => Some(value)
    _ => None
  }
}

///|
async fn account_input(path : String) -> Result[String, @github_cli.Output] {
  if path == "-" {
    let text = @stdio.stdin.read_all().text() catch {
        _ =>
          return Err(@github_cli.failure(message="cannot read standard input"))
      }
    return Ok(text)
  }
  guard valid_local_git_value(path) else {
    return Err(@github_cli.failure(message="invalid input path"))
  }
  let text = @fs.read_file(path).text() catch {
    _ => return Err(@github_cli.failure(message="cannot read input file"))
  }
  Ok(text)
}

///|
async fn execute_account_key(
  parsed : ParsedBusiness,
  client : @github.Client,
) -> @github_cli.Output {
  let gpg = parsed.command == "gpg-key"
  let kind = parsed.values.get("type").unwrap_or("authentication")
  guard kind is ("authentication" | "signing") &&
    (!gpg || parsed.values.get("type") is None) else {
    return @github_cli.failure(
      message="SSH key type must be authentication or signing",
    )
  }
  let resource = if gpg {
    "gpg_keys"
  } else if kind == "signing" {
    "ssh_signing_keys"
  } else {
    "keys"
  }
  let path = "/user/" + resource
  match parsed.subcommand {
    "add" => {
      guard parsed.positionals.length() <= 1 else {
        return @github_cli.failure(message="only one key file is allowed")
      }
      let field = if gpg { "armored_public_key" } else { "key" }
      guard !(parsed.values.get(field) is Some(_) &&
        !parsed.positionals.is_empty()) else {
        return @github_cli.failure(message="key input was specified twice")
      }
      let key = match parsed.values.get(field) {
        Some(value) => value
        None =>
          match account_input(parsed.positionals.get(0).unwrap_or("-")) {
            Ok(value) => value
            Err(error) => return error
          }
      }
      guard !key.trim().is_empty() else {
        return @github_cli.failure(message="public key input is empty")
      }
      guard !key.contains("PRIVATE KEY") else {
        return @github_cli.failure(
          message="input must contain only a public key",
        )
      }
      guard (if gpg {
        key.contains("-----BEGIN PGP PUBLIC KEY BLOCK-----")
      } else {
        key.has_prefix("ssh-") ||
        key.has_prefix("ecdsa-") ||
        key.has_prefix("sk-")
      }) else {
        return @github_cli.failure(
          message="input is not a recognized public key",
        )
      }
      let body : Map[String, Json] = Map([])
      body[field] = Json::string(key)
      if parsed.values.get("title") is Some(title) {
        body[if gpg { "name" } else { "title" }] = Json::string(title)
      }
      match account_request(client, "POST", path, body=Json::object(body)) {
        Ok(_) => @github_cli.success(stdout="")
        Err(error) => error
      }
    }
    "list" | "ls" => {
      let kinds = if gpg { ["gpg_keys"] } else { ["keys", "ssh_signing_keys"] }
      let all : Array[Json] = []
      for kind in kinds {
        let response = match account_key_list(client, kind) {
          Ok(items) => items
          Err(error) => return error
        }
        for item in response {
          if item is Object(fields) {
            if !gpg {
              fields["type"] = Json::string(
                if kind == "keys" {
                  "authentication"
                } else {
                  "signing"
                },
              )
            }
            all.push(Json::object(fields))
          } else {
            return @github_cli.failure(message="invalid key response")
          }
        }
      }
      if parsed.jq is Some(_) ||
        parsed.template is Some(_) ||
        parsed.json_fields is Some(_) {
        return account_render(parsed, Json::array(all))
      }
      let lines : Array[String] = []
      for item in all {
        let id = graphql_object_field(item, "id")
          .unwrap_or(Json::null())
          .stringify()
        let title = account_string(item, if gpg { "name" } else { "title" }).unwrap_or(
          "",
        )
        lines.push(
          id +
          "\t" +
          title +
          (if gpg {
            ""
          } else {
            "\t" + account_string(item, "type").unwrap_or("")
          }),
        )
      }
      @github_cli.success(
        stdout=if lines.is_empty() { "" } else { lines.join("\n") + "\n" },
      )
    }
    "delete" => {
      guard parsed_flag(parsed, "yes") else {
        return @github_cli.failure(message="pass --yes to confirm key deletion")
      }
      guard parsed.positionals.length() == 1 else {
        return @github_cli.failure(message="key ID is required")
      }
      let id = @string.parse_int64(parsed.positionals[0]) catch {
        _ => return @github_cli.failure(message="invalid key ID")
      }
      guard id > 0L else {
        return @github_cli.failure(message="invalid key ID")
      }
      let mut target = path
      if !gpg {
        let mut found : String? = None
        for kind in ["keys", "ssh_signing_keys"] {
          let keys = match account_key_list(client, kind) {
            Ok(items) => items
            Err(error) => return error
          }
          for key in keys {
            if graphql_object_field(key, "id") is Some(value) &&
              value.stringify() == id.to_string() {
              guard found is None else {
                return @github_cli.failure(message="ambiguous SSH key ID")
              }
              found = Some("/user/" + kind)
            }
          }
        }
        target = match found {
          Some(value) => value
          None => return @github_cli.failure(message="SSH key not found")
        }
      }
      match account_request(client, "DELETE", target + "/" + id.to_string()) {
        Ok(_) => @github_cli.success(stdout="")
        Err(error) => error
      }
    }
    _ => @github_cli.failure(message="unsupported key command")
  }
}

///|
async fn account_key_list(
  client : @github.Client,
  resource : String,
) -> Result[Array[Json], @github_cli.Output] {
  let all : Array[Json] = []
  for page in 1..<=100 {
    let items = match
      account_request(client, "GET", "/user/" + resource, query=[
        ("per_page", "100"),
        ("page", page.to_string()),
      ]) {
      Ok(Array(items)) => items
      Ok(_) =>
        return Err(@github_cli.failure(message="key response is not an array"))
      Err(error) => return Err(error)
    }
    all.append(items)
    if items.length() < 100 {
      return Ok(all)
    }
  }
  Err(@github_cli.failure(message="key pagination exceeded its limit"))
}
