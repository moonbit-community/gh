///|
/// Command plans. The historical ReadCommand name is retained for source
/// compatibility; mutation variants were added in Increment 3.
pub enum ReadCommand {
  Api(@gh.HttpMethod, String, Array[(String, String)])
  Meta
  CurrentUser
  Repositories
  Repository(@moonhub.RepositoryRef)
  Issues(@moonhub.RepositoryRef)
  Issue(@moonhub.RepositoryRef, Int)
  MergeRequests(@moonhub.RepositoryRef)
  MergeRequest(@moonhub.RepositoryRef, Int)
  Pipelines(@moonhub.RepositoryRef)
  Pipeline(@moonhub.RepositoryRef, String)
  CancelPipeline(@moonhub.RepositoryRef, String, @moonhub.EntityTag)
  RerunPipeline(@moonhub.RepositoryRef, String, @moonhub.EntityTag)
  CreateIssue(@moonhub.RepositoryRef, String)
  CommentIssue(@moonhub.RepositoryRef, Int)
  CloseIssue(@moonhub.RepositoryRef, Int, @moonhub.EntityTag)
  ReopenIssue(@moonhub.RepositoryRef, Int, @moonhub.EntityTag)
  CreateMergeRequest(@moonhub.RepositoryRef, String, String, String, Bool)
  CommentMergeRequest(@moonhub.RepositoryRef, Int, @moonhub.EntityTag)
  MergeMergeRequest(@moonhub.RepositoryRef, Int, @moonhub.EntityTag)
}

///|
/// Body sources are resolved explicitly by the native boundary. Parsing and
/// command execution do not read files or standard input.
pub enum BodyInput {
  Literal(String)
  File(String)
  Stdin
}

///|
/// Parsed command policy. Parsing performs no environment, filesystem, or
/// network access; callers explicitly supply the supported environment values.
pub struct RunOptions {
  command : ReadCommand
  base_url : String
  config_path : String?
  trace_path : String?
  json : Bool
  page : Int
  per_page : Int
  paginate : Bool
  max_pages : Int
  max_attempts : Int
  body_input : BodyInput?
}

///|
pub fn RunOptions::is_mutation(self : RunOptions) -> Bool {
  match self.command {
    Api(verb, _, _) => !(verb is @gh.Get)
    CreateIssue(_, _)
    | CommentIssue(_, _)
    | CloseIssue(_, _, _)
    | ReopenIssue(_, _, _)
    | CreateMergeRequest(_, _, _, _, _)
    | CommentMergeRequest(_, _, _)
    | MergeMergeRequest(_, _, _)
    | CancelPipeline(_, _, _)
    | RerunPipeline(_, _, _) => true
    _ => false
  }
}

///|
pub enum Invocation {
  Help(String)
  Version
  Run(RunOptions)
  Trace(TraceOptions)
}

///|
fn command(
  name : String,
  options? : Array[@argparse.OptionArg] = [],
  flags? : Array[@argparse.FlagArg] = [],
  positionals? : Array[@argparse.PositionArg] = [],
  subcommands? : Array[@argparse.Command] = [],
  about? : String = "",
) -> @argparse.Command {
  @argparse.Command(
    // Upstream's built-in help/version actions terminate the process. Ordinary
    // flags let this library return an Invocation without writing or exiting.
    name,
    options~,
    flags~,
    positionals~,
    subcommands~,
    about~,
    disable_help_flag=true,
    disable_version_flag=true,
    disable_help_subcommand=true,
  )
}

///|
fn list_command() -> @argparse.Command {
  command(
    "list",
    about="List visible resources",
    options=[
      @argparse.OptionArg(
        "page",
        default_values=["1"],
        about="Page number (1..1000000)",
      ),
      @argparse.OptionArg(
        "per-page",
        default_values=["30"],
        about="Page size (1..100)",
      ),
      @argparse.OptionArg(
        "max-pages",
        default_values=["20"],
        about="Maximum pages with --paginate (1..100)",
      ),
    ],
    flags=[@argparse.FlagArg("paginate", about="Follow bounded next links")],
  )
}

///|
fn resource_group(name : String, about : String) -> @argparse.Command {
  let subcommands = [
    list_command(),
    command("view", about="View one resource", positionals=[
      @argparse.PositionArg(
        "number",
        num_args=@argparse.ValueRange(lower=0, upper=1),
      ),
    ]),
  ]
  let creation_options = body_options() +
    [@argparse.OptionArg("title", about="Required resource title")]
  if name == "pr" {
    creation_options.push(
      @argparse.OptionArg("source", about="Required source branch"),
    )
    creation_options.push(
      @argparse.OptionArg("target", about="Required target branch"),
    )
  }
  subcommands.push(
    command(
      "create",
      about="Create a resource without prompting",
      options=creation_options,
      flags=if name == "pr" {
        [@argparse.FlagArg("draft", about="Create a draft merge request")]
      } else {
        []
      },
    ),
  )
  subcommands.push(
    command(
      "comment",
      about="Add a comment",
      options=body_options() +
        (if name == "pr" { [if_match_option()] } else { [] }),
      positionals=[number_argument()],
    ),
  )
  let actions = if name == "issue" { ["close", "reopen"] } else { ["merge"] }
  for action in actions {
    subcommands.push(
      command(action, options=[if_match_option()], positionals=[
        number_argument(),
      ]),
    )
  }
  command(name, about~, subcommands~)
}

///|
fn body_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg("body", about="Resource description or comment text"),
    @argparse.OptionArg(
      "body-file",
      about="Read UTF-8 body from PATH; - reads stdin",
    ),
  ]
}

///|
fn if_match_option() -> @argparse.OptionArg {
  @argparse.OptionArg(
    "if-match",
    about="Required strong ETag from a preceding view",
  )
}

///|
fn number_argument() -> @argparse.PositionArg {
  @argparse.PositionArg(
    "number",
    num_args=@argparse.ValueRange(lower=0, upper=1),
  )
}

///|
fn command_spec() -> @argparse.Command {
  command(
    "gh",
    about="MoonHub command-line client",
    flags=[
      @argparse.FlagArg(
        "help",
        short='h',
        global=true,
        about="Show command help",
      ),
      @argparse.FlagArg("version", global=true, about="Show client version"),
      @argparse.FlagArg(
        "json",
        global=true,
        about="Print stable versioned JSON",
      ),
    ],
    options=[
      @argparse.OptionArg(
        "host",
        global=true,
        env="MOONHUB_HOST",
        about="MoonHub origin including scheme",
      ),
      @argparse.OptionArg(
        "repo",
        short='R',
        global=true,
        about="Repository OWNER/NAME (fallback: MOONHUB_REPO)",
      ),
      @argparse.OptionArg(
        "config",
        global=true,
        about="Explicit token configuration file",
      ),
      @argparse.OptionArg(
        "trace",
        global=true,
        about="Request trace output, or input file for trace commands",
      ),
      @argparse.OptionArg(
        "max-attempts",
        global=true,
        about="GET attempts per page, 1..5 (default 3); writes always once",
      ),
    ],
    subcommands=[
      api_command_spec(),
      command("meta", about="Read server version and capabilities"),
      command("auth", about="Inspect authentication", subcommands=[
        command("status", about="Read the current authenticated user"),
      ]),
      command("repo", about="Inspect repositories", subcommands=[
        list_command(),
        command("view", about="View a repository", positionals=[
          @argparse.PositionArg(
            "repository",
            num_args=@argparse.ValueRange(lower=0, upper=1),
          ),
        ]),
      ]),
      resource_group("issue", "Inspect issues"),
      resource_group("pr", "Inspect MoonHub merge requests"),
      pipeline_group(),
      trace_group(),
    ],
  )
}

///|
fn value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some([item]) => Some(item)
    _ => None
  }
}

///|
fn positive_int(value : String, maximum : Int) -> Int? {
  guard !value.is_empty() && value.iter().all(ch => ch is ('0'..='9')) else {
    return None
  }
  let number = @string.parse_int(value) catch { _ => return None }
  if number >= 1 && number <= maximum {
    Some(number)
  } else {
    None
  }
}

///|
/// Parse arguments excluding argv[0]. Invalid arguments are never echoed: a
/// mistaken token option must not copy its value into logs or diagnostics.
pub fn parse(
  args : Array[String],
  host_env? : String,
  repo_env? : String,
) -> Result[Invocation, String] {
  let environment : Map[String, String] = Map([])
  if host_env is Some(host) {
    environment["MOONHUB_HOST"] = host
  }
  let matches = command_spec().parse(argv=args, env=environment) catch {
    _ => return Err("invalid command or arguments; run gh --help")
  }
  if matches.flags.get("help") == Some(true) || args.is_empty() {
    return Ok(Help(help_text()))
  }
  if matches.flags.get("version") == Some(true) {
    return Ok(Version)
  }
  guard matches.subcommand is Some((group, group_matches)) else {
    return Err("a command is required; run gh --help")
  }
  let (action, leaf) = if group == "meta" || group == "api" {
    (group, group_matches)
  } else {
    match group_matches.subcommand {
      Some(pair) => pair
      None => return Ok(Help(help_text()))
    }
  }
  if group == "trace" {
    return parse_trace(matches, leaf, action)
  }
  guard value(matches, "host") is Some(host) else {
    return Err("MoonHub origin is required: use --host or MOONHUB_HOST")
  }
  let base_url = match @gh.normalize_origin(host) {
    Ok(origin) => origin
    Err(_) => return Err("invalid MoonHub origin; use HTTPS or loopback HTTP")
  }
  let config_path = value(matches, "config")
  let trace_path = value(matches, "trace")
  if config_path is Some("") || trace_path is Some("") {
    return Err("configuration and trace paths must not be empty")
  }
  if group == "api" {
    return parse_api(matches, leaf, base_url, config_path, trace_path)
  }
  guard positive_int(value(matches, "max-attempts").unwrap_or("3"), 5)
    is Some(max_attempts) else {
    return Err("--max-attempts must be an integer from 1 to 5")
  }
  let is_list = action == "list"
  let body_input = match (value(leaf, "body"), value(leaf, "body-file")) {
    (Some(_), Some(_)) =>
      return Err("--body and --body-file are mutually exclusive")
    (Some(text), None) => Some(Literal(text))
    (None, Some("")) => return Err("--body-file requires a nonempty path or -")
    (None, Some("-")) => Some(Stdin)
    (None, Some(path)) => Some(File(path))
    _ => None
  }
  if action == "comment" {
    match body_input {
      None => return Err("comment requires --body or --body-file")
      Some(Literal(text)) if text.trim().is_empty() =>
        return Err("comment body must not be empty")
      _ => ()
    }
  }
  let mut page = 1
  let mut per_page = 30
  let mut max_pages = 20
  if is_list {
    guard positive_int(value(leaf, "page").unwrap_or("1"), 1000000)
      is Some(parsed_page) else {
      return Err("--page must be an integer from 1 to 1000000")
    }
    guard positive_int(value(leaf, "per-page").unwrap_or("30"), 100)
      is Some(parsed_size) else {
      return Err("--per-page must be an integer from 1 to 100")
    }
    guard positive_int(value(leaf, "max-pages").unwrap_or("20"), 100)
      is Some(parsed_max) else {
      return Err("--max-pages must be an integer from 1 to 100")
    }
    page = parsed_page
    per_page = parsed_size
    max_pages = parsed_max
  }
  let command = match (group, action) {
    ("meta", "meta") => Meta
    ("auth", "status") => CurrentUser
    ("repo", "list") => Repositories
    _ => {
      let explicit = value(matches, "repo")
      let positional = value(leaf, "repository")
      if explicit is Some(a) && positional is Some(b) && a != b {
        return Err("repository positional argument conflicts with --repo")
      }
      let selected = match (positional, explicit) {
        (Some(repository), _) | (_, Some(repository)) => Some(repository)
        _ => repo_env
      }
      guard selected is Some(selected) else {
        return Err(
          "repository is required: use --repo OWNER/NAME or MOONHUB_REPO",
        )
      }
      let repo = match @moonhub.RepositoryRef::parse(selected) {
        Ok(repo) => repo
        Err(_) => return Err("repository must be a valid OWNER/NAME")
      }
      match (group, action) {
        ("repo", "view") => Repository(repo)
        ("issue", "list") => Issues(repo)
        ("pr", "list") => MergeRequests(repo)
        ("pipeline", "list") => Pipelines(repo)
        ("pipeline", _) =>
          match pipeline_command(action, leaf, repo) {
            Ok(command) => command
            Err(message) => return Err(message)
          }
        ("issue", _) | ("pr", _) =>
          match resource_command(group, action, leaf, repo) {
            Ok(command) => command
            Err(message) => return Err(message)
          }
        _ => return Err("unsupported command; run gh --help")
      }
    }
  }
  Ok(
    Run({
      command,
      base_url,
      config_path,
      trace_path,
      json: matches.flags.get("json") == Some(true),
      page,
      per_page,
      max_pages,
      max_attempts,
      body_input,
      paginate: leaf.flags.get("paginate") == Some(true),
    }),
  )
}

///|
fn resource_command(
  group : String,
  action : String,
  leaf : @argparse.Matches,
  repo : @moonhub.RepositoryRef,
) -> Result[ReadCommand, String] {
  if action == "create" {
    guard value(leaf, "title") is Some(title) && !title.trim().is_empty() else {
      return Err("create requires a nonempty --title")
    }
    if group == "issue" {
      return Ok(CreateIssue(repo, title))
    }
    guard value(leaf, "source") is Some(source) &&
      !source.trim().is_empty() &&
      value(leaf, "target") is Some(target) &&
      !target.trim().is_empty() else {
      return Err("pr create requires nonempty --source and --target branches")
    }
    return Ok(
      CreateMergeRequest(
        repo,
        title,
        source,
        target,
        leaf.flags.get("draft") == Some(true),
      ),
    )
  }
  guard value(leaf, "number") is Some(raw_number) &&
    positive_int(raw_number, 2147483647) is Some(number) else {
    return Err("command requires a positive resource number (1..2147483647)")
  }
  if action == "view" {
    return Ok(
      if group == "issue" {
        Issue(repo, number)
      } else {
        MergeRequest(repo, number)
      },
    )
  }
  if group == "issue" && action == "comment" {
    return Ok(CommentIssue(repo, number))
  }
  guard value(leaf, "if-match") is Some(raw_tag) else {
    return Err(
      "command requires --if-match with a strong ETag from a preceding view",
    )
  }
  let tag = match @moonhub.EntityTag::parse(raw_tag) {
    Ok(tag) => tag
    Err(_) =>
      return Err(
        "--if-match must be one strong ETag; weak tags and wildcards are not accepted",
      )
  }
  match (group, action) {
    ("issue", "close") => Ok(CloseIssue(repo, number, tag))
    ("issue", "reopen") => Ok(ReopenIssue(repo, number, tag))
    ("pr", "comment") => Ok(CommentMergeRequest(repo, number, tag))
    ("pr", "merge") => Ok(MergeMergeRequest(repo, number, tag))
    _ => Err("unsupported command; run gh --help")
  }
}
