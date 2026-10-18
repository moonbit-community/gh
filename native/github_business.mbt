///|
/// Core GitHub resource commands share a small request builder. It keeps the
/// command layer independent from generated SDK models and makes every
/// operation observable through the raw GitHub client fixture seam.
priv struct BusinessRequest {
  verb : String
  path : String
  query : Array[(String, String)]
  headers : Array[(String, String)]
  body : Bytes?
  jq : String?
  template : String?
  include_headers : Bool
  silent : Bool
  verbose : Bool
  json_fields : String?
}

///|
priv struct ParsedBusiness {
  command : String
  subcommand : String
  positionals : Array[String]
  values : Map[String, String]
  flags : Map[String, Bool]
  repository : String?
  jq : String?
  template : String?
  json_fields : String?
}

///|
fn business_value_option(name : String) -> Bool {
  name
  is ("repo"
  | "hostname"
  | "json"
  | "jq"
  | "template"
  | "limit"
  | "q"
  | "org"
  | "env"
  | "state"
  | "label"
  | "labels"
  | "color"
  | "new_name"
  | "author"
  | "assignee"
  | "milestone"
  | "creator"
  | "since"
  | "before"
  | "base"
  | "head"
  | "title"
  | "body"
  | "homepage"
  | "has_issues"
  | "has_projects"
  | "has_wiki"
  | "has_discussions"
  | "is_template"
  | "team_id"
  | "auto_init"
  | "gitignore_template"
  | "license_template"
  | "ssh_key"
  | "organization"
  | "default_branch_only"
  | "maintainer_can_modify"
  | "commit_title"
  | "commit_message"
  | "sha"
  | "merge_method"
  | "tag_name"
  | "target_commitish"
  | "prerelease"
  | "make_latest"
  | "generate_release_notes"
  | "discussion_category_name"
  | "enable_debug_logging"
  | "enable_step_debug_logging"
  | "ref"
  | "inputs"
  | "key"
  | "value"
  | "files"
  | "file"
  | "pattern"
  | "dir"
  | "interval"
  | "timeout"
  | "workflow_id"
  | "event"
  | "workflow"
  | "branch"
  | "depth"
  | "tag"
  | "name"
  | "description"
  | "visibility"
  | "affiliation"
  | "type"
  | "direction"
  | "per_page"
  | "page"
  | "search"
  | "filename"
  | "extension"
  | "path"
  | "match"
  | "stars"
  | "fork"
  | "forks"
  | "archived"
  | "size"
  | "followers"
  | "pushed"
  | "updated"
  | "closed"
  | "merged"
  | "comments"
  | "linked"
  | "in"
  | "review"
  | "reviewer"
  | "reviewed_by"
  | "mentions"
  | "committer"
  | "author_date"
  | "committer_date"
  | "new_owner"
  | "new_repo"
  | "new_issue"
  | "reason"
  | "lock_reason"
  | "approve"
  | "request_changes"
  | "commit"
  | "log"
  | "log_failed"
  | "rerun_failed"
  | "exit_status"
  | "clobber"
  | "source"
  | "target"
  | "comment"
  | "subject"
  | "user"
  | "format"
  | "field"
  | "sort"
  | "order"
  | "language"
  | "owner"
  | "topic"
  | "category"
  | "includes_parents"
  | "inherited"
  | "created"
  | "draft"
  | "confirm")
}

///|
fn business_boolean_option(name : String) -> Bool {
  name
  is ("web"
  | "draft"
  | "all"
  | "participating"
  | "public"
  | "private"
  | "has_issues"
  | "has_projects"
  | "has_wiki"
  | "has_discussions"
  | "is_template"
  | "default_branch_only"
  | "maintainer_can_modify"
  | "prerelease"
  | "generate_release_notes"
  | "exclude_pull_requests"
  | "dry_run"
  | "confirm"
  | "verify_tag"
  | "fail_on_no_commits"
  | "latest"
  | "force"
  | "clobber"
  | "skip_existing"
  | "read_only"
  | "archive"
  | "unarchive"
  | "fill"
  | "recover"
  | "no_fork"
  | "wait"
  | "watch"
  | "exit_status"
  | "yes"
  | "delete_branch"
  | "admin"
  | "verbose"
  | "silent"
  | "include"
  | "follow"
  | "archived"
  | "fork"
  | "required"
  | "no_assignee"
  | "no_label"
  | "no_milestone"
  | "merge"
  | "request_changes"
  | "approve"
  | "comment"
  | "log"
  | "log_failed"
  | "rerun_failed"
  | "json")
}

///|
/// GitHub exposes kebab-case flags while REST keys use snake_case.
fn business_option_key(name : String) -> String {
  name.replace_all(old="-", new="_")
}

///|
fn parse_business(options : @github_cli.BusinessOptions) -> ParsedBusiness {
  let args = options.args()
  let mut subcommand = "list"
  let positionals : Array[String] = []
  let values : Map[String, String] = Map([])
  let flags : Map[String, Bool] = Map([])
  let mut repository : String? = None
  let mut jq : String? = None
  let mut template : String? = None
  let mut json_fields : String? = None
  let mut index = 0
  // `browse` accepts a URL/path directly and has no nested subcommand. Keep
  // its first non-flag argument in `positionals` so punctuation is preserved
  // for the browser opener; resource commands still consume their first word
  // as the subcommand.
  let mut found_subcommand = options.command() == "browse"
  while index < args.length() {
    let arg = args[index]
    if arg == "--" {
      index += 1
      while index < args.length() {
        positionals.push(args[index])
        index += 1
      }
      continue
    }
    if arg == "-R" || arg == "--repo" {
      if index + 1 < args.length() {
        repository = Some(args[index + 1])
        index += 2
      } else {
        index += 1
      }
      continue
    }
    if arg.has_prefix("--repo=") {
      repository = Some(arg[7:].to_owned())
      index += 1
      continue
    }
    if arg == "--jq" ||
      arg == "-q" ||
      arg == "--template" ||
      arg == "-t" ||
      arg == "--json" {
      if index + 1 < args.length() {
        let value = args[index + 1]
        if arg is ("--jq" | "-q") {
          jq = Some(value)
        } else if arg is ("--template" | "-t") {
          template = Some(value)
        } else {
          json_fields = Some(value)
        }
        index += 2
      } else {
        index += 1
      }
      continue
    }
    if arg.has_prefix("--jq=") {
      jq = Some(arg[5:].to_owned())
      index += 1
      continue
    }
    if arg.has_prefix("--template=") {
      template = Some(arg[10:].to_owned())
      index += 1
      continue
    }
    if arg.has_prefix("--json=") {
      json_fields = Some(arg[7:].to_owned())
      index += 1
      continue
    }
    if arg == "--include" || arg == "-i" {
      flags["include"] = true
      index += 1
      continue
    }
    if arg == "--silent" {
      flags["silent"] = true
      index += 1
      continue
    }
    if arg == "--verbose" {
      flags["verbose"] = true
      index += 1
      continue
    }
    if arg.has_prefix("--") {
      let raw = arg[2:].to_owned()
      let (name, attached) = match raw.split_once("=") {
        Some((name, value)) =>
          (business_option_key(name.to_owned()), Some(value.to_owned()))
        None => (business_option_key(raw), None)
      }
      if attached is Some(value) {
        values[name] = value
      } else if business_value_option(name) &&
        !business_boolean_option(name) &&
        index + 1 < args.length() &&
        !args[index + 1].has_prefix("-") {
        values[name] = args[index + 1]
        index += 1
      } else {
        flags[name] = true
      }
      index += 1
      continue
    }
    if arg.has_prefix("-") {
      // Preserve short command flags in the generic map. Unknown switches are
      // intentionally tolerated here; endpoint construction still remains
      // deterministic and `gh api` handles strict option diagnostics.
      let name = business_option_key(
        arg.strip_prefix("-").unwrap_or(arg).to_owned(),
      )
      if index + 1 < args.length() && !args[index + 1].has_prefix("-") {
        values[name] = args[index + 1]
        index += 1
      } else {
        flags[name] = true
      }
      index += 1
      continue
    }
    if !found_subcommand {
      subcommand = arg
      found_subcommand = true
    } else {
      positionals.push(arg)
    }
    index += 1
  }
  {
    command: options.command(),
    subcommand,
    positionals,
    values,
    flags,
    repository,
    jq,
    template,
    json_fields,
  }
}

///|
/// Reject misspelled long options at the business boundary.  The generic
/// business parser intentionally stores values in maps, but silently
/// ignoring a typo (for example `--sttae`) is a dangerous gh compatibility
/// failure.  Short options remain command-specific and are left to the
/// command implementation, matching gh's aliases and future extension room.
fn business_unknown_option(options : @github_cli.BusinessOptions) -> String? {
  let args = options.args()
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    if arg == "--" {
      return None
    }
    if arg.has_prefix("--") && arg != "--help" {
      let raw = arg[2:].to_owned()
      let name = match raw.split_once("=") {
        Some((value, _)) => business_option_key(value.to_owned())
        None => business_option_key(raw)
      }
      let known = name == "repo" ||
        name == "hostname" ||
        name == "jq" ||
        name == "template" ||
        name == "json" ||
        name == "include" ||
        name == "silent" ||
        name == "verbose" ||
        business_value_option(name) ||
        business_boolean_option(name)
      if !known {
        return Some(arg)
      }
      if !arg.contains("=") &&
        business_value_option(name) &&
        !business_boolean_option(name) {
        index += 1
      }
    }
    index += 1
  }
  None
}

///|
fn parsed_flag(parsed : ParsedBusiness, name : String) -> Bool {
  parsed.flags.get(name) is Some(true)
}

///|
fn business_segment(value : String) -> Result[String, @github_cli.Output] {
  guard !value.is_empty() && value != "." && value != ".." else {
    return Err(@github_cli.failure(message="invalid command argument"))
  }
  guard value
    .iter()
    .all(ch => ch.to_int() >= 32 && ch.to_int() != 127 && ch != '\\') else {
    return Err(@github_cli.failure(message="invalid command argument"))
  }
  // Every positional value used as a REST path segment must be escaped.  The
  // request validator deliberately accepts percent escapes, while leaving a
  // raw `?`, `#`, `%` or non-ASCII byte here would change the route or make
  // the request invalid.  Keep only RFC 3986 unreserved bytes verbatim.
  let output = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(value) {
    if byte is (b'a'..<=b'z' | b'A'..<=b'Z' | b'0'..<=b'9') ||
      byte is (b'-' | b'.' | b'_' | b'~') {
      output.write_char(byte.to_int().to_char().unwrap())
    } else {
      output.write_char('%')
      output.write_char(hex.get_char(byte.to_int() / 16).unwrap())
      output.write_char(hex.get_char(byte.to_int() % 16).unwrap())
    }
  }
  Ok(output.to_string())
}

///|
fn business_repository_arg(options : @github_cli.BusinessOptions) -> String? {
  let parsed = parse_business(options)
  business_explicit_repository(options.command(), parsed)
}

///|
/// `gh repo view [repository]` accepts the repository as a positional value.
/// Resolve it before local git inference and use the same selection at the
/// request boundary so embedding callers get identical precedence.
fn business_explicit_repository(
  command : String,
  parsed : ParsedBusiness,
) -> String? {
  if command == "repo" && parsed.subcommand == "view" {
    match parsed.positionals.get(0) {
      Some(repository) => Some(repository)
      None => parsed.repository
    }
  } else {
    parsed.repository
  }
}

///|
/// Extract a command-level `--hostname` without exposing the mutable parser
/// maps to the executable boundary.
fn business_hostname_arg(options : @github_cli.BusinessOptions) -> String? {
  let args = options.args()
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    if arg == "--hostname" && index + 1 < args.length() {
      return Some(args[index + 1])
    }
    if arg.has_prefix("--hostname=") {
      return Some(arg[11:].to_owned())
    }
    index += 1
  }
  None
}

///|
fn business_needs_repository(options : @github_cli.BusinessOptions) -> Bool {
  let parsed = parse_business(options)
  match options.command() {
    "repo" =>
      parsed.subcommand
      is ("view"
      | "edit"
      | "delete"
      | "rename"
      | "sync"
      | "fork"
      | "clone"
      | "archive"
      | "unarchive"
      | "deploy-key"
      | "read-dir"
      | "read-file")
    "issue"
    | "pr"
    | "discussion"
    | "release"
    | "run"
    | "workflow"
    | "actions"
    | "label"
    | "cache"
    | "ruleset" => true
    "secret" =>
      // Organization-scoped Actions resources use /orgs/{org} and do not
      // require -R. Repository and environment scopes still need a repo.
      parsed.values.get("org") is None
    "variable" => parsed.values.get("org") is None
    _ => false
  }
}

///|
/// Build the URL used by `gh browse`.  Positional paths are encoded one
/// segment at a time so a value such as `issues?state=open` cannot turn into
/// a query on the opener's URL.  Explicit HTTP(S) URLs are accepted as gh
/// does, but control characters and embedded credentials are rejected.
fn business_browse_url(
  options : @github_cli.BusinessOptions,
  repository : @github_cli.RepositoryContext?,
) -> Result[String, @github_cli.Output] {
  let parsed = parse_business(options)
  let base = match repository {
    Some(context) => "https://" + context.host() + "/" + context.full_name()
    None => "https://github.com"
  }
  guard parsed.positionals.get(0) is Some(first) else { return Ok(base) }
  if first.has_prefix("https://") || first.has_prefix("http://") {
    guard !first.contains("@") &&
      first.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) else {
      return Err(@github_cli.failure(message="invalid browse URL"))
    }
    return Ok(first)
  }
  let output = StringBuilder()
  output.write_string(base)
  for positional in parsed.positionals {
    let segment = match business_segment(positional) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    output.write_string("/" + segment)
  }
  Ok(output.to_string())
}

///|
fn business_help_requested(options : @github_cli.BusinessOptions) -> Bool {
  let args = options.args()
  // Nested resource commands print their command help when invoked without
  // arguments. `gh status` is the top-level exception and performs its
  // notifications request directly.
  (args.is_empty() && options.command() != "status") ||
  args.any(arg => arg is ("--help" | "-h"))
}

///|
fn business_json_body(parsed : ParsedBusiness, names : Array[String]) -> Bytes? {
  let body : Map[String, Json] = Map([])
  for name in names {
    let value = match parsed.values.get(name) {
      None if name == "tag_name" &&
        parsed.command == "release" &&
        parsed.subcommand == "create" => parsed.positionals.get(0)
      None if name == "labels" => parsed.values.get("label")
      None if name == "lock_reason" => parsed.values.get("reason")
      None if name == "name" => parsed.values.get("new_name")
      other => other
    }
    match value {
      Some(value) => body[name] = @github_cli.typed_field(value)
      None =>
        if parsed.flags.get(name) is Some(true) {
          body[name] = Json::boolean(true)
        }
    }
  }
  if body.is_empty() {
    None
  } else {
    Some(@utf8.encode(Json::object(body).stringify()))
  }
}

///|
/// Actions variable values are always strings, even when they look like JSON
/// booleans or numbers.  `--body` is gh's spelling for the value in the
/// resource command; accept `--value` as the API-oriented alias as well.
fn business_string_body(parsed : ParsedBusiness, field : String) -> Bytes? {
  let value = match parsed.values.get(field) {
    Some(value) => Some(value)
    None if field == "value" => parsed.values.get("body")
    None => None
  }
  match value {
    Some(value) => {
      let body : Map[String, Json] = Map([])
      body[field] = Json::string(value)
      Some(@utf8.encode(Json::object(body).stringify()))
    }
    None => None
  }
}

///|
/// Build a JSON body with an operation supplied state.  `gh issue close`,
/// `gh issue reopen`, and their pull request counterparts do not require the
/// user to spell out `--state`; the command itself determines the REST state.
/// Keeping this helper separate also avoids mutating the parser's option map
/// when a caller reuses a parsed invocation in a fixture.
fn business_state_body(
  parsed : ParsedBusiness,
  state : String,
  names : Array[String],
) -> Bytes {
  let body : Map[String, Json] = Map([])
  body["state"] = Json::string(state)
  for name in names {
    let value = match parsed.values.get(name) {
      None if name == "labels" => parsed.values.get("label")
      None if name == "lock_reason" => parsed.values.get("reason")
      None if name == "state_reason" =>
        parsed.values.get("reason").map(business_rest_state_reason)
      other => other
    }
    match value {
      Some(value) => body[name] = @github_cli.typed_field(value)
      None =>
        if parsed.flags.get(name) is Some(true) {
          body[name] = Json::boolean(true)
        }
    }
  }
  @utf8.encode(Json::object(body).stringify())
}

///|
/// Convert gh's human-readable close reason to the REST issue PATCH value.
fn business_rest_state_reason(value : String) -> String {
  match value {
    "not planned" => "not_planned"
    "completed" => "completed"
    "duplicate" => "duplicate"
    other => other
  }
}

///|
/// Build a body containing an explicit boolean.  The generic field parser
/// only emits booleans for flags that were present, while `gh pr ready` must
/// send `draft=false` even though there is no `--draft=false` CLI spelling.
fn business_boolean_body(
  parsed : ParsedBusiness,
  name : String,
  value : Bool,
  names : Array[String],
) -> Bytes {
  let body : Map[String, Json] = Map([])
  body[name] = Json::boolean(value)
  for field in names {
    match parsed.values.get(field) {
      Some(item) => body[field] = @github_cli.typed_field(item)
      None =>
        if parsed.flags.get(field) is Some(true) {
          body[field] = Json::boolean(true)
        }
    }
  }
  @utf8.encode(Json::object(body).stringify())
}

///|
fn business_query(
  parsed : ParsedBusiness,
  names : Array[String],
) -> Array[(String, String)] {
  let query : Array[(String, String)] = []
  for name in names {
    let value = match parsed.values.get(name) {
      None if name == "labels" => parsed.values.get("label")
      other => other
    }
    match value {
      Some(value) => {
        let key = if name == "limit" { "per_page" } else { name }
        // `--limit` is the user-facing spelling of `per_page`. If callers
        // provide both spellings, preserve the first value rather than
        // emitting duplicate query keys that GitHub interprets differently
        // across endpoints.
        if !query.any(pair => pair.0 == key) {
          query.push((key, value))
        }
      }
      None => ()
    }
  }
  query
}

///|
/// Validate the syntactic field surface before resolving credentials or
/// issuing a request.  Command schemas intentionally share the broad set of
/// stable fields used by gh's core JSON exporters; nested paths are checked by
/// their root so `labels[].name` remains valid.
fn business_validate_json_fields(
  parsed : ParsedBusiness,
) -> Result[Unit, String] {
  guard parsed.json_fields is Some(fields) else { return Ok(()) }
  let known = [
    "id", "nodeId", "number", "name", "title", "body", "state", "url", "htmlUrl",
    "fullName", "nameWithOwner", "visibility", "description", "owner", "login", "author",
    "user", "labels", "comments", "assignees", "assignee", "milestone", "createdAt",
    "updatedAt", "closedAt", "mergedAt", "merged", "draft", "isDraft", "isPrerelease",
    "headRefName", "baseRefName", "headRepository", "baseRepository", "reviewDecision",
    "reviews", "checks", "statusCheckRollup", "workflowRuns", "workflow_runs", "workflows",
    "status", "conclusion", "nameWithOwner", "tagName", "name", "assets", "authorLogin",
    "databaseId", "workflowDatabaseId", "runNumber", "event", "path", "state", "category",
    "isAnswered", "locked", "totalCount", "incompleteResults", "items", "repositories",
    "issues", "pulls", "releases", "organizations", "secrets", "variables", "caches",
    "actions_caches", "key", "ref", "sizeInBytes", "startedAt", "completedAt", "attempt",
    "headSha", "workflowName", "environment", "public", "closed", "shortDescription",
    "number", "project", "projects", "viewer", "repository",
  ]
  for raw in fields.split(",") {
    let parts = raw.trim().split(".").map(x => x.to_owned()).collect()
    let name = parts.get(0).unwrap_or("")
    guard !name.is_empty() else { return Err("JSON field cannot be empty") }
    if !known.contains(name) {
      return Err("unknown JSON field: " + name)
    }
  }
  Ok(())
}

///|
fn business_collection_command(parsed : ParsedBusiness) -> Bool {
  match (parsed.command, parsed.subcommand) {
    ("repo", "list")
    | ("issue", "list" | "status" | "comments")
    | ("pr", "list")
    | ("release", "list")
    | ("run", "list")
    | ("workflow", "list")
    | ("actions", "list")
    | ("search", "issues" | "prs" | "repos" | "code" | "commits")
    | ("org", "list")
    | ("label", "list")
    | ("secret", "list")
    | ("variable", "list")
    | ("cache", "list") => true
    _ => false
  }
}

///|
fn business_requested_limit(parsed : ParsedBusiness) -> Int32? {
  match parsed.values.get("limit") {
    Some(value) => Some(@string.parse_int(value) catch { _ => return None })
    None => None
  }
}

///|
fn business_page_query(
  query : Array[(String, String)],
  page : Int32,
) -> Array[(String, String)] {
  let output : Array[(String, String)] = []
  let mut has_page = false
  let mut has_per_page = false
  for (name, value) in query {
    if name == "page" {
      if !has_page {
        output.push(("page", page.to_string()))
        has_page = true
      }
    } else if name == "per_page" {
      if !has_per_page {
        output.push(("per_page", "100"))
        has_per_page = true
      }
    } else {
      output.push((name, value))
    }
  }
  if !has_page {
    output.push(("page", page.to_string()))
  }
  if !has_per_page {
    output.push(("per_page", "100"))
  }
  output
}

///|
/// Convert a validated pagination URL back into a request path.  The GitHub
/// client rejects cross-origin links; keeping the configured base prefix here
/// also prevents an Enterprise `/api/v3` prefix from being duplicated.
fn business_next_path(
  next_url : String,
  base_url : String,
) -> Result[String, String] {
  guard next_url.has_prefix(base_url) else {
    return Err("pagination link changed host")
  }
  let suffix = next_url[base_url.length():].to_owned()
  guard suffix.is_empty() || suffix.has_prefix("/") else {
    return Err("invalid pagination link")
  }
  if suffix.is_empty() {
    Ok("/")
  } else {
    Ok(suffix)
  }
}

///|
fn business_collection_field(
  parsed : ParsedBusiness,
  value : Json,
) -> (String?, Array[Json]) {
  match value {
    Array(items) => (None, items)
    Object(fields) => {
      let candidates = match (parsed.command, parsed.subcommand) {
        ("run", "list") => ["workflow_runs"]
        ("workflow" | "actions", "list") => ["workflows"]
        ("search", _) => ["items"]
        _ =>
          [
            "issues", "pulls", "releases", "repositories", "organizations", "labels",
            "secrets", "variables", "artifacts", "caches", "actions_caches", "items",
          ]
      }
      for name in candidates {
        match fields.get(name) {
          Some(Array(items)) => return (Some(name), items)
          _ => ()
        }
      }
      (None, [])
    }
    _ => (None, [])
  }
}

///|
fn business_append_collection(
  value : Json,
  field : String?,
  items : Array[Json],
) -> Json {
  match field {
    None => Json::array(items)
    Some(name) =>
      match value {
        Object(fields) => {
          fields[name] = Json::array(items)
          Json::object(fields)
        }
        _ => value
      }
  }
}

///|
/// Send a collection request and fetch additional pages when gh's `--limit`
/// exceeds GitHub's 100-item page size.  The first response headers are kept
/// for `--include`; only the JSON collection body is merged.
async fn execute_business_collection(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  client : @github.Client,
  base_url : String,
) -> Result[(@github.RawResponse, Bytes?), @github_cli.Output] {
  let limit = business_requested_limit(parsed)
  let should_page = request.verb == "GET" &&
    business_collection_command(parsed) &&
    limit is Some(value) &&
    value > 100
  let first_query = if should_page {
    business_page_query(request.query, 1)
  } else {
    request.query
  }
  let first = match
    (if request.path == "/graphql" &&
      (parsed.command == "project" || parsed.command == "discussion") {
      client.graphql_raw(
        @github.Request::new(
          verb=request.verb,
          path=request.path,
          query=first_query,
          headers=request.headers,
          body?=request.body,
        ),
        operation_id="business",
        operation_name=parsed.command,
      )
    } else {
      client.request(
        @github.Request::new(
          verb=request.verb,
          path=request.path,
          query=first_query,
          headers=request.headers,
          body?=request.body,
        ),
        operation_id="business",
        operation_name=parsed.command,
      )
    }) {
    Ok(value) => value
    Err(error) =>
      match error.response() {
        Some(value) => value
        None => return Err(@github_cli.failure(message=error.code()))
      }
  }
  if !should_page || first.status() < 200 || first.status() >= 300 {
    return Ok((first, None))
  }
  let first_json : Json = @json.parse(@utf8.decode(first.body())) catch {
    _ => return Ok((first, None))
  }
  let (field, first_items) = business_collection_field(parsed, first_json)
  if field is None && first_items.is_empty() {
    return Ok((first, None))
  }
  let target = limit.unwrap()
  let merged : Array[Json] = first_items.copy()
  let mut page = 2
  let mut current_path = request.path
  let mut current_query = first_query
  let mut last_response = first
  let visited : Map[String, Bool] = Map([])
  while merged.length() < target && page <= 10000 {
    let current_url = base_url +
      current_path +
      (if current_query.is_empty() {
        ""
      } else {
        "?" + current_query.map(pair => pair.0 + "=" + pair.1).join("&")
      })
    let next_path = match last_response.next_url(current_url~) {
      Ok(Some(url)) =>
        match business_next_path(url, base_url) {
          Ok(value) => value
          Err(message) => return Err(@github_cli.failure(message~))
        }
      Ok(None) => break
      Err(_) =>
        return Err(@github_cli.failure(message="invalid pagination link"))
    }
    guard !visited.contains(next_path) else {
      return Err(@github_cli.failure(message="pagination repeated link"))
    }
    visited[next_path] = true
    let next_parts = match next_path.split_once("?") {
      Some((path, query_string)) => {
        let query : Array[(String, String)] = []
        for part in query_string.split("&") {
          match part.split_once("=") {
            Some((name, value)) =>
              query.push((name.to_owned(), value.to_owned()))
            None if !part.is_empty() => query.push((part.to_owned(), ""))
            None => ()
          }
        }
        (path.to_owned(), query)
      }
      None => (next_path, [])
    }
    current_path = next_parts.0
    current_query = next_parts.1
    let response = match
      client.request(
        @github.Request::new(
          verb=request.verb,
          path=current_path,
          query=current_query,
          headers=request.headers,
          body?=request.body,
        ),
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
    last_response = response
    let page_json : Json = @json.parse(@utf8.decode(response.body())) catch {
      _ => break
    }
    let (_, page_items) = business_collection_field(parsed, page_json)
    if page_items.is_empty() {
      break
    }
    for item in page_items {
      if merged.length() >= target {
        break
      }
      merged.push(item)
    }
    if page_items.length() < 100 {
      break
    }
    page += 1
  }
  Ok(
    (
      first,
      Some(
        @utf8.encode(
          business_append_collection(first_json, field, merged).stringify(),
        ),
      ),
    ),
  )
}

///|
/// Match gh's search keyword formatter. Each positional argument is one
/// keyword: whitespace and quote characters are preserved by JSON-style
/// quoting. A colon splits a raw qualifier from its value, and only the value
/// is quoted (for example `in:name user:owner` becomes
/// `in:"name user:owner"`).
fn business_search_quote(value : String) -> String {
  if value
    .iter()
    .any(ch => ch == ' ' || ch == '"' || ch == '\t' || ch == '\r' || ch == '\n') {
    Json::string(value).stringify()
  } else {
    value
  }
}

///|
fn business_search_keyword(value : String) -> String {
  match value.split_once(":") {
    Some((name, qualifier)) =>
      name.to_owned() + ":" + business_search_quote(qualifier.to_owned())
    None => business_search_quote(value)
  }
}

///|
/// Search commands use GitHub's qualifier syntax inside `q`; the REST API
/// does not expose these as independent query parameters. Keeping this
/// conversion in one helper prevents `--repo`, `--language`, and date
/// qualifiers from being silently ignored or sent as unsupported parameters.
fn business_search_terms(
  parsed : ParsedBusiness,
  kind : String,
) -> Array[String] {
  let terms : Array[String] = []
  for positional in parsed.positionals {
    terms.push(business_search_keyword(positional))
  }
  match parsed.values.get("q") {
    Some(value) => terms.push(value)
    None => ()
  }
  match parsed.repository {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(context) => terms.push("repo:" + context.full_name())
        Err(_) => ()
      }
    None => ()
  }
  let qualifiers : Array[(String, String)] = match kind {
    "code" =>
      [
        ("filename", "filename"),
        ("extension", "extension"),
        ("path", "path"),
        ("language", "language"),
        ("repo", "repo"),
        ("owner", "user"),
        ("match", "in"),
        ("size", "size"),
      ]
    "repositories" =>
      [
        ("owner", "user"),
        ("org", "org"),
        ("user", "user"),
        ("language", "language"),
        ("topic", "topic"),
        ("stars", "stars"),
        ("forks", "forks"),
        ("size", "size"),
        ("followers", "followers"),
        ("created", "created"),
        ("pushed", "pushed"),
        ("archived", "archived"),
        ("in", "in"),
      ]
    "commits" =>
      [
        ("author", "author"),
        ("committer", "committer"),
        ("author_date", "author-date"),
        ("committer_date", "committer-date"),
        ("repo", "repo"),
        ("path", "path"),
        ("owner", "user"),
      ]
    _ =>
      [
        ("repo", "repo"),
        ("author", "author"),
        ("assignee", "assignee"),
        ("mentions", "mentions"),
        ("reviewer", "reviewer"),
        ("reviewed_by", "reviewed-by"),
        ("label", "label"),
        ("milestone", "milestone"),
        ("state", "state"),
        ("base", "base"),
        ("head", "head"),
        ("created", "created"),
        ("updated", "updated"),
        ("closed", "closed"),
        ("merged", "merged"),
        ("comments", "comments"),
        ("linked", "linked"),
        ("in", "in"),
      ]
  }
  for (name, qualifier) in qualifiers {
    match parsed.values.get(name) {
      Some(value) => terms.push(qualifier + ":" + business_search_quote(value))
      None => ()
    }
  }
  for
    (name, qualifier) in [
      ("archived", "archived"),
      ("fork", "fork"),
      ("draft", "draft"),
      ("no_assignee", "no:assignee"),
      ("no_label", "no:label"),
      ("no_milestone", "no:milestone"),
    ] {
    if parsed_flag(parsed, name) {
      terms.push(
        if name.has_prefix("no_") {
          qualifier
        } else {
          qualifier + ":true"
        },
      )
    }
  }
  terms
}

///|
/// Apply `--json a,b.c` at the command boundary.  Keeping this projection
/// here lets the raw response and trace retain the complete GitHub payload,
/// while the user-facing command only emits the requested fields.
fn business_json_lookup(value : Json, path : Array[String]) -> Json {
  let mut current = value
  for segment in path {
    current = match current {
      Object(fields) =>
        // gh exposes a few stable camelCase field names whose REST payload
        // counterparts use snake_case or a shorter identifier.  Resolve the
        // alias only when the requested spelling is absent, preserving the
        // requested key in the projected output.
        match fields.get(segment) {
          Some(found) => found
          None => {
            let field_alias = match segment {
              "fullName" => Some("full_name")
              "nameWithOwner" => Some("full_name")
              "databaseId" => Some("id")
              "workflowDatabaseId" => Some("workflow_id")
              "isDraft" => Some("draft")
              "isPrerelease" => Some("prerelease")
              "createdAt" => Some("created_at")
              "updatedAt" => Some("updated_at")
              "closedAt" => Some("closed_at")
              "mergedAt" => Some("merged_at")
              _ => None
            }
            match field_alias {
              Some(name) => fields.get(name).unwrap_or(Json::null())
              None => Json::null()
            }
          }
        }
      _ => Json::null()
    }
  }
  current
}

///|
/// Normalize REST's lower-case issue/PR state to the GraphQL enum spelling
/// exported by the typed `gh issue` and `gh pr` commands. Search endpoints
/// intentionally keep their lower-case REST state and do not use this helper.
fn business_normalize_state(
  value : Json,
  enabled : Bool,
  pull_request~ : Bool = false,
) -> Json {
  if !enabled {
    return value
  }
  match value {
    Object(fields) => {
      let normalized = match (fields.get("state"), fields.get("merged_at")) {
        (Some(String(_)), Some(String(_))) if pull_request => "MERGED"
        (Some(String(state)), _) => state.to_upper()
        _ => ""
      }
      if !normalized.is_empty() {
        fields["state"] = Json::string(normalized)
      }
      Json::object(fields)
    }
    Array(items) =>
      Json::array(
        items.map(item => business_normalize_state(item, enabled, pull_request~)),
      )
    _ => value
  }
}

///|
fn business_project_object(value : Json, names : Array[String]) -> Json {
  match value {
    Object(_) => {
      let output : Map[String, Json] = Map([])
      for name in names {
        let parts = name.split(".").map(x => x.to_owned()).collect()
        guard parts.get(0) is Some(root) && !root.is_empty() else { continue }
        let selected = business_json_lookup(value, parts)
        if parts.length() == 1 {
          output[root] = selected
        } else {
          let nested : Map[String, Json] = Map([])
          nested[parts[parts.length() - 1]] = selected
          // Nested projections are kept useful and deterministic even when
          // sibling paths are requested; merge the common root below.
          let mut cursor = Json::object(nested)
          for index = parts.length() - 2; index >= 1; index = index - 1 {
            let wrapped : Map[String, Json] = Map([])
            wrapped[parts[index]] = cursor
            cursor = Json::object(wrapped)
            if index == 1 {
              break
            }
          }
          match output.get(root) {
            Some(Object(existing)) =>
              match cursor {
                Object(extra) =>
                  for key, item in extra {
                    existing[key] = item
                  }
                _ => ()
              }
            _ => output[root] = cursor
          }
        }
      }
      Json::object(output)
    }
    _ => value
  }
}

///|
/// GitHub collection endpoints wrap their result arrays in endpoint-specific
/// objects (for example `workflow_runs`, `workflows`, and `items`).  The
/// corresponding gh list/search commands expose the collection itself to the
/// JSON projection layer.  Unwrap only when the command supplied an explicit
/// envelope key so repository/detail responses remain objects.
fn business_unwrap_envelope(value : Json, envelope_key : String?) -> Json {
  match envelope_key {
    Some(key) =>
      match value {
        Object(fields) =>
          match fields.get(key) {
            Some(Array(items)) => Json::array(items)
            _ => value
          }
        _ => value
      }
    None => value
  }
}

///|
/// v2.102.0 hides every workflow whose state is not `active` unless `--all`
/// is supplied. It then returns before the exporter when no workflows remain,
/// so JSON, jq, and template output must all stay empty in that case.
fn business_workflow_list_body(
  body : Bytes,
  include_disabled : Bool,
) -> Result[Bytes?, Unit] {
  let value : Json = @json.parse(@utf8.decode(body)) catch {
    _ => return Err(())
  }
  let items = match business_unwrap_envelope(value, Some("workflows")) {
    Array(items) => items
    _ => return Err(())
  }
  let filtered = if include_disabled {
    items
  } else {
    items.filter(item => {
      match item {
        Object(fields) => fields.get("state") is Some(String("active"))
        _ => false
      }
    })
  }
  if filtered.is_empty() {
    return Ok(None)
  }
  let value = match value {
    Object(fields) => {
      let fields = fields.copy()
      fields["workflows"] = Json::array(filtered)
      Json::object(fields)
    }
    _ => Json::array(filtered)
  }
  Ok(Some(@utf8.encode(value.stringify())))
}

///|
fn business_project_response(
  body : Bytes,
  fields : String,
  repository_view~ : Bool,
  state_upper~ : Bool = false,
  pull_request~ : Bool = false,
  envelope_key? : String,
) -> Result[Bytes, Unit] {
  let value : Json = @json.parse(@utf8.decode(body)) catch {
    _ => return Err(())
  }
  let value = if repository_view {
    match value {
      Object(repository) =>
        match repository.get("full_name") {
          Some(String(full_name)) => {
            let fields = repository.copy()
            fields["nameWithOwner"] = Json::string(full_name)
            // Repository view exports the GraphQL Visibility enum; search
            // repository results use the REST lower-case value and bypass
            // this repository-only normalization.
            match fields.get("visibility") {
              Some(String(visibility)) =>
                fields["visibility"] = Json::string(visibility.to_upper())
              _ => ()
            }
            Json::object(fields)
          }
          _ => value
        }
      _ => value
    }
  } else {
    value
  }
  let value = business_unwrap_envelope(value, envelope_key)
  let value = business_normalize_state(value, state_upper, pull_request~)
  let names = fields
    .split(",")
    .map(x => x.trim().to_owned())
    .filter(x => !x.is_empty())
    .collect()
  guard !names.is_empty() else { return Err(()) }
  let projected = match value {
    Array(items) =>
      Json::array(items.map(item => business_project_object(item, names)))
    _ => business_project_object(value, names)
  }
  Ok(@utf8.encode(projected.stringify() + "\n"))
}

///|
/// Release assets are intentionally parsed only at the native boundary.  The
/// raw GitHub client keeps their bytes opaque, while these small records let
/// `gh release download/upload` perform their required second request.
priv struct BusinessReleaseAsset {
  id : String
  name : String
}

///|
fn business_release_id(value : Json) -> String? {
  match value {
    Object(fields) =>
      match fields.get("id") {
        Some(Number(number, ..)) => Some(number.to_int().to_string())
        Some(String(value)) if !value.is_empty() => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// GitHub release metadata carries an absolute upload URL.  The API origin
/// serves metadata, while github.com serves asset bytes from
/// `uploads.github.com`; keep both the origin and route so the transport can
/// enforce its cross-origin allow-list without exposing the URL template's
/// `{?name,label}` suffix as a literal path segment.
fn business_release_upload_target(value : Json) -> (String, String)? {
  match value {
    Object(fields) =>
      match fields.get("upload_url") {
        Some(String(url)) => {
          let (scheme, rest) = match url.split_once("://") {
            Some(value) => value
            None => return None
          }
          guard scheme == "https" else { return None }
          let (authority, suffix) = match rest.split_once("/") {
            Some(value) => value
            None => return None
          }
          guard !authority.is_empty() else { return None }
          let raw_path = "/" + suffix.to_owned()
          let path = match raw_path.split_once("{?") {
            Some((prefix, _)) => prefix.to_owned()
            None => raw_path
          }
          let path = match path.split_once("?") {
            Some((prefix, _)) => prefix.to_owned()
            None => path
          }
          guard path.has_prefix("/") && path.length() > 1 else { return None }
          Some((scheme.to_owned() + "://" + authority.to_owned(), path))
        }
        _ => None
      }
    _ => None
  }
}

///|
fn business_release_assets(value : Json) -> Array[BusinessReleaseAsset] {
  match value {
    Object(fields) =>
      match fields.get("assets") {
        Some(Array(items)) => {
          let output : Array[BusinessReleaseAsset] = []
          for item in items {
            match item {
              Object(asset) => {
                let id = match asset.get("id") {
                  Some(Number(number, ..)) => number.to_int().to_string()
                  Some(String(value)) => value
                  _ => ""
                }
                let name = match asset.get("name") {
                  Some(String(value)) => value
                  _ => ""
                }
                if !id.is_empty() && !name.is_empty() {
                  output.push({ id, name, })
                }
              }
              _ => ()
            }
          }
          output
        }
        _ => []
      }
    _ => []
  }
}

///|
fn business_asset_matches(name : String, pattern : String?) -> Bool {
  match pattern {
    None => true
    Some(pattern) if pattern == "" || pattern == "*" => true
    Some(pattern) if !pattern.contains("*") => name == pattern
    Some(pattern) => {
      // Support the glob form used by gh's release downloader.  Multiple
      // stars are treated as one wildcard, which is sufficient for fixture
      // and normal asset names without introducing a shell matcher.
      let pieces = pattern.split("*").map(x => x.to_owned()).collect()
      let prefix = pieces.get(0).unwrap_or("")
      let suffix = pieces.last().unwrap_or("")
      name.has_prefix(prefix) &&
      name.has_suffix(suffix) &&
      name.length() >= prefix.length() + suffix.length()
    }
  }
}

///|
fn business_asset_filename(name : String) -> Bool {
  !name.is_empty() &&
  name != "." &&
  name != ".." &&
  !name.contains("/") &&
  !name.contains("\\") &&
  name.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127)
}

///|
fn business_release_metadata(
  response : @github.RawResponse,
) -> Result[Json, @github_cli.Output] {
  guard response.status() >= 200 && response.status() < 300 else {
    return Err(@github_cli.failure(message="release request failed"))
  }
  let text = match response.body_text() {
    Ok(value) => value
    Err(_) =>
      return Err(@github_cli.failure(message="release response is not UTF-8"))
  }
  let value = @json.parse(text) catch {
    _ =>
      return Err(
        @github_cli.failure(message="release response is not valid JSON"),
      )
  }
  Ok(value)
}

///|
async fn execute_release_download(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
  request : BusinessRequest,
  metadata_response : @github.RawResponse,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  guard repository is Some(repo) else {
    return @github_cli.failure(message="a repository is required")
  }
  let metadata = match business_release_metadata(metadata_response) {
    Ok(value) => value
    Err(error) => return error
  }
  let assets = business_release_assets(metadata)
  let pattern = parsed.values.get("pattern")
  let selected = assets.filter(asset => {
    business_asset_matches(asset.name, pattern)
  })
  guard !selected.is_empty() else {
    return @github_cli.failure(message="no release assets matched the pattern")
  }
  let directory = parsed.values.get("dir").unwrap_or(".")
  guard valid_local_git_value(directory) else {
    return @github_cli.failure(message="invalid download directory")
  }
  if !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true) catch {
      _ =>
        return @github_cli.failure(message="cannot create download directory")
    }
  } else {
    guard @fs.kind(directory) == @fs.Directory else {
      return @github_cli.failure(message="download path is not a directory")
    }
  }
  let clobber = parsed_flag(parsed, "clobber")
  for asset in selected {
    guard business_asset_filename(asset.name) else {
      return @github_cli.failure(
        message="release asset has an invalid filename",
      )
    }
    let target = if directory == "." {
      asset.name
    } else {
      directory + "/" + asset.name
    }
    if @fs.exists(target) && !clobber {
      return @github_cli.failure(message="file already exists: " + target)
    }
    let asset_response = match
      client.request(
        @github.Request::new(
          verb="GET",
          path=repo_api_path(repo) + "/releases/assets/" + asset.id,
          headers=[("Accept", "application/octet-stream")],
        ),
        operation_id="release-download-" + asset.id,
        operation_name="release.download",
      ) {
      Ok(value) => value
      Err(error) =>
        match error.response() {
          Some(value) => value
          None => return @github_cli.failure(message=error.code())
        }
    }
    guard asset_response.status() >= 200 && asset_response.status() < 300 else {
      return @github_cli.failure(
        message="could not download release asset " + asset.name,
      )
    }
    @fs.write_file(target, asset_response.body()) catch {
      _ =>
        return @github_cli.failure(
          message="cannot write release asset " + target,
        )
    }
  }
  ignore(options)
  ignore(request)
  @github_cli.success(stdout="")
}

///|
async fn execute_release_upload(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
  request : BusinessRequest,
  metadata_response : @github.RawResponse,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  guard repository is Some(repo) else {
    return @github_cli.failure(message="a repository is required")
  }
  guard parsed.positionals.length() > 1 else {
    return @github_cli.failure(message="at least one asset file is required")
  }
  let metadata = match business_release_metadata(metadata_response) {
    Ok(value) => value
    Err(error) => return error
  }
  let release_id = match business_release_id(metadata) {
    Some(value) => value
    None => return @github_cli.failure(message="release response has no id")
  }
  let (upload_origin, upload_path) = match
    business_release_upload_target(metadata) {
    Some((origin, path)) => (Some(origin), path)
    None => (None, repo_api_path(repo) + "/releases/" + release_id + "/assets")
  }
  for index = 1; index < parsed.positionals.length(); index = index + 1 {
    let source = parsed.positionals[index]
    guard valid_local_git_value(source) else {
      return @github_cli.failure(message="invalid asset filename")
    }
    let name = source.split("/").last().unwrap_or(source).to_owned()
    guard business_asset_filename(name) else {
      return @github_cli.failure(message="invalid asset filename")
    }
    guard @fs.file_size(source) <= 67108864L else {
      return @github_cli.failure(message="release asset exceeds 64 MiB limit")
    }
    let body = @fs.read_file(source).binary() catch {
      _ =>
        return @github_cli.failure(
          message="cannot read release asset " + source,
        )
    }
    let response = match
      client.request(
        @github.Request::new(
          verb="POST",
          path=upload_path,
          query=[("name", name)],
          headers=[("Content-Type", "application/octet-stream")],
          body~,
          origin?=upload_origin,
        ),
        operation_id="release-upload-" + release_id,
        operation_name="release.upload",
      ) {
      Ok(value) => value
      Err(error) =>
        match error.response() {
          Some(value) => value
          None => return @github_cli.failure(message=error.code())
        }
    }
    guard response.status() >= 200 && response.status() < 300 else {
      return @github_cli.failure(
        message="could not upload release asset " + name,
      )
    }
  }
  ignore(options)
  ignore(request)
  @github_cli.success(stdout="")
}

///|
/// Release edit/delete accept a tag in gh's CLI, while GitHub's REST write
/// endpoints require the numeric release id.  The request builder performs
/// the tag lookup; this boundary resolves the id and sends the write request
/// only after the metadata lookup succeeded.
async fn execute_release_edit_delete(
  options : @github_cli.BusinessOptions,
  parsed : ParsedBusiness,
  request : BusinessRequest,
  metadata_response : @github.RawResponse,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  let metadata = match business_release_metadata(metadata_response) {
    Ok(value) => value
    Err(error) => return error
  }
  let release_id = match business_release_id(metadata) {
    Some(value) => value
    None => return @github_cli.failure(message="release response has no id")
  }
  let repo = match repository {
    Some(value) => value
    None => return @github_cli.failure(message="a repository is required")
  }
  let release_verb = if parsed.subcommand == "delete" {
    "DELETE"
  } else {
    "PATCH"
  }
  let response = match
    client.request(
      @github.Request::new(
        verb=release_verb,
        path=repo_api_path(repo) + "/releases/" + release_id,
        headers=request.headers,
        body?=if release_verb == "PATCH" { request.body } else { None },
      ),
      operation_id="release-" + parsed.subcommand + "-" + release_id,
      operation_name="release." + parsed.subcommand,
    ) {
    Ok(value) => value
    Err(error) =>
      match error.response() {
        Some(value) => value
        None => return @github_cli.failure(message=error.code())
      }
  }
  if parsed.subcommand == "delete" {
    if response.status() >= 200 && response.status() < 300 {
      return @github_cli.success(stdout="")
    }
    return @github_cli.render_response(
      response.status(),
      response.headers(),
      response.body(),
    )
  }
  ignore(options)
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

///|
fn repo_api_path(repository : @github_cli.RepositoryContext) -> String {
  "/repos/" + repository.owner() + "/" + repository.name()
}

///|
fn business_run_state(body : Bytes) -> (String, String) {
  let value : Json = @json.parse(@utf8.decode(body)) catch { _ => Json::null() }
  match value {
    Object(fields) => {
      let status = match fields.get("status") {
        Some(String(value)) => value
        _ => ""
      }
      let conclusion = match fields.get("conclusion") {
        Some(String(value)) => value
        _ => ""
      }
      (status, conclusion)
    }
    _ => ("", "")
  }
}

///|
async fn execute_run_watch(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  client : @github.Client,
) -> @github_cli.Output {
  let interval = match parsed.values.get("interval") {
    Some(value) =>
      @string.parse_int(value) catch {
        _ => return @github_cli.failure(message="interval must be an integer")
      }
    None => 3
  }
  guard interval >= 0 && interval <= 3600 else {
    return @github_cli.failure(
      message="interval must be between 0 and 3600 seconds",
    )
  }
  let max_attempts = match parsed.values.get("timeout") {
    Some(value) =>
      @string.parse_int(value) catch {
        _ => return @github_cli.failure(message="timeout must be an integer")
      }
    None => 1200
  }
  guard max_attempts > 0 && max_attempts <= 100000 else {
    return @github_cli.failure(
      message="timeout must be between 1 and 100000 polls",
    )
  }
  let mut attempts = 0
  let mut final_response : @github.RawResponse? = None
  let mut final_conclusion = ""
  while attempts < max_attempts {
    let response = match
      client.request(
        @github.Request::new(
          verb=request.verb,
          path=request.path,
          query=request.query,
          headers=request.headers,
          body?=request.body,
        ),
        operation_id="run-watch",
        operation_name="run.watch",
      ) {
      Ok(value) => value
      Err(error) =>
        match error.response() {
          Some(value) => value
          None => return @github_cli.failure(message=error.code())
        }
    }
    final_response = Some(response)
    let (status, conclusion) = business_run_state(response.body())
    final_conclusion = conclusion
    if status == "completed" ||
      conclusion
      is ("success" | "failure" | "cancelled" | "timed_out" | "action_required") {
      break
    }
    attempts += 1
    if interval > 0 {
      @async.sleep(interval * 1000)
    }
  }
  guard final_response is Some(response) else {
    return @github_cli.failure(message="workflow run watch timed out")
  }
  guard attempts < max_attempts else {
    return @github_cli.failure(message="workflow run watch timed out")
  }
  let output = @github_cli.render_response(
    response.status(),
    response.headers(),
    response.body(),
    jq?=request.jq,
    template?=request.template,
    include_headers=request.include_headers,
    silent=request.silent,
    verbose=request.verbose,
  )
  if parsed_flag(parsed, "exit_status") &&
    final_conclusion != "" &&
    final_conclusion != "success" {
    @github_cli.Output::from_bytes(
      output.stdout_bytes(),
      stderr=output.stderr(),
      exit_code=1,
    )
  } else {
    output
  }
}

///|
fn business_request(
  options : @github_cli.BusinessOptions,
  repository? : @github_cli.RepositoryContext,
) -> Result[BusinessRequest, @github_cli.Output] {
  match business_unknown_option(options) {
    Some(option) =>
      return Err(@github_cli.failure(message="unknown flag: " + option))
    None => ()
  }
  let parsed = parse_business(options)
  match business_validate_json_fields(parsed) {
    Ok(_) => ()
    Err(message) => return Err(@github_cli.failure(message~))
  }
  let command = options.command()
  let sub = parsed.subcommand
  let mut verb = "GET"
  let mut path : String? = None
  let mut query = []
  let headers : Array[(String, String)] = []
  let mut body : Bytes? = None
  let repo_required = business_needs_repository(options)
  let repo = match business_explicit_repository(command, parsed) {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(value) => Some(value)
        Err(_) =>
          return Err(
            @github_cli.failure(message="expected the [HOST/]OWNER/REPO format"),
          )
      }
    None => repository
  }
  let repo_path = match repo {
    Some(context) => "/repos/" + context.owner() + "/" + context.name()
    None => ""
  }
  // Projects V2 and Discussions do not have the REST endpoints used by the
  // historical command implementation. Build their read requests through
  // the GraphQL adapter before the generic REST switch selects a path.
  if command == "project" || command == "discussion" {
    return business_graphql_request(parsed, repo)
  }
  // Resolve additional v2.102.0 endpoint mappings before the primary switch.
  match business_extra_request(options, parsed, repo_path) {
    Ok(Some(request)) => return Ok(request)
    Err(error) => return Err(error)
    Ok(None) => ()
  }
  if command == "status" {
    path = Some("/notifications")
    query = business_query(parsed, ["all", "participating", "since", "before"])
    if parsed_flag(parsed, "all") {
      query.push(("all", "true"))
    }
    if parsed_flag(parsed, "participating") {
      query.push(("participating", "true"))
    }
  } else if command == "search" {
    let kind = match sub {
      "issues" | "prs" | "issues-and-prs" => "issues"
      "repos" | "repositories" => "repositories"
      "code" => "code"
      "commits" => "commits"
      _ =>
        return Err(
          @github_cli.failure(message="unsupported search command: " + sub),
        )
    }
    path = Some("/search/" + kind)
    let terms = business_search_terms(parsed, kind)
    guard !terms.is_empty() else {
      return Err(@github_cli.failure(message="search requires a query"))
    }
    // GitHub's `/search/issues` endpoint requires an explicit issue or pull
    // request qualifier.  gh's two command spellings make that distinction
    // explicit in `q`; without it GitHub returns HTTP 422 before searching.
    if kind == "issues" {
      if sub == "prs" {
        terms.push("is:pr")
      } else if sub == "issues" {
        terms.push("is:issue")
      }
    }
    query.push(("q", terms.join(" ")))
    // Search sort/order/per-page remain ordinary API parameters. Qualifiers
    // such as owner and language were folded into q above.
    query.append(business_query(parsed, ["sort", "order", "limit"]))
  } else if command == "org" {
    match sub {
      "list" => {
        path = Some("/user/orgs")
        query = business_query(parsed, ["limit", "per_page"])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported org command: " + sub),
        )
    }
  } else if command == "label" {
    match sub {
      "list" => {
        path = Some(repo_path + "/labels")
        query = business_query(parsed, ["search", "sort", "direction", "limit"])
      }
      "create" => {
        path = Some(repo_path + "/labels")
        verb = "POST"
        body = business_json_body(parsed, ["name", "description", "color"])
      }
      "delete" | "edit" => {
        guard parsed.positionals.get(0) is Some(name) else {
          return Err(@github_cli.failure(message="label name is required"))
        }
        let name = match business_segment(name) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/labels/" + name)
        if sub == "delete" {
          verb = "DELETE"
        }
        if sub == "edit" {
          verb = "PATCH"
          body = business_json_body(parsed, ["new_name", "color", "description"])
        }
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported label command: " + sub),
        )
    }
  } else if command == "workflow" || command == "actions" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/actions/workflows")
        query = business_query(parsed, ["limit", "per_page"])
      }
      "view" | "disable" | "enable" | "run" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="workflow is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/actions/workflows/" + identifier)
        if sub == "disable" {
          verb = "PUT"
          path = Some(path.unwrap() + "/disable")
        }
        if sub == "enable" {
          verb = "PUT"
          path = Some(path.unwrap() + "/enable")
        }
        if sub == "run" {
          verb = "POST"
          path = Some(path.unwrap() + "/dispatches")
          body = business_json_body(parsed, ["ref", "inputs"])
        }
      }
      _ =>
        return Err(
          @github_cli.failure(
            message="unsupported " + command + " command: " + sub,
          ),
        )
    }
  } else if command == "gist" {
    match sub {
      "list" => {
        path = Some("/gists")
        query = business_query(parsed, ["limit", "page"])
      }
      "view" | "edit" | "delete" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="gist ID is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some("/gists/" + identifier)
        if sub == "edit" {
          verb = "PATCH"
          body = business_json_body(parsed, ["description", "files"])
        }
        if sub == "delete" {
          verb = "DELETE"
        }
      }
      "create" => {
        path = Some("/gists")
        verb = "POST"
        body = business_json_body(parsed, ["description", "public", "files"])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported gist command: " + sub),
        )
    }
  } else if command == "gpg-key" || command == "ssh-key" {
    let resource = if command == "gpg-key" { "gpg_keys" } else { "keys" }
    match sub {
      "list" => path = Some("/user/" + resource)
      "add" => {
        path = Some("/user/" + resource)
        verb = "POST"
        body = business_json_body(parsed, ["armored_public_key", "title", "key"])
      }
      "delete" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="key ID is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some("/user/" + resource + "/" + identifier)
        verb = "DELETE"
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported key command: " + sub),
        )
    }
  } else if command == "secret" || command == "variable" {
    let resource = if command == "secret" { "secrets" } else { "variables" }
    let scoped_path = match parsed.values.get("org") {
      Some(org) => {
        let org = match business_segment(org) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        guard parsed.values.get("env") is None else {
          return Err(
            @github_cli.failure(message="--org cannot be combined with --env"),
          )
        }
        "/orgs/" + org + "/actions/" + resource
      }
      None =>
        match parsed.values.get("env") {
          Some(environment) => {
            guard !repo_path.is_empty() else {
              return Err(
                @github_cli.failure(
                  message="a repository is required for --env",
                ),
              )
            }
            let environment = match business_segment(environment) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            repo_path + "/environments/" + environment + "/" + resource
          }
          None => {
            guard !repo_path.is_empty() else {
              return Err(
                @github_cli.failure(message="a repository is required"),
              )
            }
            repo_path + "/actions/" + resource
          }
        }
    }
    match sub {
      "list" => {
        path = Some(scoped_path)
        query = business_query(parsed, ["limit", "per_page"])
      }
      "set" => {
        guard parsed.positionals.get(0) is Some(name) else {
          return Err(@github_cli.failure(message="name is required"))
        }
        let name = match business_segment(name) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(scoped_path + "/" + name)
        verb = "PUT"
        body = if command == "variable" {
          match business_string_body(parsed, "value") {
            Some(value) => Some(value)
            None =>
              return Err(
                @github_cli.failure(message="variable value is required"),
              )
          }
        } else {
          business_json_body(parsed, ["body", "value"])
        }
      }
      "delete" => {
        guard parsed.positionals.get(0) is Some(name) else {
          return Err(@github_cli.failure(message="name is required"))
        }
        let name = match business_segment(name) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(scoped_path + "/" + name)
        verb = "DELETE"
      }
      _ =>
        return Err(
          @github_cli.failure(
            message="unsupported " + command + " command: " + sub,
          ),
        )
    }
  } else if command == "cache" {
    match sub {
      "list" => {
        path = Some(repo_path + "/actions/caches")
        query = business_query(parsed, ["limit", "ref", "key"])
      }
      "delete" => {
        path = Some(repo_path + "/actions/caches")
        verb = "DELETE"
        query = business_query(parsed, ["key", "ref"])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported cache command: " + sub),
        )
    }
  } else if command == "ruleset" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/rulesets")
        query = business_query(parsed, [
          "limit", "per_page", "includes_parents", "inherited",
        ])
      }
      "view" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="ruleset ID is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/rulesets/" + identifier)
      }
      "check" => {
        guard parsed.positionals.get(0) is Some(reference) else {
          return Err(@github_cli.failure(message="branch or ref is required"))
        }
        let reference = match business_segment(reference) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/rulesets/rule-suites")
        query = [("ref", reference)]
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported ruleset command: " + sub),
        )
    }
  } else if command == "licenses" {
    path = Some("/licenses")
    guard sub == "list" || sub == "" else {
      return Err(
        @github_cli.failure(message="unsupported licenses command: " + sub),
      )
    }
  } else if command == "project" {
    let scope = match
      business_segment(parsed.values.get("owner").unwrap_or("user")) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match sub {
      "list" => {
        path = Some("/users/" + scope + "/projects")
        query = business_query(parsed, ["limit", "state"])
      }
      "view" | "delete" | "edit" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="project number is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some("/projects/" + identifier)
        if sub == "delete" {
          verb = "DELETE"
        }
        if sub == "edit" {
          verb = "PATCH"
          body = business_json_body(parsed, ["name", "body", "state"])
        }
      }
      "create" => {
        path = Some("/user/projects")
        verb = "POST"
        body = business_json_body(parsed, ["name", "body", "state"])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported project command: " + sub),
        )
    }
  } else if command == "browse" {
    let target = match repo {
      Some(context) => "https://" + context.host() + "/" + context.full_name()
      None => "https://github.com"
    }
    return Ok({
      verb: "GET",
      path: "/",
      query: [("browse", target)],
      headers: [],
      body: None,
      jq: None,
      template: None,
      json_fields: None,
      include_headers: false,
      silent: false,
      verbose: false,
    })
  } else if command == "repo" {
    match sub {
      "list" => {
        let owner = parsed.values.get("owner")
        path = Some(
          match owner {
            Some(owner) => {
              let owner = match business_segment(owner) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              "/orgs/" + owner + "/repos"
            }
            None => "/user/repos"
          },
        )
        query = business_query(parsed, [
          "visibility", "affiliation", "type", "sort", "direction", "per_page", "limit",
        ])
      }
      "create" => {
        path = Some(
          if parsed.values.get("org") is Some(org) {
            let org = match business_segment(org) {
              Ok(value) => value
              Err(error) => return Err(error)
            }
            "/orgs/" + org + "/repos"
          } else {
            "/user/repos"
          },
        )
        verb = "POST"
        body = business_json_body(parsed, [
          "name", "description", "homepage", "private", "has_issues", "has_projects",
          "has_wiki", "has_discussions", "is_template", "team_id", "auto_init", "gitignore_template",
          "license_template", "ssh_key",
        ])
      }
      "view" | "edit" | "delete" | "rename" | "sync" | "fork" | "clone" => {
        guard !repo_path.is_empty() else {
          return Err(@github_cli.failure(message="a repository is required"))
        }
        path = Some(repo_path)
        if sub == "edit" || sub == "rename" {
          verb = "PATCH"
          body = business_json_body(parsed, [
            "name", "description", "homepage", "private", "has_issues", "has_projects",
            "has_wiki", "has_discussions",
          ])
        }
        if sub == "delete" {
          verb = "DELETE"
        }
        if sub == "fork" {
          verb = "POST"
          path = Some(repo_path + "/forks")
          body = business_json_body(parsed, [
            "organization", "name", "default_branch_only",
          ])
        }
        if sub == "sync" {
          verb = "POST"
          path = Some(repo_path + "/merge-upstream")
          body = business_json_body(parsed, ["branch"])
        }
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported repo command: " + sub),
        )
    }
  } else if command == "issue" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/issues")
        query = business_query(parsed, [
          "state", "labels", "assignee", "creator", "milestone", "sort", "direction",
          "since", "per_page", "limit",
        ])
      }
      // `gh issue status` presents a repository's open issues grouped by
      // assignee.  The grouping is an output concern; the REST collection is
      // still the stable source of records and keeps this request fixture
      // compatible with GitHub installations that do not expose a bespoke
      // status endpoint.
      "status" => {
        path = Some(repo_path + "/issues")
        query = [("state", "open"), ("per_page", "100")]
      }
      "view"
      | "edit"
      | "close"
      | "reopen"
      | "delete"
      | "lock"
      | "unlock"
      | "transfer" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(@github_cli.failure(message="issue number is required"))
        }
        let number = match business_segment(number) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(repo_path + "/issues/" + number)
        if sub is ("edit" | "close" | "reopen") {
          verb = "PATCH"
          body = if sub == "close" {
            Some(
              business_state_body(parsed, "closed", [
                "title", "body", "assignee", "milestone", "labels", "state_reason",
              ]),
            )
          } else if sub == "reopen" {
            Some(
              business_state_body(parsed, "open", [
                "title", "body", "assignee", "milestone", "labels",
              ]),
            )
          } else {
            business_json_body(parsed, [
              "title", "body", "state", "assignee", "milestone", "labels",
            ])
          }
        }
        if sub == "delete" {
          verb = "DELETE"
        }
        if sub is ("lock" | "unlock") {
          verb = if sub == "lock" { "PUT" } else { "DELETE" }
          path = Some(path.unwrap() + "/lock")
          if sub == "lock" {
            body = business_json_body(parsed, ["lock_reason"])
          }
        }
        if sub == "transfer" {
          verb = "POST"
          path = Some(path.unwrap() + "/transfer")
          body = business_json_body(parsed, [
            "new_owner", "new_repo", "new_issue",
          ])
        }
      }
      "comment" | "comments" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(@github_cli.failure(message="issue number is required"))
        }
        let number = match business_segment(number) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(repo_path + "/issues/" + number + "/comments")
        if parsed.values.get("body") is Some(_) {
          verb = "POST"
          body = business_json_body(parsed, ["body"])
        } else {
          query = business_query(parsed, ["per_page", "limit"])
        }
      }
      "create" => {
        path = Some(repo_path + "/issues")
        verb = "POST"
        body = business_json_body(parsed, [
          "title", "body", "assignee", "milestone", "labels", "type",
        ])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported issue command: " + sub),
        )
    }
  } else if command == "pr" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/pulls")
        query = business_query(parsed, [
          "state", "head", "base", "sort", "direction", "per_page", "limit",
        ])
      }
      "view"
      | "edit"
      | "close"
      | "reopen"
      | "ready"
      | "lock"
      | "unlock"
      | "merge" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(repo_path + "/pulls/" + number)
        if sub is ("edit" | "close" | "reopen") {
          verb = "PATCH"
          body = if sub == "close" {
            Some(
              business_state_body(parsed, "closed", [
                "title", "body", "base", "maintainer_can_modify",
              ]),
            )
          } else if sub == "reopen" {
            Some(
              business_state_body(parsed, "open", [
                "title", "body", "base", "maintainer_can_modify",
              ]),
            )
          } else {
            business_json_body(parsed, [
              "title", "body", "state", "base", "maintainer_can_modify",
            ])
          }
        }
        if sub == "ready" {
          verb = "PATCH"
          body = Some(
            business_boolean_body(parsed, "draft", false, [
              "title", "body", "base", "maintainer_can_modify",
            ]),
          )
        }
        if sub == "merge" {
          verb = "PUT"
          path = Some(path.unwrap() + "/merge")
          body = business_json_body(parsed, [
            "commit_title", "commit_message", "sha", "merge_method",
          ])
        }
        if sub is ("lock" | "unlock") {
          verb = if sub == "lock" { "PUT" } else { "DELETE" }
          path = Some(path.unwrap() + "/lock")
          if sub == "lock" {
            body = business_json_body(parsed, ["lock_reason"])
          }
        }
      }
      "create" => {
        path = Some(repo_path + "/pulls")
        verb = "POST"
        body = business_json_body(parsed, [
          "title", "body", "head", "base", "maintainer_can_modify", "draft",
        ])
      }
      "checks" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let reference = parsed.values.get("ref").unwrap_or(number)
        let number = match business_segment(reference) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/commits/" + number + "/check-runs")
      }
      "review" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/pulls/" + number + "/reviews")
        verb = "POST"
        let event = if parsed_flag(parsed, "approve") {
          "APPROVE"
        } else if parsed_flag(parsed, "request_changes") {
          "REQUEST_CHANGES"
        } else {
          "COMMENT"
        }
        let review_body : Map[String, Json] = Map([])
        review_body["event"] = Json::string(event)
        match parsed.values.get("body") {
          Some(value) => review_body["body"] = @github_cli.typed_field(value)
          None => ()
        }
        body = Some(@utf8.encode(Json::object(review_body).stringify()))
      }
      "comment" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/issues/" + number + "/comments")
        verb = "POST"
        body = business_json_body(parsed, ["body"])
      }
      "status" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/pulls/" + number)
        headers.push(("Accept", "application/vnd.github.raw+json"))
      }
      "diff" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="pull request number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/pulls/" + number)
        // Pull request diffs are selected by media type. A query parameter
        // named `diff` is ignored by GitHub and returns JSON metadata.
        headers.push(("Accept", "application/vnd.github.diff"))
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported pr command: " + sub),
        )
    }
  } else if command == "discussion" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/discussions")
        query = business_query(parsed, [
          "category", "answered", "order", "direction", "per_page", "limit",
        ])
      }
      "view" | "edit" | "close" | "reopen" | "delete" => {
        guard parsed.positionals.get(0) is Some(number) else {
          return Err(
            @github_cli.failure(message="discussion number is required"),
          )
        }
        let number = match business_segment(number) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(repo_path + "/discussions/" + number)
        if sub is ("edit" | "close" | "reopen") {
          verb = "PATCH"
          body = business_json_body(parsed, [
            "title", "body", "category", "state",
          ])
        }
        if sub == "delete" {
          verb = "DELETE"
        }
      }
      "create" => {
        path = Some(repo_path + "/discussions")
        verb = "POST"
        body = business_json_body(parsed, ["title", "body", "category"])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported discussion command: " + sub),
        )
    }
  } else if command == "release" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/releases")
        query = business_query(parsed, ["per_page", "limit"])
      }
      "view" | "edit" | "delete" | "download" | "upload" => {
        guard parsed.positionals.get(0) is Some(tag) else {
          return Err(@github_cli.failure(message="release tag is required"))
        }
        let tag = match business_segment(tag) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(
          if tag == "latest" {
            repo_path + "/releases/latest"
          } else {
            repo_path + "/releases/tags/" + tag
          },
        )
        if sub == "edit" {
          // Resolve the tag first; the write endpoint requires the numeric
          // release id and is issued by execute_release_edit_delete.
          body = business_json_body(parsed, [
            "tag_name", "target_commitish", "name", "body", "draft", "prerelease",
            "make_latest",
          ])
        }
      }
      "delete-asset" => {
        guard parsed.positionals.get(0) is Some(identifier) else {
          return Err(@github_cli.failure(message="asset ID is required"))
        }
        let identifier = match business_segment(identifier) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        path = Some(repo_path + "/releases/assets/" + identifier)
        verb = "DELETE"
      }
      "create" => {
        path = Some(repo_path + "/releases")
        verb = "POST"
        body = business_json_body(parsed, [
          "tag_name", "target_commitish", "name", "body", "draft", "prerelease",
          "generate_release_notes", "discussion_category_name",
        ])
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported release command: " + sub),
        )
    }
  } else if command == "run" {
    guard !repo_path.is_empty() else {
      return Err(@github_cli.failure(message="a repository is required"))
    }
    match sub {
      "list" => {
        path = Some(repo_path + "/actions/runs")
        query = business_query(parsed, [
          "actor", "branch", "event", "status", "workflow_id", "created", "exclude_pull_requests",
          "check_suite_id", "per_page", "limit",
        ])
      }
      "view"
      | "cancel"
      | "rerun"
      | "rerun-failed"
      | "delete"
      | "watch"
      | "download" => {
        guard parsed.positionals.get(0) is Some(id) else {
          return Err(@github_cli.failure(message="workflow run ID is required"))
        }
        let id = match business_segment(id) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        path = Some(repo_path + "/actions/runs/" + id)
        if sub == "download" {
          // The run download command resolves artifacts through this
          // collection endpoint. Native extraction of zip entries remains a
          // process concern, while the SDK preserves the binary body.
          path = Some(path.unwrap() + "/artifacts")
        }
        if sub == "view" &&
          (parsed_flag(parsed, "log") || parsed_flag(parsed, "log_failed")) {
          path = Some(path.unwrap() + "/logs")
        }
        if sub == "cancel" {
          verb = "POST"
          path = Some(path.unwrap() + "/cancel")
        }
        if sub == "rerun" {
          verb = "POST"
          path = Some(path.unwrap() + "/rerun")
          body = business_json_body(parsed, [
            "enable_debug_logging", "enable_step_debug_logging",
          ])
        }
        if sub == "rerun-failed" {
          verb = "POST"
          path = Some(path.unwrap() + "/rerun-failed-jobs")
        }
        if sub == "delete" {
          verb = "DELETE"
        }
      }
      _ =>
        return Err(
          @github_cli.failure(message="unsupported run command: " + sub),
        )
    }
  } else {
    return Err(@github_cli.failure(message="unsupported command: " + command))
  }
  guard path is Some(path) else {
    return Err(@github_cli.failure(message="could not build command request"))
  }
  if repo_required && repo is None {
    return Err(@github_cli.failure(message="a repository is required"))
  }
  let jq = match parsed.jq {
    Some(value) => Some(value)
    None => None
  }
  Ok({
    verb,
    path,
    query,
    headers,
    body,
    jq,
    template: parsed.template,
    json_fields: parsed.json_fields,
    include_headers: parsed_flag(parsed, "include"),
    silent: parsed_flag(parsed, "silent"),
    verbose: parsed_flag(parsed, "verbose"),
  })
}

///|
/// Credential-free business command seam. Tests inject a transport and assert
/// the exact REST method, path, query, and body without contacting GitHub.
pub async fn execute_github_business(
  options : @github_cli.BusinessOptions,
  client~ : @github.Client,
  base_url~ : String,
  repository? : @github_cli.RepositoryContext,
) -> @github_cli.Output {
  // Keep the configured origin explicit in the fixture seam even though the
  // Client owns URL preparation and the injected transport only sees paths.
  ignore(base_url)
  let request = match business_request(options, repository?) {
    Ok(value) => value
    Err(error) => return error
  }
  let parsed = parse_business(options)
  if options.command() == "secret" && parsed.subcommand == "set" {
    return execute_secret_set(parsed, request, client, repository?)
  }
  if options.command() == "issue" && parsed.subcommand == "delete" {
    return execute_issue_delete(parsed, repository, client)
  }
  if options.command() == "run" && parsed.subcommand == "watch" {
    return execute_run_watch(parsed, request, client)
  }
  let graphql_limit = business_requested_limit(parsed)
  let (response, paged_body) = match
    (if request.path == "/graphql" &&
      (parsed.command == "project" || parsed.command == "discussion") &&
      parsed.subcommand == "list" &&
      graphql_limit is Some(limit) &&
      limit > 100 {
      execute_business_graphql_collection(
        parsed,
        request,
        client,
        graphql_limit.unwrap(),
      )
    } else {
      execute_business_collection(parsed, request, client, base_url)
    }) {
    Ok(value) => value
    Err(error) => return error
  }
  if options.command() == "release" && parsed.subcommand is ("edit" | "delete") {
    return execute_release_edit_delete(
      options, parsed, request, response, client, repository,
    )
  }
  if options.command() == "release" && parsed.subcommand == "download" {
    return execute_release_download(
      options, parsed, request, response, client, repository,
    )
  }
  if options.command() == "release" && parsed.subcommand == "upload" {
    return execute_release_upload(
      options, parsed, request, response, client, repository,
    )
  }
  let response_body = match paged_body {
    Some(body) => body
    None if response.status() >= 200 &&
      response.status() < 300 &&
      (options.command() == "workflow" || options.command() == "actions") &&
      parsed.subcommand == "list" => {
      let include_disabled = match parsed.values.get("all") {
        Some("true") => true
        Some("false") => false
        _ => parsed_flag(parsed, "all") || parsed_flag(parsed, "a")
      }
      match business_workflow_list_body(response.body(), include_disabled) {
        Ok(Some(body)) => body
        Ok(None) => return @github_cli.Output::new()
        Err(_) =>
          return @github_cli.failure(message="response is not valid JSON")
      }
    }
    None if request.path == "/graphql" &&
      (parsed.command == "project" || parsed.command == "discussion") =>
      match business_graphql_data(parsed, response.body()) {
        Ok(value) => value
        Err(error) => return error
      }
    None => response.body()
  }
  let body = match request.json_fields {
    Some(fields) =>
      if response.status() >= 200 && response.status() < 300 {
        match
          business_project_response(
            response_body,
            fields,
            repository_view=options.command() == "repo" &&
              parsed.subcommand == "view",
            state_upper=options.command() == "issue" ||
              options.command() == "pr",
            pull_request=options.command() == "pr",
            envelope_key?=if options.command() == "run" &&
              parsed.subcommand == "list" {
              Some("workflow_runs")
            } else if (
                options.command() == "workflow" ||
                options.command() == "actions"
              ) &&
              parsed.subcommand == "list" {
              Some("workflows")
            } else if options.command() == "issue" &&
              parsed.subcommand == "list" {
              Some("issues")
            } else if options.command() == "pr" && parsed.subcommand == "list" {
              Some("pulls")
            } else if options.command() == "release" &&
              parsed.subcommand == "list" {
              Some("releases")
            } else if options.command() == "repo" && parsed.subcommand == "list" {
              Some("repositories")
            } else if options.command() == "org" && parsed.subcommand == "list" {
              Some("organizations")
            } else if options.command() == "label" &&
              parsed.subcommand == "list" {
              Some("labels")
            } else if (
                options.command() == "secret" || options.command() == "variable"
              ) &&
              parsed.subcommand == "list" {
              Some(
                if options.command() == "secret" {
                  "secrets"
                } else {
                  "variables"
                },
              )
            } else if options.command() == "cache" &&
              parsed.subcommand == "list" {
              Some("actions_caches")
            } else if options.command() == "search" {
              Some("items")
            } else {
              None
            },
          ) {
          Ok(value) => value
          Err(_) =>
            return @github_cli.failure(message="response is not valid JSON")
        }
      } else {
        response_body
      }
    None => response_body
  }
  @github_cli.render_response(
    response.status(),
    response.headers(),
    body,
    jq?=request.jq,
    template?=request.template,
    include_headers=request.include_headers,
    silent=request.silent,
    verbose=request.verbose,
  )
}
