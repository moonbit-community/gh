///|
/// Rendered output has separate channels. The executable writes these strings
/// verbatim and exits with exit_code, so JSON never mixes with human progress.
pub(all) struct Output {
  stdout : String
  stderr : String
  exit_code : Int
}

///|
fn nullable_string(value : String?) -> Json {
  match value {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
fn nullable_int(value : Int?) -> Json {
  match value {
    Some(value) => value.to_json()
    None => Json::null()
  }
}

///|
fn safe_text(text : String) -> String {
  let buffer = StringBuilder()
  let mut count = 0
  for ch in text {
    if count == 240 {
      buffer.write_string("…")
      break
    }
    let cp = ch.to_int()
    if cp <= 31 ||
      (cp >= 127 && cp <= 159) ||
      cp == 0x2028 ||
      cp == 0x2029 ||
      (cp >= 0x202a && cp <= 0x202e) ||
      (cp >= 0x2066 && cp <= 0x2069) {
      buffer.write_char(' ')
    } else {
      buffer.write_char(ch)
    }
    count += 1
  }
  buffer.to_string()
}

///|
fn failure_message(kind : @gh.ApiError) -> String {
  match kind {
    @gh.InvalidRequest(..) => "invalid request or local configuration"
    @gh.Unauthorized => "authentication required or token rejected"
    @gh.Forbidden => "permission denied"
    @gh.NotFound => "resource not found"
    @gh.Conflict(..) => "resource conflict or stale version"
    @gh.RateLimited => "request rate limit reached"
    @gh.Server(..) => "MoonHub server failed to complete the request"
    @gh.UnexpectedStatus(..) => "unexpected HTTP response status"
    @gh.Decode(..) => "response does not match the MoonHub API contract"
    @gh.Transport(..) =>
      "request did not complete; check connectivity and server origin"
  }
}

///|
fn failure_exit(failure : @gh.ApiFailure) -> Int {
  match failure.kind {
    @gh.Unauthorized | @gh.Forbidden => 3
    @gh.Conflict(..) => 4
    @gh.Transport(..) => 5
    @gh.InvalidRequest(..) if failure.status is None => 2
    _ => 1
  }
}

///|
/// Server bodies and arbitrary exception messages are never rendered as
/// diagnostics. Status-based categories remain stable across error envelopes.
pub fn failure_output(
  failure : @gh.ApiFailure,
  json~ : Bool,
  outcome? : @moonhub.MutationOutcome,
) -> Output {
  let message = failure_message(failure.kind) +
    (match outcome {
      Some(@moonhub.Unknown) =>
        "; write outcome is unknown; inspect the resource before retrying"
      _ => ""
    })
  let request_id = match failure.request_id {
    Some(id) if !id.is_empty() &&
      id.length() <= 128 &&
      id
      .iter()
      .all(ch => ch is ('a'..='z' | 'A'..='Z' | '0'..='9' | '.' | '_' | '-')) =>
      Some(id)
    _ => None
  }
  let stderr = if json {
    let details : Map[String, Json] = {
      "code": failure.kind.code().to_json(),
      "message": message.to_json(),
      "status": nullable_int(failure.status),
      "request_id": nullable_string(request_id),
    }
    if outcome is Some(outcome) {
      details["outcome"] = outcome.as_string().to_json()
    }
    let envelope : Json = { "version": 1, "error": Json::object(details) }
    envelope.stringify() + "\n"
  } else {
    "error [\{failure.kind.code()}]: \{message}\n"
  }
  { stdout: "", stderr, exit_code: failure_exit(failure), }
}

///|
/// message comes from parse's fixed diagnostics, never from a raw argv value.
pub fn argument_error(message : String, json~ : Bool) -> Output {
  let stderr = if json {
    let envelope : Json = {
      "version": 1,
      "error": {
        "code": "invalid_request",
        "message": message.to_json(),
        "status": Json::null(),
        "request_id": Json::null(),
      },
    }
    envelope.stringify() + "\n"
  } else {
    "error [invalid_request]: \{safe_text(message)}\n"
  }
  { stdout: "", stderr, exit_code: 2, }
}

///|
fn trace_warning(json : Bool) -> String {
  if json {
    let warning : Json = {
      "version": 1,
      "warning": {
        "code": "trace_failed",
        "message": "request trace could not be recorded completely",
      },
    }
    warning.stringify() + "\n"
  } else {
    "warning [trace_failed]: request trace could not be recorded completely\n"
  }
}

///|
fn Output::with_trace_warning(
  self : Output,
  failed : Bool,
  json : Bool,
) -> Output {
  if failed {
    { ..self, stderr: self.stderr + trace_warning(json), }
  } else {
    self
  }
}

///|
fn[T] render_read(
  result : @moonhub.ReadResult[T],
  json : Bool,
  encode : (T) -> Json,
  human : (T) -> String,
  list? : Bool = false,
) -> Output {
  let output = match result.value {
    Err(failure) => failure_output(failure, json~)
    Ok(data) => {
      let stdout = if json {
        let pagination : Json = if list {
          {
            "pages": result.pages.to_json(),
            "next": nullable_string(result.next),
          }
        } else {
          Json::null()
        }
        let envelope : Json = {
          "version": 1,
          "data": encode(data),
          "pagination": pagination,
          "etag": nullable_string(result.etag.map(tag => tag.value())),
        }
        envelope.stringify() + "\n"
      } else {
        human(data) + "\n"
      }
      let stderr = if !json && result.next is Some(_) {
        "More results are available; use --paginate or request the next page.\n"
      } else {
        ""
      }
      { stdout, stderr, exit_code: 0, }
    }
  }
  output.with_trace_warning(result.trace_failed, json)
}

///|
fn[T] render_mutation(
  result : @moonhub.MutationResult[T],
  json : Bool,
  encode : (T) -> Json,
  human : (T) -> String,
) -> Output {
  let output = match result.value {
    Err(failure) => failure_output(failure, json~, outcome=result.outcome)
    Ok(data) => {
      let stdout = if json {
        let envelope : Json = {
          "version": 1,
          "data": encode(data),
          "pagination": Json::null(),
          "etag": nullable_string(result.etag.map(tag => tag.value())),
          "outcome": result.outcome.as_string().to_json(),
        }
        envelope.stringify() + "\n"
      } else {
        human(data) + "\n"
      }
      { stdout, stderr: "", exit_code: 0, }
    }
  }
  output.with_trace_warning(result.trace_failed, json)
}

///|
fn repository_line(repo : @moonhub.Repository) -> String {
  "\{safe_text(repo.owner)}/\{safe_text(repo.name)}\t\{repo.visibility}"
}

///|
fn issue_line(issue : @moonhub.Issue) -> String {
  "#\{issue.number}\t\{issue.status}\t\{safe_text(issue.title)}"
}

///|
fn merge_request_line(request : @moonhub.MergeRequest) -> String {
  let job = match request.job_status {
    Some(status) => "\tmerge:\{safe_text(status)}"
    None => ""
  }
  "#\{request.number}\t\{request.status}\t\{safe_text(request.title)}" + job
}

///|
fn lines(items : Array[String]) -> String {
  if items.is_empty() {
    "No results."
  } else {
    items.join("\n")
  }
}
