///|
/// gh exposes boolean merge strategy flags and an expected head commit.
/// Resolve their REST fields before any request, retaining the historical
/// API-shaped aliases only when they do not disagree with standard flags.
fn business_pr_merge_body(
  parsed : ParsedBusiness,
) -> Result[Bytes?, @github_cli.Output] {
  let mut strategy : String? = None
  for candidate in ["merge", "squash", "rebase"] {
    let enabled = match parsed.values.get(candidate) {
      Some("true") => true
      Some("false") => false
      Some(_) =>
        return Err(
          @github_cli.failure(
            message="invalid boolean value for --" + candidate,
          ),
        )
      None => parsed_flag(parsed, candidate)
    }
    if enabled {
      guard strategy is None else {
        return Err(
          @github_cli.failure(
            message="only one of --merge, --squash, or --rebase may be specified",
          ),
        )
      }
      strategy = Some(candidate)
    }
  }
  if parsed_flag(parsed, "merge_method") {
    return Err(@github_cli.failure(message="--merge-method requires a value"))
  }
  if parsed.values.get("merge_method") is Some(legacy_strategy) {
    guard legacy_strategy is ("merge" | "squash" | "rebase") else {
      return Err(
        @github_cli.failure(
          message="merge method must be merge, squash, or rebase",
        ),
      )
    }
    guard strategy is None || strategy == Some(legacy_strategy) else {
      return Err(
        @github_cli.failure(
          message="--merge-method conflicts with the selected merge strategy",
        ),
      )
    }
    strategy = Some(legacy_strategy)
  }
  if parsed_flag(parsed, "match_head_commit") || parsed_flag(parsed, "sha") {
    return Err(
      @github_cli.failure(message="expected head commit requires a value"),
    )
  }
  let expected = parsed.values.get("match_head_commit")
  let sha_alias = parsed.values.get("sha")
  if expected is Some(value) {
    guard !value.is_empty() else {
      return Err(
        @github_cli.failure(message="--match-head-commit requires a value"),
      )
    }
    guard sha_alias is None || sha_alias == expected else {
      return Err(
        @github_cli.failure(message="--sha conflicts with --match-head-commit"),
      )
    }
  }
  let sha = match expected {
    Some(_) => expected
    None => sha_alias
  }
  if sha is Some(value) && value.is_empty() {
    return Err(
      @github_cli.failure(message="expected head commit requires a value"),
    )
  }
  let body : Map[String, Json] = Map([])
  for key in ["commit_title", "commit_message"] {
    if parsed.values.get(key) is Some(value) {
      body[key] = Json::string(value)
    }
  }
  if strategy is Some(value) {
    body["merge_method"] = Json::string(value)
  }
  if sha is Some(value) {
    body["sha"] = Json::string(value)
  }
  Ok(
    if body.is_empty() {
      None
    } else {
      Some(@utf8.encode(Json::object(body).stringify()))
    },
  )
}
