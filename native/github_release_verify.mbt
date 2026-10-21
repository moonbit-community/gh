///|
fn release_statement(bundle : Json) -> Json raise {
  guard bundle is { "dsseEnvelope": { "payload": String(encoded), .. }, .. } else {
    fail("missing release statement")
  }
  @bounded_json.parse(@utf8.decode(@base64.decode(encoded)))
}

///|
/// Match the pinned attestation client: retry transport/read failures and
/// server statuses, but parse/decompress the final body only once.
async fn release_bundle_fetch(
  url : String,
  fetch : async (String) -> @gh.RawHttpResponse,
  wait~ : async (Int32) -> Unit noraise = @async.sleep,
) -> @gh.RawHttpResponse {
  for attempt in 1..<=4 {
    let response = fetch(url) catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        if attempt == 4 {
          raise error
        }
        wait(200)
        continue
      }
    }
    if response.status() >= 500 && response.status() <= 599 && attempt < 4 {
      wait(200)
      continue
    }
    return response
  }
  fail("release bundle retry limit reached")
}

///|
async fn release_asset_digest(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  guard file.kind() == @fs.Regular else {
    fail("release asset must be a regular file")
  }
  let hash = @crypto.SHA256::new()
  while file.read_some(max_len=65536) is Some(bytes) {
    hash.update(bytes)
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn execute_release_verify(
  parsed : ParsedBusiness,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
  cache_directory : String?,
  public_fetch : async (String) -> @gh.RawHttpResponse,
  now_unix : Int64,
) -> @github_cli.Output {
  let is_asset = parsed.subcommand == "verify-asset"
  if parsed.positionals.length() > (if is_asset { 2 } else { 1 }) {
    return actions_failure("too many arguments")
  }
  if is_asset && parsed.positionals.is_empty() {
    return actions_failure("you must specify an asset filepath")
  }
  let format = parsed.values.get("format")
  if format is Some(value) && value != "json" {
    return actions_failure("invalid format: " + value)
  }
  if (parsed.jq is Some(_) || parsed.template is Some(_)) && format is None {
    return actions_failure("cannot use --jq or --template without --format")
  }
  let repo = match repository {
    Some(value) => value
    None =>
      match parsed.repository {
        Some(value) =>
          match @github_cli.RepositoryContext::parse(value) {
            Ok(value) => value
            Err(_) =>
              return actions_failure("expected the [HOST/]OWNER/REPO format")
          }
        None => return actions_failure("a repository is required")
      }
  }
  let file_path = if is_asset { parsed.positionals.last() } else { None }
  let mut tag = if parsed.positionals.length() == (if is_asset { 2 } else { 1 }) {
    parsed.positionals[0]
  } else {
    ""
  }
  if tag.is_empty() {
    let latest = match
      account_request(
        client,
        "GET",
        "/repos/" + repo.full_name() + "/releases/latest",
        operation="release.latest",
      ) {
      Ok(value) => value
      Err(error) => return error
    }
    guard latest is { "tag_name": String(value), .. } else {
      return actions_failure("invalid latest release metadata")
    }
    tag = value
  }
  let file_digest = if file_path is Some(path) {
    Some(release_asset_digest(path)) catch {
      error if @async.is_being_cancelled() => raise error
      _ => return actions_failure("could not calculate release asset digest")
    }
  } else {
    None
  }
  let ref_digest = match
    @operations.release_ref_digest(client, repo.full_name(), tag) {
    Ok(value) => value
    Err(error) => return actions_api_failure(error, "")
  }
  let attestations = match
    @operations.list_release_attestations(client, repo.full_name(), ref_digest) {
    Ok(value) if !value.is_empty() => value
    _ =>
      return actions_failure(
        (if is_asset {
          "no attestations found for tag "
        } else {
          "no attestations for tag "
        }) +
        tag +
        " (" +
        ref_digest +
        ")",
      )
  }
  let matching : Array[Json] = []
  for attestation in attestations {
    let bundle = try {
      if !attestation.bundle_url.is_empty() {
        let response = release_bundle_fetch(
          attestation.bundle_url,
          public_fetch,
        )
        @bounded_json.parse(@utf8.decode(@snappy.decompress(response.body())))
      } else {
        attestation.bundle.unwrap()
      }
    } catch {
      error if @async.is_being_cancelled() => raise error
      _ =>
        return actions_failure(
          (if is_asset {
            "no attestations found for tag "
          } else {
            "no attestations for tag "
          }) +
          tag +
          " (" +
          ref_digest +
          ")",
        )
    }
    let statement = release_statement(bundle) catch {
      _ => return actions_failure("error parsing attestations for tag " + tag)
    }
    if statement is { "predicate": { "tag": String(value), .. }, .. } &&
      value == tag {
      matching.push(bundle)
    }
  }
  if matching.is_empty() {
    return actions_failure(
      "no attestations found for release " +
      tag +
      " in " +
      (if is_asset { repo.full_name() } else { repo.name() }),
    )
  }
  if !is_asset && matching.length() > 1 {
    return actions_failure(
      "duplicate attestations found for release " + tag + " in " + repo.name(),
    )
  }
  let mut selected = matching[0]
  if file_digest is Some(digest) {
    let mut found = false
    for bundle in matching {
      let statement = release_statement(bundle)
      if statement is { "subject": Array(subjects), .. } &&
        subjects.any(subject => {
          subject is { "digest": { "sha256": String(value), .. }, .. } &&
          value == digest
        }) {
        selected = bundle
        found = true
        break
      }
    }
    if !found {
      return actions_failure(
        "attestation for " + tag + " does not contain subject sha256:" + digest,
      )
    }
  }
  let prefix = (if is_asset {
      "failed to verify attestation for tag "
    } else {
      "failed to verify attestations for tag "
    }) +
    tag +
    ": "
  let domain = match @operations.release_trust_domain(client) {
    Ok(value) => value
    Err(error) =>
      if error.response() is Some(response) {
        return actions_failure(
          prefix +
          @github_cli.rest_error_message(
            response.status(),
            response.headers(),
            response.body(),
            client.config.base_url() + "/meta",
            reason_phrase?=response.reason_phrase(),
          ),
        )
      } else {
        return actions_api_failure(error, prefix)
      }
  }
  if !domain.is_empty() && domain != "dotcom" {
    return actions_failure(
      "release verification for this Enterprise trust domain is not available",
    )
  }
  let roots = load_release_trust(
    parsed.values.get("custom_trusted_root"),
    cache_directory,
    public_fetch,
    now_unix,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    @attestation.Invalid(message) => return actions_failure(prefix + message)
    _ =>
      return actions_failure(
        prefix + "could not load trusted verification material",
      )
  }
  let mut verified : @attestation.VerifiedRelease? = None
  let mut verification_error = "no trusted verifier accepted the release"
  for root in roots {
    try {
      verified = Some(
        root.verify_release(
          @utf8.encode(selected.stringify()),
          tag~,
          ref_digest~,
          asset_sha256?=file_digest,
          now_unix~,
        ),
      )
      break
    } catch {
      @attestation.Invalid(message) => verification_error = message
    }
  }
  guard verified is Some(verified) else {
    return actions_failure(prefix + verification_error)
  }
  if format == Some("json") {
    let result : Json = {
      "attestation": { "bundle": selected, "bundle_url": "", "initiator": "" },
      "verificationResult": verified.verification_result(),
    }
    return render_github_response(
      200,
      [],
      @utf8.encode(result.stringify()),
      jq?=parsed.jq,
      template?=parsed.template,
    )
  }
  let output = StringBuilder()
  if file_path is Some(path) && file_digest is Some(digest) {
    let name = path.split("/").last().unwrap_or("").to_owned()
    output.write_string(
      "Calculated digest for " + name + ": sha256:" + digest + "\n",
    )
  }
  output.write_string(
    "Resolved tag " +
    tag +
    " to " +
    ref_digest +
    "\nLoaded attestation from GitHub API\n",
  )
  if file_path is Some(path) {
    let name = path.split("/").last().unwrap_or("").to_owned()
    output.write_string(
      "\n✓ Verification succeeded! " +
      name +
      " is present in release " +
      tag +
      "\n",
    )
  } else {
    output.write_string("✓ Release " + tag + " verified!\n\n")
    if verified.statement() is { "subject": Array(subjects), .. } &&
      subjects.length() >= 2 {
      output.write_string("Assets\n")
      for subject in subjects {
        if subject is { "name": String(name), "digest": Object(hashes), .. } &&
          !name.is_empty() {
          let mut digest = ""
          for key, value in hashes {
            if value is String(value) {
              digest = key + ":" + value
            }
          }
          output.write_string(name + "\t" + digest + "\n")
        }
      }
      output.write_string("\n")
    }
  }
  @github_cli.success(stdout=output.to_string())
}
