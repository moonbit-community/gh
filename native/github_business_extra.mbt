///|
/// Additional v2.102.0 core endpoint mappings. Requests stay raw:
/// response decoding, JSON projection, tracing, and HTTP error handling remain
/// owned by `execute_github_business`.
fn extra_body(fields : Map[String, Json]) -> Bytes? {
  if fields.is_empty() {
    None
  } else {
    Some(@utf8.encode(Json::object(fields).stringify()))
  }
}

///|
fn extra_state_body(name : String, value : Bool) -> Bytes {
  let fields : Map[String, Json] = Map([])
  fields[name] = Json::boolean(value)
  @utf8.encode(Json::object(fields).stringify())
}

///|
fn extra_path_segment(value : String) -> Result[String, @github_cli.Output] {
  business_segment(value)
}

///|
/// Return a request for an additional command family. `None` delegates to
/// the primary request switch.
fn business_extra_request(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
  repo_path : String,
) -> Result[BusinessRequest?, @github_cli.Output] {
  let command = options.command()
  let sub = parsed.subcommand
  if command == "repo" {
    match sub {
      "archive" | "unarchive" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        let body = extra_state_body("archived", sub == "archive")
        return Ok(
          Some({
            verb: "PATCH",
            path: repo_path,
            query: [],
            headers: [],
            body: Some(body),
            jq: parsed.jq,
            template: parsed.template,
            json_fields: parsed.json_fields,
            include_headers: parsed_flag(parsed, "include"),
            silent: parsed_flag(parsed, "silent"),
            verbose: parsed_flag(parsed, "verbose"),
          }),
        )
      }
      "deploy-key" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        let action = parsed.positionals.get(0).unwrap_or("list")
        let key_path = repo_path + "/keys"
        if action == "list" {
          return Ok(
            Some({
              verb: "GET",
              path: key_path,
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        if action == "add" {
          let fields : Map[String, Json] = Map([])
          match parsed.values.get("title") {
            Some(value) => fields["title"] = Json::string(value)
            None => ()
          }
          match parsed.values.get("key") {
            Some(value) => fields["key"] = Json::string(value)
            None => ()
          }
          if parsed_flag(parsed, "read_only") {
            fields["read_only"] = Json::boolean(true)
          }
          return Ok(
            Some({
              verb: "POST",
              path: key_path,
              query: [],
              headers: [],
              body: extra_body(fields),
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        if action == "delete" {
          guard parsed.positionals.get(1) is Some(identifier) else {
            return Err(@github_cli.failure(message="key ID is required"))
          }
          let identifier = match extra_path_segment(identifier) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          return Ok(
            Some({
              verb: "DELETE",
              path: key_path + "/" + identifier,
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        return Err(
          @github_cli.failure(
            message="unsupported deploy-key command: " + action,
          ),
        )
      }
      "gitignore" => {
        let action = parsed.positionals.get(0).unwrap_or("list")
        if action == "list" {
          return Ok(
            Some({
              verb: "GET",
              path: "/gitignore/templates",
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        if action == "view" {
          guard parsed.positionals.get(1) is Some(name) else {
            return Err(@github_cli.failure(message="template name is required"))
          }
          let name = match extra_path_segment(name) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          return Ok(
            Some({
              verb: "GET",
              path: "/gitignore/templates/" + name,
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        return Err(
          @github_cli.failure(
            message="unsupported gitignore command: " + action,
          ),
        )
      }
      "license" => {
        let action = parsed.positionals.get(0).unwrap_or("list")
        if action == "list" {
          return Ok(
            Some({
              verb: "GET",
              path: "/licenses",
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        if action == "view" {
          guard parsed.positionals.get(1) is Some(name) else {
            return Err(@github_cli.failure(message="license key is required"))
          }
          let name = match extra_path_segment(name) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          return Ok(
            Some({
              verb: "GET",
              path: "/licenses/" + name,
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        return Err(
          @github_cli.failure(message="unsupported license command: " + action),
        )
      }
      "read-file" | "read-dir" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        let path = match parsed.positionals.get(0) {
          Some(value) =>
            match extra_path_segment(value) {
              Ok(segment) => repo_path + "/contents/" + segment
              Err(error) => return Err(error)
            }
          None => repo_path + "/contents"
        }
        let query = business_query(parsed, ["ref"])
        let headers : Array[(String, String)] = []
        if sub == "read-file" &&
          parsed.json_fields is None &&
          parsed.jq is None &&
          parsed.template is None {
          headers.push(("Accept", "application/vnd.github.raw"))
        }
        return Ok(
          Some({
            verb: "GET",
            path,
            query,
            headers,
            body: None,
            jq: parsed.jq,
            template: parsed.template,
            json_fields: parsed.json_fields,
            include_headers: parsed_flag(parsed, "include"),
            silent: parsed_flag(parsed, "silent"),
            verbose: parsed_flag(parsed, "verbose"),
          }),
        )
      }
      _ => ()
    }
  }
  if command == "issue" {
    match sub {
      "pin" | "unpin" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(@github_cli.failure(message="issue number is required"))
        }
        let number = match extra_path_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        return Ok(
          Some({
            verb: if sub == "pin" {
              "PUT"
            } else {
              "DELETE"
            },
            path: repo_path + "/issues/" + number + "/pin",
            query: [],
            headers: [],
            body: None,
            jq: parsed.jq,
            template: parsed.template,
            json_fields: parsed.json_fields,
            include_headers: parsed_flag(parsed, "include"),
            silent: parsed_flag(parsed, "silent"),
            verbose: parsed_flag(parsed, "verbose"),
          }),
        )
      }
      "develop" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(@github_cli.failure(message="issue number is required"))
        }
        let number = match extra_path_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let base = repo_path + "/issues/" + number + "/development/branches"
        if parsed_flag(parsed, "list") {
          return Ok(
            Some({
              verb: "GET",
              path: base,
              query: [],
              headers: [],
              body: None,
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        let fields : Map[String, Json] = Map([])
        match parsed.values.get("name") {
          Some(value) => fields["name"] = Json::string(value)
          None => ()
        }
        match parsed.values.get("base") {
          Some(value) => fields["base"] = Json::string(value)
          None => ()
        }
        return Ok(
          Some({
            verb: "POST",
            path: base,
            query: [],
            headers: [],
            body: extra_body(fields),
            jq: parsed.jq,
            template: parsed.template,
            json_fields: parsed.json_fields,
            include_headers: parsed_flag(parsed, "include"),
            silent: parsed_flag(parsed, "silent"),
            verbose: parsed_flag(parsed, "verbose"),
          }),
        )
      }
      _ => ()
    }
  }
  if command == "pr" {
    match sub {
      "update-branch" | "revert" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match extra_path_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if sub == "update-branch" {
          let fields : Map[String, Json] = Map([])
          if parsed_flag(parsed, "rebase") {
            fields["update_method"] = Json::string("rebase")
          }
          return Ok(
            Some({
              verb: "PUT",
              path: repo_path + "/pulls/" + number + "/update-branch",
              query: [],
              headers: [],
              body: extra_body(fields),
              jq: parsed.jq,
              template: parsed.template,
              json_fields: parsed.json_fields,
              include_headers: parsed_flag(parsed, "include"),
              silent: parsed_flag(parsed, "silent"),
              verbose: parsed_flag(parsed, "verbose"),
            }),
          )
        }
        let fields : Map[String, Json] = Map([])
        match parsed.values.get("title") {
          Some(value) => fields["title"] = Json::string(value)
          None => ()
        }
        match parsed.values.get("body") {
          Some(value) => fields["body"] = Json::string(value)
          None => ()
        }
        if parsed_flag(parsed, "draft") {
          fields["draft"] = Json::boolean(true)
        }
        return Ok(
          Some({
            verb: "POST",
            path: repo_path + "/pulls/" + number + "/revert",
            query: [],
            headers: [],
            body: extra_body(fields),
            jq: parsed.jq,
            template: parsed.template,
            json_fields: parsed.json_fields,
            include_headers: parsed_flag(parsed, "include"),
            silent: parsed_flag(parsed, "silent"),
            verbose: parsed_flag(parsed, "verbose"),
          }),
        )
      }
      _ => ()
    }
  }
  Ok(None)
}
