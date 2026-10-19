///|
/// URLs are prepared once by the SDK; the adapter adds no provider prefix.
pub fn github_client(
  base_url~ : String,
  graphql_url? : String,
  token? : String,
  trace_path? : String,
  timeout_ms~ : Int32 = 30000,
  max_response_bytes~ : Int32 = 16777216,
) -> Result[@github.Client, @github_cli.Output] {
  guard base_url.split_once("://") is Some((scheme, rest)) else {
    return Err(@github_cli.failure(message="invalid API URL"))
  }
  let authority = rest.split("/").next().unwrap_or("").to_owned()
  let origin = match
    @gh.normalize_origin(scheme.to_owned() + "://" + authority) {
    Ok(v) => v
    Err(_) => return Err(@github_cli.failure(message="invalid API origin"))
  }
  let transport = @transport.native_raw_transport(
    base_url=origin,
    timeout_ms~,
    max_response_bytes~,
  ) catch {
    _ =>
      return Err(
        @github_cli.failure(message="invalid HTTP transport configuration"),
      )
  }
  // Release metadata is served by the API origin, while asset uploads on
  // github.com use uploads.github.com. Keep a second transport scoped to
  // that derived origin; the SDK request seam validates the same relationship
  // before a URL can select it.
  let upload_origin : String? = if authority == "api.github.com" {
    Some("https://uploads.github.com")
  } else if authority.has_prefix("api.") {
    Some(scheme.to_owned() + "://uploads." + authority[4:].to_owned())
  } else {
    Some(origin)
  }
  let upload_transport : @gh.RawTransport? = match upload_origin {
    Some(value) if value != origin =>
      Some(
        @transport.native_raw_transport(
          base_url=value,
          timeout_ms~,
          max_response_bytes~,
        ),
      ) catch {
        _ => None
      }
    _ => None
  }
  let observer : (async (@github.TraceRecord) -> Unit)? = match trace_path {
    None => None
    Some(path) => {
      guard !path.is_empty() && path != "-" else {
        return Err(@github_cli.failure(message="invalid trace path"))
      }
      Some(record => {
        let secrets = match token {
          Some(v) => [v]
          None => []
        }
        @fs.write_file(
          path,
          record.to_json_line(secrets~),
          append=true,
          permission=0o600,
        )
      })
    }
  }
  @github.Client::new(
    config=@github.ClientConfig::new(base_url~, graphql_url?, token?),
    transport=@github.Transport::new(send=request => {
      let mut download_origin : String? = None
      if origin == "https://api.github.com" {
        for
          candidate in [
            "https://release-assets.githubusercontent.com", "https://github-releases.githubusercontent.com",
          ] {
          if request.url().has_prefix(candidate + "/") {
            download_origin = Some(candidate)
          }
        }
      }
      let selected = if download_origin is Some(asset_origin) {
        // The SDK's explicit release download operation validates every hop.
        // Never forward API credentials or cookies to the signed asset URL.
        guard request.verb() == "GET" &&
          request.body() is None &&
          request
          .headers()
          .all(pair => {
            pair.0.equal_ignore_ascii_case("Accept") ||
            pair.0.equal_ignore_ascii_case("User-Agent")
          }) else {
          return Err(@github.TransportError::Failed)
        }
        let asset_transport = @transport.native_raw_transport(
          base_url=asset_origin,
          timeout_ms~,
          max_response_bytes~,
        ) catch {
          _ => return Err(@github.TransportError::Failed)
        }
        (asset_transport, asset_origin)
      } else {
        match upload_origin {
          Some(value) if value != origin &&
            request.url().strip_prefix(value + "/") is Some(_) =>
            match upload_transport {
              Some(value_transport) => (value_transport, value)
              None => return Err(@github.TransportError::Failed)
            }
          _ => (transport, origin)
        }
      }
      let (selected_transport, selected_origin) = selected
      let suffix = match request.url().strip_prefix(selected_origin + "/") {
        Some(value) => value
        None => return Err(@github.TransportError::Failed)
      }
      let response = selected_transport.send(
        @gh.RawRequest::new(
          verb=request.verb(),
          path="/" + suffix.to_owned(),
          body?=request.body(),
          headers=request.headers(),
        ),
      ) catch {
        error if @async.is_being_cancelled() => raise error
        _ => return Err(@github.TransportError::Failed)
      }
      Ok(
        @github.RawResponse::new(
          status=response.status(),
          headers=response.headers(),
          body=response.body(),
        ),
      )
    }),
    trace_observer?=observer,
  ).map_err(_ => {
    @github_cli.failure(message="invalid GitHub client configuration")
  })
}

///|
async fn read_api_input(source : String) -> Result[Bytes, @github_cli.Output] {
  let bytes = try {
    if source == "-" {
      let buffer = @buffer.Buffer()
      for ;; {
        match @stdio.stdin.read_some(max_len=65536) {
          None => break
          Some(chunk) => {
            guard chunk.length() <= 16777216 - buffer.length() else {
              return Err(
                @github_cli.failure(message="API input exceeds 16 MiB limit"),
              )
            }
            buffer.write_bytes(chunk)
          }
        }
      }
      buffer.to_bytes()
    } else {
      guard @fs.file_size(source) <= 16777216L else {
        return Err(
          @github_cli.failure(message="API input exceeds 16 MiB limit"),
        )
      }
      @fs.read_file(source).binary()
    }
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ => return Err(@github_cli.failure(message="cannot read API input"))
  }
  Ok(bytes)
}

///|
async fn api_placeholders(
  options : @github_cli.ApiOptions,
) -> Result[@github_cli.RepositoryContext?, @github_cli.Output] {
  let sources = [options.path()]
  for (_, value) in options.raw_fields() {
    sources.push(value)
  }
  for (_, value) in options.json_fields() {
    sources.push(value)
  }
  let need_repository = sources.any(v => {
    v.contains("{owner}") || v.contains("{repo}")
  })
  let need_branch = sources.any(v => v.contains("{branch}"))
  if need_repository {
    resolve_repository_context(need_branch~, respect_resolved=false).map(value => {
      Some(value)
    })
  } else if need_branch {
    let branch = match resolve_current_branch() {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match @github_cli.RepositoryContext::parse("placeholder/placeholder") {
      Ok(context) =>
        context
        .with_branch(branch)
        .map(value => Some(value))
        .map_err(_ => {
          @github_cli.failure(message="cannot resolve current branch")
        })
      Err(_) => Err(@github_cli.failure(message="cannot resolve repository"))
    }
  } else {
    Ok(None)
  }
}

///|
async fn run_api(options : @github_cli.ApiOptions) -> @github_cli.Output {
  let environment = @github_auth.Environment::from_process()
  let environment = match options.hostname() {
    Some(host) => environment.with_host(host)
    None => environment
  }
  let keyring = system_credential_backend()
  let config = match resolve_github_auth_with_backend(environment, keyring) {
    Ok(v) => v
    Err(e) => return e
  }
  guard config.token() is Some(_) else {
    return @github_cli.Output::new(
      stderr="To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n",
      exit_code=4,
    )
  }
  let repository = match api_placeholders(options) {
    Ok(v) => v
    Err(e) => return e
  }
  let client = match
    github_client(
      base_url=config.rest_base_url(),
      graphql_url=config.graphql_url(),
      token?=config.token(),
      trace_path?=@env.get_env_var("GH_TRACE_FILE"),
    ) {
    Ok(v) => v
    Err(e) => return e
  }
  execute_github_api(
    options,
    client~,
    base_url=config.rest_base_url(),
    repository?,
  )
}

///|
/// Credential-free execution seam for native loopback and injected fixtures.
pub async fn execute_github_api(
  options : @github_cli.ApiOptions,
  client~ : @github.Client,
  base_url~ : String,
  repository? : @github_cli.RepositoryContext,
) -> @github_cli.Output {
  let endpoint = match api_substitute(options.path(), repository) {
    Ok(v) => v
    Err(e) => return e
  }
  let graphql = endpoint == "graphql"
  let path = if endpoint.has_prefix("/") { endpoint } else { "/" + endpoint }
  let values : Array[(String, Json)] = []
  for (name, value) in options.raw_fields() {
    let value = match api_substitute(value, repository) {
      Ok(v) => v
      Err(e) => return e
    }
    values.push((name, Json::string(value)))
  }
  for (name, value) in options.json_fields() {
    let value = if value.strip_prefix("@") is Some(source) {
      let bytes = match read_api_input(source.to_owned()) {
        Ok(v) => v
        Err(e) => return e
      }
      Json::string(
        @utf8.decode(bytes) catch {
          _ => return @github_cli.failure(message="field file is not UTF-8")
        },
      )
    } else {
      let text = match api_substitute(value, repository) {
        Ok(v) => v
        Err(e) => return e
      }
      @github_cli.typed_field(text)
    }
    values.push((name, value))
  }
  let fields = match @github_cli.build_fields(values, options.empty_arrays()) {
    Ok(v) => v
    Err(e) => return @github_cli.failure(message=e)
  }
  let input = match options.input() {
    Some(source) =>
      match read_api_input(source) {
        Ok(v) => Some(v)
        Err(e) => return e
      }
    None => None
  }
  let query = if input is Some(_) || options.verb() == "GET" {
    @github_cli.query_fields(values)
  } else {
    []
  }
  let body = match input {
    Some(v) => Some(v)
    None if options.verb() != "GET" && !fields.is_empty() =>
      Some(
        @utf8.encode(
          (if graphql {
            @github_cli.graphql_payload(fields)
          } else {
            Json::object(fields)
          }).stringify(),
        ),
      )
    None => None
  }
  let headers = options.headers()
  if !options.previews().is_empty() {
    let accepts : Array[String] = []
    for preview in options.previews() {
      for name in preview.split(",") {
        let name = name.strip_suffix("-preview").unwrap_or(name)
        accepts.push(
          "application/vnd.github." + name.to_owned() + "-preview+json",
        )
      }
    }
    headers.push(("Accept", accepts.join(", ")))
  }
  let mut request = @github.Request::new(
    verb=options.verb(),
    path~,
    query~,
    headers~,
    body?,
  )
  let output = @buffer.Buffer()
  let diagnostics = StringBuilder()
  let pages : Array[Json] = []
  let seen : Map[String, Unit] = Map([])
  let mut current_url = base_url + path
  let operation_name = match fields.get("operationName") {
    Some(String(name)) => name
    _ => if graphql { "graphql" } else { "api" }
  }
  let cache_duration = match options.cache() {
    Some(duration) => {
      guard api_cache_duration(duration) is Some(_) else {
        return @github_cli.failure(message="invalid cache duration")
      }
      guard options.verb() == "GET" else {
        return @github_cli.failure(
          message="--cache is only supported for GET requests",
        )
      }
      Some(duration)
    }
    None => None
  }
  let cached = match cache_duration {
    Some(duration) if options.verb() == "GET" =>
      api_cache_read(request, duration)
    _ => None
  }
  for page = 0; page < 10000; page = page + 1 {
    let from_cache = page == 0 && cached is Some(_)
    let result = if page == 0 && cached is Some(response) {
      Ok(response)
    } else if graphql {
      client.graphql_raw(request, operation_id="api", operation_name~)
    } else {
      client.request(request, operation_id="api", operation_name="api")
    }
    let response = match result {
      Ok(v) => v
      Err(error) =>
        match error.response() {
          Some(v) => v
          None =>
            return @github_cli.Output::from_bytes(
              output.to_bytes(),
              stderr=diagnostics.to_string() + "gh: " + error.code() + "\n",
              exit_code=if error is @github.Cancelled { 2 } else { 1 },
            )
        }
    }
    if !from_cache &&
      cache_duration is Some(duration) &&
      response.status() >= 200 &&
      response.status() < 300 &&
      options.verb() == "GET" {
      api_cache_write(request, response, duration)
    }
    let rendered = @github_cli.render_response(
      response.status(),
      response.headers(),
      response.body(),
      jq?=options.jq(),
      template?=options.template(),
      include_headers=options.show_headers(),
      silent=options.silent(),
      verbose=options.verbose(),
      allow_escape_sequences=options.allow_escape_sequences(),
    )
    diagnostics.write_string(rendered.stderr())
    if !options.slurp() {
      output.write_bytes(rendered.stdout_bytes())
    }
    if rendered.exit_code() != 0 {
      return @github_cli.Output::from_bytes(
        output.to_bytes(),
        stderr=diagnostics.to_string(),
        exit_code=rendered.exit_code(),
      )
    }
    let json : Json? = if graphql || options.slurp() {
      Some(@json.parse(@utf8.decode(response.body()))) catch {
        _ =>
          return @github_cli.Output::from_bytes(
            output.to_bytes(),
            stderr=diagnostics.to_string() + "gh: response is not valid JSON\n",
            exit_code=1,
          )
      }
    } else {
      None
    }
    if options.slurp() && json is Some(v) {
      pages.push(v)
    }
    if graphql &&
      json is Some({ "errors": Array(errors), .. }) &&
      !errors.is_empty() {
      for error in errors {
        match error {
          { "message": String(message), .. } =>
            diagnostics.write_string("gh: " + message + "\n")
          _ => diagnostics.write_string("gh: GraphQL error\n")
        }
      }
      return @github_cli.Output::from_bytes(
        output.to_bytes(),
        stderr=diagnostics.to_string(),
        exit_code=1,
      )
    }
    if !options.paginate() {
      break
    }
    if graphql {
      let cursor = match json {
        Some(v) =>
          match api_cursor(v) {
            Ok(v) => v
            Err(e) => return e
          }
        None => None
      }
      guard cursor is Some(cursor) else { break }
      guard !seen.contains(cursor) else {
        return @github_cli.failure(message="GraphQL pagination cursor repeated")
      }
      seen[cursor] = ()
      let payload = match request.body() {
        Some(bytes) =>
          @json.parse(@utf8.decode(bytes)) catch {
            _ =>
              return @github_cli.failure(
                message="GraphQL pagination requires a JSON body",
              )
          }
        None =>
          return @github_cli.failure(
            message="GraphQL pagination requires a JSON body",
          )
      }
      guard payload is Object(top) else {
        return @github_cli.failure(message="GraphQL payload must be an object")
      }
      let variables = match top.get("variables") {
        Some(Object(v)) => v
        None => Map([])
        _ => return @github_cli.failure(message="invalid GraphQL variables")
      }
      variables["endCursor"] = Json::string(cursor)
      top["variables"] = Json::object(variables)
      request = @github.Request::new(
        verb=options.verb(),
        path~,
        headers~,
        body=@utf8.encode(Json::object(top).stringify()),
      )
    } else {
      let next = match response.next_url(current_url~) {
        Ok(v) => v
        Err(_) => return @github_cli.failure(message="invalid pagination link")
      }
      guard next is Some(next) else { break }
      guard !seen.contains(next) else {
        return @github_cli.failure(message="pagination link repeated")
      }
      seen[next] = ()
      guard next.strip_prefix(base_url + "/") is Some(suffix) else {
        return @github_cli.failure(
          message="pagination left configured API base",
        )
      }
      current_url = next
      request = @github.Request::new(
        verb="GET",
        path="/" + suffix.to_owned(),
        headers~,
      )
    }
    if page == 9999 {
      return @github_cli.failure(message="pagination exceeded page limit")
    }
  }
  if options.slurp() && !options.silent() {
    output.write_bytes(@utf8.encode(Json::array(pages).stringify() + "\n"))
  }
  if client.trace_failures() > 0 {
    diagnostics.write_string("warning: trace observer failed\n")
  }
  @github_cli.Output::from_bytes(
    output.to_bytes(),
    stderr=diagnostics.to_string(),
  )
}

///|
fn api_substitute(
  source : String,
  context : @github_cli.RepositoryContext?,
) -> Result[String, @github_cli.Output] {
  match context {
    None => Ok(source)
    Some(context) =>
      context
      .substitute(source)
      .map_err(_ => {
        @github_cli.failure(message="cannot resolve repository placeholder")
      })
  }
}

///|
fn api_cursor(value : Json) -> Result[String?, @github_cli.Output] {
  let candidates : Array[Json] = []
  api_page_info(value, candidates)
  if candidates.is_empty() {
    return Ok(None)
  }
  guard candidates.length() == 1 else {
    return Err(
      @github_cli.failure(
        message="GraphQL pagination has multiple pageInfo objects",
      ),
    )
  }
  @github.graphql_next_cursor(candidates[0]).map_err(_ => {
    @github_cli.failure(message="invalid GraphQL pageInfo")
  })
}

///|
fn api_page_info(value : Json, result : Array[Json]) -> Unit {
  match value {
    Object(fields) =>
      for name, value in fields {
        if name == "pageInfo" {
          result.push(value)
        } else {
          api_page_info(value, result)
        }
      }
    Array(values) =>
      for value in values {
        api_page_info(value, result)
      }
    _ => ()
  }
}
