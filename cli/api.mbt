///|
fn api_command_spec() -> @argparse.Command {
  command(
    "api",
    about="Call a documented MoonHub JSON endpoint once",
    options=[
      @argparse.OptionArg(
        "method",
        short='X',
        about="GET, POST, PUT, PATCH or DELETE (default GET)",
      ),
      @argparse.OptionArg(
        "header",
        short='H',
        action=@argparse.Append,
        about="Request header Name: value; repeat for distinct names",
      ),
      @argparse.OptionArg(
        "input",
        about="Read UTF-8 JSON from FILE; - reads stdin",
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "path",
        num_args=@argparse.ValueRange(lower=0, upper=1),
      ),
    ],
  )
}

///|
fn parse_api(
  globals : @argparse.Matches,
  leaf : @argparse.Matches,
  base_url : String,
  config_path : String?,
  trace_path : String?,
) -> Result[Invocation, String] {
  let verb = match value(leaf, "method").unwrap_or("GET") {
    "GET" => @gh.Get
    "POST" => @gh.Post
    "PUT" => @gh.Put
    "PATCH" => @gh.Patch
    "DELETE" => @gh.Delete
    _ => return Err("api --method must be GET, POST, PUT, PATCH or DELETE")
  }
  if value(globals, "max-attempts") is Some(attempts) && attempts != "1" {
    return Err("api sends one attempt; --max-attempts must be 1 if supplied")
  }
  if value(globals, "repo") is Some(_) {
    return Err("api uses an explicit path and does not accept --repo")
  }
  guard value(leaf, "path") is Some(path) else {
    return Err("api requires a path relative to /api/v1 beginning with /")
  }
  let headers : Array[(String, String)] = []
  for raw in leaf.values.get("header").unwrap_or([]) {
    guard raw.split_once(":") is Some((name, value)) else {
      return Err("api --header requires Name: value")
    }
    // Only remove the usual separator spaces, never controls that validation
    // should reject. Header syntax and policy belong to the shared SDK.
    headers.push((name.to_owned(), value.trim(chars=" ").to_owned()))
  }
  if @moonhub.validate_api_request(@gh.Request::new(verb~, path~, headers~))
    is Err(_) {
    return Err("invalid api path or unsupported request headers")
  }
  let body_input = match value(leaf, "input") {
    Some("") => return Err("api --input requires a nonempty path or -")
    Some("-") => Some(Stdin)
    Some(path) => Some(File(path))
    None => None
  }
  if verb is @gh.Get && body_input is Some(_) {
    return Err(
      "api GET does not accept --input; select an explicit write method",
    )
  }
  Ok(
    Run({
      command: Api(verb, path, headers),
      base_url,
      config_path,
      trace_path,
      body_input,
      json: globals.flags.get("json") == Some(true),
      page: 1,
      per_page: 30,
      paginate: false,
      max_pages: 20,
      max_attempts: 1,
    }),
  )
}

///|
async fn run_api(
  opts : RunOptions,
  client : @moonhub.Client,
  verb : @gh.HttpMethod,
  path : String,
  headers : Array[(String, String)],
  operation_id~ : String,
  body? : String,
) -> Output {
  let input = match (opts.body_input, body) {
    (None, _) => None
    (Some(File(_) | Stdin), Some(text)) => Some(text)
    _ => {
      let outcome = if verb is @gh.Get { None } else { Some(@moonhub.NotSent) }
      return failure_output(
        @gh.ApiFailure::new(
          kind=@gh.InvalidRequest(message="api input was not resolved"),
        ),
        json=opts.json,
        outcome?,
      )
    }
  }
  let body = input
  render_api(
    client.api(@gh.Request::new(verb~, path~, headers~, body?), operation_id~),
    opts.json,
  )
}

///|
fn render_api(result : @moonhub.ApiResult, json : Bool) -> Output {
  let outcome = result.outcome
  let output = match result.value {
    Err(failure) => failure_output(failure, json~, outcome?)
    Ok(response) => {
      let stdout = if json {
        let envelope : Json = {
          "version": 1,
          "data": response.data,
          "status": response.status.to_json(),
          "request_id": nullable_string(response.request_id),
          "etag": nullable_string(response.etag.map(tag => tag.value())),
          "outcome": nullable_string(outcome.map(value => value.as_string())),
        }
        envelope.stringify() + "\n"
      } else {
        response.data.stringify(indent=2) + "\n"
      }
      let stderr = if json {
        ""
      } else {
        match outcome {
          Some(@moonhub.Accepted) =>
            "HTTP \{response.status}; write outcome: accepted; inspect the endpoint for completion.\n"
          Some(outcome) =>
            "HTTP \{response.status}; write outcome: \{outcome.as_string()}.\n"
          None => ""
        }
      }
      { stdout, stderr, exit_code: 0, }
    }
  }
  output.with_trace_warning(result.trace_failed, json)
}
