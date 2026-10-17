///|
/// A parsed GitHub CLI invocation. Parsing has no I/O; the native runner owns
/// credentials, stdin, files, git and the network.
pub enum Invocation {
  Help
  HelpTopic(String)
  Version
  Completion(shell~ : String?)
  Config(Array[String])
  Alias(Array[String])
  Auth(Array[String])
  Api(ApiOptions)
  /// A core command invocation. Command-specific parsing intentionally lives
  /// at the native boundary so the pure parser remains I/O free and can be
  /// reused by fixture tests.
  Business(BusinessOptions)
  Unsupported(String)
}

///|
pub struct BusinessOptions {
  command : String
  args : Array[String]
}

///|
pub fn BusinessOptions::command(self : BusinessOptions) -> String {
  self.command
}

///|
pub fn BusinessOptions::args(self : BusinessOptions) -> Array[String] {
  self.args.copy()
}

///|
pub suberror ParseError {
  MissingValue(String)
  InvalidValue(String)
  UnknownOption(String)
  UnexpectedArgument(String)
}

///|
pub struct ApiOptions {
  path : String
  verb : String
  explicit_method : Bool
  hostname : String?
  headers : Array[(String, String)]
  raw_fields : Array[(String, String)]
  json_fields : Array[(String, String)]
  input : String?
  jq : String?
  template : String?
  paginate : Bool
  slurp : Bool
  show_headers : Bool
  silent : Bool
  verbose : Bool
  allow_escape_sequences : Bool
  cache : String?
  previews : Array[String]
  empty_arrays : Array[String]
}

///|
pub fn ApiOptions::path(self : ApiOptions) -> String {
  self.path
}

///|
pub fn ApiOptions::verb(self : ApiOptions) -> String {
  self.verb
}

///|
pub fn ApiOptions::hostname(self : ApiOptions) -> String? {
  self.hostname
}

///|
pub fn ApiOptions::headers(self : ApiOptions) -> Array[(String, String)] {
  self.headers.copy()
}

///|
pub fn ApiOptions::raw_fields(self : ApiOptions) -> Array[(String, String)] {
  self.raw_fields.copy()
}

///|
pub fn ApiOptions::json_fields(self : ApiOptions) -> Array[(String, String)] {
  self.json_fields.copy()
}

///|
pub fn ApiOptions::input(self : ApiOptions) -> String? {
  self.input
}

///|
pub fn ApiOptions::jq(self : ApiOptions) -> String? {
  self.jq
}

///|
pub fn ApiOptions::template(self : ApiOptions) -> String? {
  self.template
}

///|
pub fn ApiOptions::paginate(self : ApiOptions) -> Bool {
  self.paginate
}

///|
pub fn ApiOptions::slurp(self : ApiOptions) -> Bool {
  self.slurp
}

///|
pub fn ApiOptions::show_headers(self : ApiOptions) -> Bool {
  self.show_headers
}

///|
pub fn ApiOptions::silent(self : ApiOptions) -> Bool {
  self.silent
}

///|
pub fn ApiOptions::verbose(self : ApiOptions) -> Bool {
  self.verbose
}

///|
pub fn ApiOptions::allow_escape_sequences(self : ApiOptions) -> Bool {
  self.allow_escape_sequences
}

///|
pub fn ApiOptions::cache(self : ApiOptions) -> String? {
  self.cache
}

///|
pub fn ApiOptions::previews(self : ApiOptions) -> Array[String] {
  self.previews.copy()
}

///|
pub fn ApiOptions::empty_arrays(self : ApiOptions) -> Array[String] {
  self.empty_arrays.copy()
}

///|
fn required_value(
  args : Array[String],
  index : Int32,
  option : String,
) -> (String, Int32) raise ParseError {
  guard index + 1 < args.length() else { raise MissingValue(option) }
  let value = args[index + 1]
  guard !value.is_empty() else { raise MissingValue(option) }
  (value, index + 1)
}

///|
fn option_value(
  args : Array[String],
  index : Int32,
  option : String,
  attached : String?,
) -> (String, Int32) raise ParseError {
  match attached {
    Some(value) if !value.is_empty() => (value, index)
    Some(_) => raise MissingValue(option)
    None => required_value(args, index, option)
  }
}

///|
fn split_header(value : String) -> (String, String) raise ParseError {
  match value.split_once(":") {
    Some((name, header_value)) => {
      let name = name.trim()
      guard !name.is_empty() else { raise InvalidValue("empty header name") }
      (name.to_owned(), header_value.trim().to_owned())
    }
    None => raise InvalidValue("header must be NAME: VALUE")
  }
}

///|
fn split_field(value : String) -> (String, String) raise ParseError {
  match value.split_once("=") {
    Some((name, field_value)) => {
      guard !name.is_empty() else { raise InvalidValue("empty field name") }
      (name.to_owned(), field_value.to_owned())
    }
    None => raise InvalidValue("field must be NAME=VALUE")
  }
}

///|
fn parse_api(args : Array[String]) -> Invocation raise ParseError {
  let mut path : String? = None
  let mut verb = "GET"
  let mut explicit_method = false
  let mut hostname : String? = None
  let headers : Array[(String, String)] = []
  let raw_fields : Array[(String, String)] = []
  let json_fields : Array[(String, String)] = []
  let mut input : String? = None
  let mut jq : String? = None
  let mut template : String? = None
  let mut paginate = false
  let mut slurp = false
  let mut show_headers = false
  let mut silent = false
  let mut verbose = false
  let mut allow_escape_sequences = false
  let mut cache : String? = None
  let previews : Array[String] = []
  let empty_arrays : Array[String] = []
  let mut end_options = false
  let mut index = 0
  while index < args.length() {
    let argument = args[index]
    if end_options {
      if path is None {
        path = Some(argument)
      } else {
        raise UnexpectedArgument(argument)
      }
    } else if argument == "--" {
      end_options = true
    } else if argument == "--help" || argument == "-h" {
      return HelpTopic("api")
    } else if argument == "--paginate" {
      paginate = true
    } else if argument == "--slurp" {
      slurp = true
    } else if argument == "--include" || argument == "-i" {
      show_headers = true
    } else if argument == "--silent" {
      silent = true
    } else if argument == "--verbose" {
      verbose = true
    } else if argument == "--allow-escape-sequences" {
      allow_escape_sequences = true
    } else if argument == "--method" || argument == "-X" {
      let (value, next) = required_value(args, index, argument)
      verb = value.to_upper()
      explicit_method = true
      index = next
    } else if argument.has_prefix("-X") && argument.length() > 2 {
      verb = argument[2:].to_owned().to_upper()
      explicit_method = true
    } else if argument.has_prefix("--method=") {
      let (value, next) = option_value(
        args,
        index,
        "--method",
        Some(argument[9:].to_owned()),
      )
      verb = value.to_upper()
      explicit_method = true
      index = next
    } else if argument == "--hostname" {
      let (value, next) = required_value(args, index, argument)
      hostname = Some(value)
      index = next
    } else if argument.has_prefix("--hostname=") {
      let (value, next) = option_value(
        args,
        index,
        "--hostname",
        Some(argument[11:].to_owned()),
      )
      hostname = Some(value)
      index = next
    } else if argument == "--input" {
      let (value, next) = required_value(args, index, argument)
      input = Some(value)
      index = next
    } else if argument.has_prefix("--input=") {
      let (value, next) = option_value(
        args,
        index,
        "--input",
        Some(argument[8:].to_owned()),
      )
      input = Some(value)
      index = next
    } else if argument == "--jq" || argument == "-q" {
      let (value, next) = required_value(args, index, argument)
      jq = Some(value)
      index = next
    } else if argument.has_prefix("--jq=") {
      let (value, next) = option_value(
        args,
        index,
        "--jq",
        Some(argument[5:].to_owned()),
      )
      jq = Some(value)
      index = next
    } else if argument == "--template" || argument == "-t" {
      let (value, next) = required_value(args, index, argument)
      template = Some(value)
      index = next
    } else if argument.has_prefix("--template=") {
      let (value, next) = option_value(
        args,
        index,
        "--template",
        Some(argument[10:].to_owned()),
      )
      template = Some(value)
      index = next
    } else if argument == "--cache" {
      let (value, next) = required_value(args, index, argument)
      cache = Some(value)
      index = next
    } else if argument.has_prefix("--cache=") {
      let (value, next) = option_value(
        args,
        index,
        "--cache",
        Some(argument[8:].to_owned()),
      )
      cache = Some(value)
      index = next
    } else if argument == "--preview" || argument == "-p" {
      let (value, next) = required_value(args, index, argument)
      previews.push(value)
      index = next
    } else if argument.has_prefix("--preview=") {
      let (value, next) = option_value(
        args,
        index,
        "--preview",
        Some(argument[10:].to_owned()),
      )
      previews.push(value)
      index = next
    } else if argument == "--header" || argument == "-H" {
      let (value, next) = required_value(args, index, argument)
      headers.push(split_header(value))
      index = next
    } else if argument.has_prefix("--header=") {
      let (value, next) = option_value(
        args,
        index,
        "--header",
        Some(argument[9:].to_owned()),
      )
      headers.push(split_header(value))
      index = next
    } else if argument.has_prefix("-H") && argument.length() > 2 {
      headers.push(split_header(argument[2:].to_owned()))
    } else if argument == "--raw-field" || argument == "-f" {
      let (value, next) = required_value(args, index, argument)
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        raw_fields.push(split_field(value))
      }
      index = next
    } else if argument.has_prefix("--raw-field=") {
      let (value, next) = option_value(
        args,
        index,
        "--raw-field",
        Some(argument[12:].to_owned()),
      )
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        raw_fields.push(split_field(value))
      }
      index = next
    } else if argument.has_prefix("-f") && argument.length() > 2 {
      let value = argument[2:].to_owned()
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        raw_fields.push(split_field(value))
      }
    } else if argument == "--field" || argument == "-F" {
      let (value, next) = required_value(args, index, argument)
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        json_fields.push(split_field(value))
      }
      index = next
    } else if argument.has_prefix("--field=") {
      let (value, next) = option_value(
        args,
        index,
        "--field",
        Some(argument[8:].to_owned()),
      )
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        json_fields.push(split_field(value))
      }
      index = next
    } else if argument.has_prefix("-F") && argument.length() > 2 {
      let value = argument[2:].to_owned()
      if value.has_suffix("[]") && !value.contains_char('=') {
        empty_arrays.push(value)
      } else {
        json_fields.push(split_field(value))
      }
    } else if argument.has_prefix("-") {
      raise UnknownOption(argument)
    } else if path is None {
      path = Some(argument)
    } else {
      raise UnexpectedArgument(argument)
    }
    index += 1
  }
  let path = match path {
    Some(value) => value
    None => raise MissingValue("ENDPOINT")
  }
  if !explicit_method &&
    (
      !raw_fields.is_empty() ||
      !json_fields.is_empty() ||
      !empty_arrays.is_empty() ||
      input is Some(_)
    ) {
    verb = "POST"
  }
  guard !(slurp && !paginate) else {
    raise InvalidValue("--slurp requires --paginate")
  }
  guard !(silent && verbose) else {
    raise InvalidValue("--silent conflicts with --verbose")
  }
  guard !(jq is Some(_) && template is Some(_)) else {
    raise InvalidValue("--jq conflicts with --template")
  }
  guard !(slurp && (jq is Some(_) || template is Some(_))) else {
    raise InvalidValue("--slurp conflicts with --jq/--template")
  }
  guard !(paginate && input is Some(_)) else {
    raise InvalidValue("--paginate cannot be combined with --input")
  }
  guard !(paginate && verb != "GET" && path != "graphql") else {
    raise InvalidValue(
      "--paginate is only supported for GET and GraphQL requests",
    )
  }
  Api({
    path,
    verb,
    explicit_method,
    hostname,
    headers,
    raw_fields,
    json_fields,
    input,
    jq,
    template,
    paginate,
    slurp,
    show_headers,
    silent,
    verbose,
    allow_escape_sequences,
    cache,
    previews,
    empty_arrays,
  })
}

///|
pub fn parse(args : Array[String]) -> Invocation raise ParseError {
  guard !args.is_empty() else { return Help }
  match args[0] {
    "help" if args.length() > 1 => HelpTopic(args[1])
    "--help" | "-h" | "help" => Help
    "--version" | "version" => Version
    "completion" =>
      Completion(shell=if args.length() > 1 { Some(args[1]) } else { None })
    "config" => Config(args[1:].to_owned())
    "alias" => Alias(args[1:].to_owned())
    "auth" => Auth(args[1:].to_owned())
    "api" => parse_api(args[1:].to_owned())
    command if command
      is ("repo"
      | "status"
      | "issue"
      | "pr"
      | "discussion"
      | "release"
      | "run"
      | "workflow"
      | "actions"
      | "search"
      | "org"
      | "project"
      | "label"
      | "gist"
      | "gpg-key"
      | "ssh-key"
      | "secret"
      | "variable"
      | "cache"
      | "browse"
      | "licenses"
      | "ruleset"
      | "skill"
      | "skills"
      | "send-telemetry"
      | "preview"
      | "accessibility") => Business({ command, args: args[1:].to_owned(), })
    command => Unsupported(command)
  }
}

///|
pub fn help_text() -> String {
  (
    #|Work seamlessly with GitHub from the command line.
    #|
    #|USAGE
    #|  gh <command> <subcommand> [flags]
    #|
    #|CORE COMMANDS
    #|  auth:          Authenticate gh and git with GitHub
    #|  browse:        Open repositories, issues, pull requests, and more in the browser
    #|  codespace:     Connect to and manage codespaces
    #|  discussion:    Work with GitHub Discussions (preview)
    #|  gist:          Manage gists
    #|  issue:         Manage issues
    #|  org:           Manage organizations
    #|  pr:            Manage pull requests
    #|  project:       Work with GitHub Projects.
    #|  release:       Manage releases
    #|  repo:          Manage repositories
    #|  skill:         Install and manage agent skills (preview)
    #|
    #|GITHUB ACTIONS COMMANDS
    #|  cache:         Manage GitHub Actions caches
    #|  run:           View details about workflow runs
    #|  workflow:      View details about GitHub Actions workflows
    #|
    #|ALIAS COMMANDS
    #|  co:            Alias for "pr checkout"
    #|
    #|ADDITIONAL COMMANDS
    #|  agent-task:    Work with agent tasks (preview)
    #|  alias:         Create command shortcuts
    #|  api:           Make an authenticated GitHub API request
    #|  attestation:   Work with artifact attestations
    #|  completion:    Generate shell completion scripts
    #|  config:        Manage configuration for gh
    #|  copilot:       Run the GitHub Copilot CLI (preview)
    #|  extension:     Manage gh extensions
    #|  gpg-key:       Manage GPG keys
    #|  label:         Manage labels
    #|  licenses:      View third-party license information
    #|  preview:       Execute previews for gh features
    #|  ruleset:       View info about repo rulesets
    #|  search:        Search for repositories, issues, and pull requests
    #|  secret:        Manage GitHub secrets
    #|  ssh-key:       Manage SSH keys
    #|  status:        Print information about relevant issues, pull requests, and notifications across repositories
    #|  variable:      Manage GitHub Actions variables
    #|
    #|HELP TOPICS
    #|  accessibility: Learn about GitHub CLI's accessibility experiences
    #|  actions:       Learn about working with GitHub Actions
    #|  environment:   Environment variables that can be used with gh
    #|  exit-codes:    Exit codes used by gh
    #|  formatting:    Formatting options for JSON data exported from gh
    #|  mintty:        Information about using gh with MinTTY
    #|  reference:     A comprehensive reference of all gh commands
    #|  telemetry:     Information about telemetry in gh
    #|
    #|FLAGS
    #|  --help      Show help for command
    #|  --version   Show gh version
    #|
    #|EXAMPLES
    #|  $ gh issue create
    #|  $ gh repo clone cli/cli
    #|  $ gh pr checkout 321
    #|
    #|LEARN MORE
    #|  Use `gh <command> <subcommand> --help` for more information about a command.
    #|  Read the manual at https://cli.github.com/manual
    #|  Learn about exit codes using `gh help exit-codes`
    #|  Learn about accessibility experiences using `gh help accessibility`
    #|
  )
}

///|
test "api parser defaults to POST when fields are present" {
  guard parse(["api", "repos/a/b/issues", "-f", "title=hello"]) is Api(options) else {
    fail("expected api")
  }
  assert_eq(options.verb, "POST")
}

///|
test "api help is a command topic rather than root help" {
  guard parse(["api", "--help"]) is HelpTopic("api") else {
    fail("expected API help topic")
  }
  guard parse(["help", "api"]) is HelpTopic("api") else {
    fail("expected help topic alias")
  }
}

///|
test "api parser accepts long equals and attached short options" {
  guard parse([
      "api", "repos/a/b", "--method=patch", "-HAccept: application/json", "-fstate=open",
    ])
    is Api(options) else {
    fail("expected api")
  }
  assert_eq(options.verb, "PATCH")
  assert_eq(options.headers, [("Accept", "application/json")])
  assert_eq(options.raw_fields, [("state", "open")])
}

///|
test "api parser rejects conflicting output modes" {
  try parse(["api", "repos/a/b", "--silent", "--verbose"]) catch {
    InvalidValue(message) => assert_true(message.contains("silent"))
    _ => fail("unexpected parse error")
  } noraise {
    _ => fail("expected parse error")
  }
}

///|
test "api parser rejects invalid pagination combinations" {
  try parse(["api", "repos/a/b", "--slurp"]) catch {
    InvalidValue(message) => assert_true(message.contains("paginate"))
    _ => fail("unexpected parse error")
  } noraise {
    _ => fail("expected parse error")
  }
  try parse(["api", "repos/a/b", "-X", "POST", "--paginate"]) catch {
    InvalidValue(message) => assert_true(message.contains("only supported"))
    _ => fail("unexpected parse error")
  } noraise {
    _ => fail("expected parse error")
  }
}

///|
test "business parser retains command and arguments for native request builder" {
  guard parse(["repo", "view", "-R", "acme/widgets", "--json", "name"])
    is Business(options) else {
    fail("expected business invocation")
  }
  assert_eq(options.command(), "repo")
  assert_eq(options.args(), ["view", "-R", "acme/widgets", "--json", "name"])
}

///|
test "all core resource roots parse as business invocations" {
  for
    command in [
      "repo", "status", "issue", "pr", "discussion", "release", "run", "workflow",
      "actions", "search", "org", "project", "label", "gist", "gpg-key", "ssh-key",
      "secret", "variable", "cache", "browse", "licenses", "ruleset", "skill", "skills",
      "send-telemetry", "preview", "accessibility",
    ] {
    guard parse([command]) is Business(options) else {
      fail("expected business invocation for " + command)
    }
    assert_eq(options.command(), command)
  }
}
