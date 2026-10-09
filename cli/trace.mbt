///|
/// Offline trace selection never constructs an authenticated HTTP client.
pub struct TraceOptions {
  path : String
  query : @gh.TraceQuery
  json : Bool
}

///|
fn trace_group() -> @argparse.Command {
  let options = [
    @argparse.OptionArg("operation-id", about="Exact logical operation ID"),
    @argparse.OptionArg("request-id", about="Exact server request ID"),
    @argparse.OptionArg("status", about="Exact HTTP status, 100..599"),
    @argparse.OptionArg("method", about="GET, POST, PUT, PATCH or DELETE"),
    @argparse.OptionArg("path-prefix", about="Match redacted path prefix"),
    @argparse.OptionArg(
      "limit",
      about="Most recent matching attempts, 1..1000 (default 100)",
    ),
  ]
  command(
    "trace",
    about="Query local redacted attempts without network access",
    subcommands=[
      command("list", options~),
      command("show", options~, positionals=[
        @argparse.PositionArg(
          "operation",
          num_args=@argparse.ValueRange(lower=0, upper=1),
        ),
      ]),
    ],
  )
}

///|
fn parse_trace(
  matches : @argparse.Matches,
  leaf : @argparse.Matches,
  action : String,
) -> Result[Invocation, String] {
  guard value(matches, "trace") is Some(path) && !path.is_empty() && path != "-" else {
    return Err(
      "trace queries require --trace with an explicit regular file path",
    )
  }
  let explicit = value(leaf, "operation-id")
  let operation_id = if action == "show" {
    guard value(leaf, "operation") is Some(operation) else {
      return Err("trace show requires an operation ID")
    }
    if explicit is Some(other) && operation != other {
      return Err("operation ID conflicts with --operation-id")
    }
    Some(operation)
  } else {
    explicit
  }
  guard positive_int(value(leaf, "limit").unwrap_or("100"), 1000) is Some(limit) else {
    return Err("--limit must be an integer from 1 to 1000")
  }
  let status = match value(leaf, "status") {
    Some(raw) =>
      match positive_int(raw, 599) {
        Some(code) if code >= 100 => Some(code)
        _ => return Err("--status must be an integer from 100 to 599")
      }
    None => None
  }
  let verb = match value(leaf, "method") {
    None => None
    Some("GET") => Some(@gh.Get)
    Some("POST") => Some(@gh.Post)
    Some("PUT") => Some(@gh.Put)
    Some("PATCH") => Some(@gh.Patch)
    Some("DELETE") => Some(@gh.Delete)
    _ => return Err("--method must be GET, POST, PUT, PATCH or DELETE")
  }
  let request_id = value(leaf, "request-id")
  let path_prefix = value(leaf, "path-prefix")
  let query = match
    @gh.TraceQuery::new(
      operation_id?,
      request_id?,
      status?,
      verb?,
      path_prefix?,
      limit~,
    ) {
    Ok(query) => query
    Err(_) =>
      return Err(
        "invalid trace filters; IDs and path prefixes must be safe metadata",
      )
  }
  Ok(Trace({ path, query, json: matches.flags.get("json") == Some(true), }))
}

///|
/// Only reconstructed metadata enters output. Unknown on-disk fields are never
/// echoed, and terminal summaries use the same control-character sanitizer.
pub fn trace_output(
  result : Result[@gh.TraceQueryResult, @gh.ApiError],
  json~ : Bool,
) -> Output {
  let result = match result {
    Ok(result) => result
    Err(kind) => return trace_error(kind, json~)
  }
  let stdout = if json {
    result.to_json().stringify() + "\n"
  } else {
    lines(
      result.records.map(record => {
        let status = record.status
          .map(status => status.to_string())
          .unwrap_or("-")
        "\{safe_text(record.operation_id)}\t\{record.attempt}\t\{record.verb.as_string()}\t\{status}\t\{safe_text(record.path)}\t\{safe_text(record.request_id.unwrap_or("-"))}"
      }),
    ) +
    "\n"
  }
  let stderr = if json {
    ""
  } else {
    (if result.truncated {
      "More matching attempts exist; increase --limit or narrow filters.\n"
    } else {
      ""
    }) +
    (if result.incomplete_tail {
      "Incomplete final trace record ignored.\n"
    } else {
      ""
    })
  }
  { stdout, stderr, exit_code: 0, }
}

///|
fn trace_error(kind : @gh.ApiError, json~ : Bool) -> Output {
  let message = match kind {
    @gh.Decode(..) =>
      "local trace data is malformed, unsupported, or exceeds the scan limits"
    _ => "cannot read the selected local trace file or query"
  }
  let stderr = if json {
    let envelope : Json = {
      "version": 1,
      "error": {
        "code": kind.code().to_json(),
        "message": message.to_json(),
        "status": Json::null(),
        "request_id": Json::null(),
      },
    }
    envelope.stringify() + "\n"
  } else {
    "error [\{kind.code()}]: \{message}\n"
  }
  {
    stdout: "",
    stderr,
    exit_code: if kind is @gh.InvalidRequest(..) {
      2
    } else {
      1
    },
  }
}
